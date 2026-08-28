//
//  DetachedAgentRuntimePersistence.swift
//  leanring-buddy
//
//  Crash-tolerant local persistence for detached coding-agent runtimes.
//  Journal is append-only JSONL. State snapshots use fsync + atomic rename.
//

import Darwin
import Foundation

nonisolated enum DetachedAgentPersistenceError: Error, Equatable {
    case runIDMismatch(expected: UUID, actual: UUID)
    case unsupportedSchemaVersion(Int)
    case corruptJournalRecord(line: Int)
    case nonMonotonicSequence(previous: UInt64, current: UInt64)
    case sequenceExhausted
    case invalidPersistencePath(String)
    case posixFailure(operation: String, code: Int32)
}

/// Narrow durable snapshot. Prompts, CLI arguments, environment variables,
/// raw output, auth tokens, and session identifiers intentionally have no
/// fields here, so callers cannot accidentally persist them.
nonisolated struct DetachedAgentDurableState: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let runID: UUID
    var phase: DetachedAgentRuntimePhase
    let createdAt: Date
    var updatedAt: Date
    var lastJournalSequence: UInt64
    var latestSafeSummary: String?
    var exitCode: Int32?

    init(
        runID: UUID,
        phase: DetachedAgentRuntimePhase = .queued,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastJournalSequence: UInt64 = 0,
        latestSafeSummary: String? = nil,
        exitCode: Int32? = nil
    ) {
        self.schemaVersion = DetachedAgentRuntimeProtocol.currentSchemaVersion
        self.runID = runID
        self.phase = phase
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastJournalSequence = lastJournalSequence
        self.latestSafeSummary = DetachedAgentSecretRedactor.redact(latestSafeSummary)
        self.exitCode = exitCode
    }

    fileprivate func sanitizedForPersistence() -> Self {
        var copy = self
        copy.latestSafeSummary = DetachedAgentSecretRedactor.redact(latestSafeSummary)
        return copy
    }
}

/// Persistence-safe projection of a runtime event.
///
/// Output contents and opaque CLI identifiers are never retained. Output
/// records keep only stream and byte count. User-visible summaries pass
/// through a defensive redactor and length cap before encoding.
nonisolated struct DetachedAgentJournalRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let runID: UUID
    let sequence: UInt64
    let messageID: UUID
    let emittedAt: Date
    let kind: DetachedAgentRuntimeEvent.Kind
    let phase: DetachedAgentRuntimePhase?
    let stream: DetachedAgentOutputStream?
    let outputByteCount: Int?
    let safeSummary: String?
    let exitCode: Int32?

    fileprivate init(sequence: UInt64, envelope: DetachedAgentEventEnvelope) {
        schemaVersion = DetachedAgentRuntimeProtocol.currentSchemaVersion
        runID = envelope.runID
        self.sequence = sequence
        messageID = envelope.messageID
        emittedAt = envelope.emittedAt
        kind = envelope.event.kind
        phase = envelope.event.phase
        stream = envelope.event.stream
        exitCode = envelope.event.exitCode

        if envelope.event.kind == .output {
            outputByteCount = envelope.event.text?.utf8.count ?? 0
            safeSummary = nil
        } else {
            outputByteCount = nil
            safeSummary = DetachedAgentSecretRedactor.redact(envelope.event.text)
        }
    }
}

nonisolated final class DetachedAgentRuntimeJournal {
    let runID: UUID
    let directoryURL: URL
    let journalFileURL: URL

    private let lock = NSLock()
    private var cachedRecords: [DetachedAgentJournalRecord]
    private var nextSequence: UInt64

    init(rootDirectoryURL: URL, runID: UUID) throws {
        self.runID = runID
        directoryURL = rootDirectoryURL
            .appendingPathComponent(runID.uuidString.lowercased(), isDirectory: true)
        journalFileURL = directoryURL.appendingPathComponent("events.jsonl", isDirectory: false)

        try DetachedAgentSecureFiles.ensureDirectory(rootDirectoryURL)
        try DetachedAgentSecureFiles.ensureDirectory(directoryURL)
        try DetachedAgentSecureFiles.ensureFile(journalFileURL)

        let recoveredRecords = try Self.loadAndRecover(
            journalFileURL: journalFileURL,
            expectedRunID: runID
        )
        cachedRecords = recoveredRecords
        if let lastSequence = recoveredRecords.last?.sequence {
            guard lastSequence < UInt64.max else {
                throw DetachedAgentPersistenceError.sequenceExhausted
            }
            nextSequence = lastSequence + 1
        } else {
            nextSequence = 1
        }
    }

    func records() -> [DetachedAgentJournalRecord] {
        lock.lock()
        defer { lock.unlock() }
        return cachedRecords
    }

    @discardableResult
    func append(_ envelope: DetachedAgentEventEnvelope) throws -> DetachedAgentJournalRecord {
        lock.lock()
        defer { lock.unlock() }

        guard envelope.schemaVersion == DetachedAgentRuntimeProtocol.currentSchemaVersion else {
            throw DetachedAgentPersistenceError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        guard envelope.runID == runID else {
            throw DetachedAgentPersistenceError.runIDMismatch(
                expected: runID,
                actual: envelope.runID
            )
        }
        guard nextSequence > 0 else {
            throw DetachedAgentPersistenceError.sequenceExhausted
        }

        let record = DetachedAgentJournalRecord(sequence: nextSequence, envelope: envelope)
        let encodedRecord = try Self.makeEncoder().encode(record)
        var line = encodedRecord
        line.append(0x0A)

        let fileHandle = try FileHandle(forWritingTo: journalFileURL)
        defer { try? fileHandle.close() }
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: line)
        try fileHandle.synchronize()
        try DetachedAgentSecureFiles.setPermissions(0o600, at: journalFileURL)

        cachedRecords.append(record)
        if nextSequence == UInt64.max {
            nextSequence = 0
        } else {
            nextSequence += 1
        }
        return record
    }

    private static func loadAndRecover(
        journalFileURL: URL,
        expectedRunID: UUID
    ) throws -> [DetachedAgentJournalRecord] {
        var data = try Data(contentsOf: journalFileURL)
        if !data.isEmpty, data.last != 0x0A {
            let recoveredLength: Int
            if let lastNewlineIndex = data.lastIndex(of: 0x0A) {
                recoveredLength = data.distance(
                    from: data.startIndex,
                    to: data.index(after: lastNewlineIndex)
                )
            } else {
                recoveredLength = 0
            }

            let fileHandle = try FileHandle(forWritingTo: journalFileURL)
            defer { try? fileHandle.close() }
            try fileHandle.truncate(atOffset: UInt64(recoveredLength))
            try fileHandle.synchronize()
            data = data.prefix(recoveredLength)
        }

        guard !data.isEmpty else { return [] }

        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var records: [DetachedAgentJournalRecord] = []
        records.reserveCapacity(lines.count)
        var previousSequence: UInt64?

        for (zeroBasedIndex, line) in lines.enumerated() {
            let record: DetachedAgentJournalRecord
            do {
                record = try makeDecoder().decode(
                    DetachedAgentJournalRecord.self,
                    from: Data(line)
                )
            } catch {
                throw DetachedAgentPersistenceError.corruptJournalRecord(
                    line: zeroBasedIndex + 1
                )
            }

            guard record.schemaVersion == DetachedAgentRuntimeProtocol.currentSchemaVersion else {
                throw DetachedAgentPersistenceError.unsupportedSchemaVersion(record.schemaVersion)
            }
            guard record.runID == expectedRunID else {
                throw DetachedAgentPersistenceError.runIDMismatch(
                    expected: expectedRunID,
                    actual: record.runID
                )
            }
            if let previousSequence, record.sequence <= previousSequence {
                throw DetachedAgentPersistenceError.nonMonotonicSequence(
                    previous: previousSequence,
                    current: record.sequence
                )
            }
            previousSequence = record.sequence
            records.append(record)
        }
        return records
    }

    fileprivate static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    fileprivate static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

nonisolated final class DetachedAgentDurableStateStore {
    let runID: UUID
    let directoryURL: URL
    let stateFileURL: URL

    init(rootDirectoryURL: URL, runID: UUID) throws {
        self.runID = runID
        directoryURL = rootDirectoryURL
            .appendingPathComponent(runID.uuidString.lowercased(), isDirectory: true)
        stateFileURL = directoryURL.appendingPathComponent("state.json", isDirectory: false)
        try DetachedAgentSecureFiles.ensureDirectory(rootDirectoryURL)
        try DetachedAgentSecureFiles.ensureDirectory(directoryURL)
    }

    func load() throws -> DetachedAgentDurableState? {
        guard FileManager.default.fileExists(atPath: stateFileURL.path) else { return nil }
        let state = try DetachedAgentRuntimeJournal.makeDecoder().decode(
            DetachedAgentDurableState.self,
            from: Data(contentsOf: stateFileURL)
        )
        guard state.schemaVersion == DetachedAgentRuntimeProtocol.currentSchemaVersion else {
            throw DetachedAgentPersistenceError.unsupportedSchemaVersion(state.schemaVersion)
        }
        guard state.runID == runID else {
            throw DetachedAgentPersistenceError.runIDMismatch(
                expected: runID,
                actual: state.runID
            )
        }
        return state
    }

    func save(_ state: DetachedAgentDurableState) throws {
        guard state.schemaVersion == DetachedAgentRuntimeProtocol.currentSchemaVersion else {
            throw DetachedAgentPersistenceError.unsupportedSchemaVersion(state.schemaVersion)
        }
        guard state.runID == runID else {
            throw DetachedAgentPersistenceError.runIDMismatch(
                expected: runID,
                actual: state.runID
            )
        }

        let data = try DetachedAgentRuntimeJournal.makeEncoder().encode(
            state.sanitizedForPersistence()
        )
        try DetachedAgentSecureFiles.atomicDurableWrite(data, to: stateFileURL)
    }
}

nonisolated private enum DetachedAgentSecretRedactor {
    private static let replacement = "[REDACTED]"
    private static let maximumSummaryLength = 512

    private static let patterns: [(pattern: String, template: String)] = [
        (#"(?i)(authorization\s*:\s*bearer\s+)[^\s\"']+"#, "$1\(replacement)"),
        (#"(?i)((?:api[_-]?key|access[_-]?token|auth[_-]?token|token|client[_-]?secret|password|secret)\s*[:=]\s*[\"']?)[^\s,\"'}]+"#, "$1\(replacement)"),
        (#"(?i)(--(?:api-key|token|password|secret)(?:=|\s+))[^\s]+"#, "$1\(replacement)"),
        (#"(?i)\b(?:sk-(?:ant-|proj-)?|github_pat_|gh[pousr]_|xox[baprs]-)[A-Za-z0-9_\-]+"#, replacement),
        (#"\bAKIA[0-9A-Z]{16}\b"#, replacement)
    ]

    static func redact(_ value: String?) -> String? {
        guard var value else { return nil }
        for item in patterns {
            guard let expression = try? NSRegularExpression(pattern: item.pattern) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = expression.stringByReplacingMatches(
                in: value,
                options: [],
                range: range,
                withTemplate: item.template
            )
        }
        if value.count > maximumSummaryLength {
            let cutoff = value.index(value.startIndex, offsetBy: maximumSummaryLength)
            value = String(value[..<cutoff])
        }
        return value
    }
}

nonisolated private enum DetachedAgentSecureFiles {
    static func ensureDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        )
        if exists, !isDirectory.boolValue {
            throw DetachedAgentPersistenceError.invalidPersistencePath(url.path)
        }
        if !exists {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try setPermissions(0o700, at: url)
    }

    static func ensureFile(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        )
        if exists, isDirectory.boolValue {
            throw DetachedAgentPersistenceError.invalidPersistencePath(url.path)
        }
        if !exists {
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw DetachedAgentPersistenceError.invalidPersistencePath(url.path)
            }
            try synchronizeDirectory(url.deletingLastPathComponent())
        }
        try setPermissions(0o600, at: url)
    }

    static func atomicDurableWrite(_ data: Data, to destinationURL: URL) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        try ensureDirectory(directoryURL)
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw DetachedAgentPersistenceError.invalidPersistencePath(temporaryURL.path)
        }

        let fileHandle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try fileHandle.write(contentsOf: data)
            try fileHandle.synchronize()
            try fileHandle.close()
        } catch {
            try? fileHandle.close()
            throw error
        }
        try setPermissions(0o600, at: temporaryURL)

        let renameResult = temporaryURL.path.withCString { temporaryPath in
            destinationURL.path.withCString { destinationPath in
                Darwin.rename(temporaryPath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw posixError(operation: "rename")
        }
        try setPermissions(0o600, at: destinationURL)
        try synchronizeDirectory(directoryURL)
    }

    static func setPermissions(_ permissions: Int, at url: URL) throws {
        let result = url.path.withCString { path in
            Darwin.chmod(path, mode_t(permissions))
        }
        guard result == 0 else {
            throw posixError(operation: "chmod")
        }
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString { path in
            Darwin.open(path, O_RDONLY)
        }
        guard descriptor >= 0 else {
            throw posixError(operation: "open directory")
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError(operation: "fsync directory")
        }
    }

    private static func posixError(operation: String) -> DetachedAgentPersistenceError {
        DetachedAgentPersistenceError.posixFailure(operation: operation, code: errno)
    }
}
