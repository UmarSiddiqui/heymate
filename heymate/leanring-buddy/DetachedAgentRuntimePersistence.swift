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
    case attemptIDMismatch(expected: UUID, actual: UUID)
    case unsupportedSchemaVersion(Int)
    case corruptJournalRecord(line: Int)
    case nonMonotonicSequence(previous: UInt64, current: UInt64)
    case sequenceExhausted
    case artifactTooLarge(path: String, maximumBytes: UInt64, actualBytes: UInt64)
    case journalRecordTooLarge(maximumBytes: Int, actualBytes: Int)
    case journalRecordLimitExceeded(maximumRecords: Int, actualRecords: Int)
    case invalidPersistencePath(String)
    case unsafeSymbolicLink(String)
    case wrongFileOwner(path: String, expected: UInt32, actual: UInt32)
    case wrongFileType(String)
    case insecureFilePermissions(path: String, expected: Int, actual: Int)
    case writerAlreadyActive(String)
    case invalidProcessGroupIdentity
    case posixFailure(operation: String, code: Int32)
}

/// Hard ceiling for one detached attempt's append-only journal. Keeping these
/// limits together makes both writer and recovery readers enforce identical
/// disk and memory bounds.
nonisolated struct DetachedAgentJournalLimits: Equatable, Sendable {
    static let standard = Self(
        maximumFileByteCount: 8 * 1_024 * 1_024,
        maximumRecordByteCount: 16 * 1_024,
        maximumRecordCount: 10_000
    )

    let maximumFileByteCount: UInt64
    let maximumRecordByteCount: Int
    let maximumRecordCount: Int

    init(
        maximumFileByteCount: UInt64,
        maximumRecordByteCount: Int,
        maximumRecordCount: Int
    ) {
        precondition(maximumFileByteCount > 0)
        precondition(maximumFileByteCount <= UInt64(Int.max))
        precondition(maximumRecordByteCount > 0)
        precondition(maximumRecordCount > 0)
        self.maximumFileByteCount = maximumFileByteCount
        self.maximumRecordByteCount = maximumRecordByteCount
        self.maximumRecordCount = maximumRecordCount
    }
}

/// Narrow durable snapshot. Prompts, CLI arguments, environment variables,
/// raw output, auth tokens, and session identifiers intentionally have no
/// fields here, so callers cannot accidentally persist them.
nonisolated struct DetachedAgentDurableState: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let runID: UUID
    let attemptID: UUID
    let leg: DetachedAgentRunLegKind
    var phase: DetachedAgentRuntimePhase
    let createdAt: Date
    var updatedAt: Date
    var lastJournalSequence: UInt64
    var latestSafeSummary: String?
    var runnerIdentity: AgentProcessIdentity?
    var childIdentity: AgentProcessIdentity?
    var childProcessGroupID: Int32?
    var lastHeartbeatAt: Date?
    var terminalSafeSummary: String?
    var terminalSafeError: String?
    var pendingApprovalToken: DetachedAgentApprovalToken?
    var handedOffToTerminal: Bool
    var exitCode: Int32?

    init(
        runID: UUID,
        attemptID: UUID,
        leg: DetachedAgentRunLegKind,
        phase: DetachedAgentRuntimePhase = .queued,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastJournalSequence: UInt64 = 0,
        latestSafeSummary: String? = nil,
        runnerIdentity: AgentProcessIdentity? = nil,
        childIdentity: AgentProcessIdentity? = nil,
        childProcessGroupID: Int32? = nil,
        lastHeartbeatAt: Date? = nil,
        terminalSafeSummary: String? = nil,
        terminalSafeError: String? = nil,
        pendingApprovalToken: DetachedAgentApprovalToken? = nil,
        handedOffToTerminal: Bool = false,
        exitCode: Int32? = nil
    ) {
        self.schemaVersion = DetachedAgentRuntimeProtocol.currentSchemaVersion
        self.runID = runID
        self.attemptID = attemptID
        self.leg = leg
        self.phase = phase
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastJournalSequence = lastJournalSequence
        self.latestSafeSummary = DetachedAgentSecretRedactor.redact(latestSafeSummary)
        self.runnerIdentity = runnerIdentity
        self.childIdentity = childIdentity
        self.childProcessGroupID = childProcessGroupID
        self.lastHeartbeatAt = lastHeartbeatAt
        self.terminalSafeSummary = DetachedAgentSecretRedactor.redact(terminalSafeSummary)
        self.terminalSafeError = DetachedAgentSecretRedactor.redact(terminalSafeError)
        self.pendingApprovalToken = pendingApprovalToken
        self.handedOffToTerminal = handedOffToTerminal
        self.exitCode = exitCode
    }

    fileprivate func sanitizedForPersistence() -> Self {
        var copy = self
        copy.latestSafeSummary = DetachedAgentSecretRedactor.redact(latestSafeSummary)
        copy.terminalSafeSummary = DetachedAgentSecretRedactor.redact(terminalSafeSummary)
        copy.terminalSafeError = DetachedAgentSecretRedactor.redact(terminalSafeError)
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
    let attemptID: UUID
    let sequence: UInt64
    let messageID: UUID
    let emittedAt: Date
    let kind: DetachedAgentRuntimeEvent.Kind
    let phase: DetachedAgentRuntimePhase?
    let stream: DetachedAgentOutputStream?
    let outputByteCount: Int?
    let safeSummary: String?
    let pendingApprovalToken: DetachedAgentApprovalToken?
    let exitCode: Int32?

    fileprivate init(sequence: UInt64, envelope: DetachedAgentEventEnvelope) {
        schemaVersion = DetachedAgentRuntimeProtocol.currentSchemaVersion
        runID = envelope.runID
        attemptID = envelope.attemptID
        self.sequence = sequence
        messageID = envelope.messageID
        emittedAt = envelope.emittedAt
        kind = envelope.event.kind
        phase = envelope.event.phase
        stream = envelope.event.stream
        pendingApprovalToken = envelope.event.approvalToken
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
    let attemptID: UUID
    let directoryURL: URL
    let journalFileURL: URL

    private let writerLease: DetachedAgentExclusiveFileLease
    private let limits: DetachedAgentJournalLimits
    private let lock = NSLock()
    private var cachedRecords: [DetachedAgentJournalRecord]
    private var nextSequence: UInt64

    init(
        rootDirectoryURL: URL,
        runID: UUID,
        attemptID: UUID,
        limits: DetachedAgentJournalLimits = .standard
    ) throws {
        self.runID = runID
        self.attemptID = attemptID
        self.limits = limits
        let runDirectoryURL = DetachedAgentRuntimePaths.runDirectoryURL(
            rootDirectoryURL: rootDirectoryURL,
            runID: runID
        )
        directoryURL = DetachedAgentRuntimePaths.attemptDirectoryURL(
            rootDirectoryURL: rootDirectoryURL,
            runID: runID,
            attemptID: attemptID
        )
        journalFileURL = directoryURL.appendingPathComponent("events.jsonl", isDirectory: false)

        try DetachedAgentSecureFiles.ensureDirectory(rootDirectoryURL)
        try DetachedAgentSecureFiles.ensureDirectory(runDirectoryURL)
        try DetachedAgentSecureFiles.ensureDirectory(directoryURL)
        writerLease = try DetachedAgentExclusiveFileLease(
            fileURL: directoryURL.appendingPathComponent("journal-writer.lock")
        )
        try DetachedAgentSecureFiles.ensureFile(journalFileURL)

        let recoveredRecords = try Self.loadAndRecover(
            journalFileURL: journalFileURL,
            expectedRunID: runID,
            expectedAttemptID: attemptID,
            truncateIncompleteFinalRecord: true,
            limits: limits
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
        guard envelope.attemptID == attemptID else {
            throw DetachedAgentPersistenceError.attemptIDMismatch(
                expected: attemptID,
                actual: envelope.attemptID
            )
        }
        guard nextSequence > 0 else {
            throw DetachedAgentPersistenceError.sequenceExhausted
        }
        guard cachedRecords.count < limits.maximumRecordCount else {
            throw DetachedAgentPersistenceError.journalRecordLimitExceeded(
                maximumRecords: limits.maximumRecordCount,
                actualRecords: cachedRecords.count + 1
            )
        }

        let record = DetachedAgentJournalRecord(sequence: nextSequence, envelope: envelope)
        let encodedRecord = try Self.makeEncoder().encode(record)
        guard encodedRecord.count <= limits.maximumRecordByteCount else {
            throw DetachedAgentPersistenceError.journalRecordTooLarge(
                maximumBytes: limits.maximumRecordByteCount,
                actualBytes: encodedRecord.count
            )
        }
        var line = encodedRecord
        line.append(0x0A)

        try DetachedAgentSecureFiles.appendDurably(
            line,
            to: journalFileURL,
            maximumFileByteCount: limits.maximumFileByteCount
        )

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
        expectedRunID: UUID,
        expectedAttemptID: UUID,
        truncateIncompleteFinalRecord: Bool,
        limits: DetachedAgentJournalLimits
    ) throws -> [DetachedAgentJournalRecord] {
        var data = try DetachedAgentSecureFiles.readRegularFile(
            journalFileURL,
            maximumByteCount: limits.maximumFileByteCount
        )
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

            if truncateIncompleteFinalRecord {
                try DetachedAgentSecureFiles.truncateDurably(
                    journalFileURL,
                    to: UInt64(recoveredLength)
                )
            }
            data = data.prefix(recoveredLength)
        }

        guard !data.isEmpty else { return [] }

        var records: [DetachedAgentJournalRecord] = []
        records.reserveCapacity(min(limits.maximumRecordCount, 256))
        var previousSequence: UInt64?
        var lineStart = data.startIndex
        var lineNumber = 0

        while lineStart < data.endIndex {
            guard let newlineIndex = data[lineStart...].firstIndex(of: 0x0A) else {
                break
            }
            let line = data[lineStart..<newlineIndex]
            lineStart = data.index(after: newlineIndex)
            guard !line.isEmpty else { continue }
            lineNumber += 1
            guard line.count <= limits.maximumRecordByteCount else {
                throw DetachedAgentPersistenceError.journalRecordTooLarge(
                    maximumBytes: limits.maximumRecordByteCount,
                    actualBytes: line.count
                )
            }
            guard records.count < limits.maximumRecordCount else {
                throw DetachedAgentPersistenceError.journalRecordLimitExceeded(
                    maximumRecords: limits.maximumRecordCount,
                    actualRecords: records.count + 1
                )
            }
            let record: DetachedAgentJournalRecord
            do {
                record = try makeDecoder().decode(
                    DetachedAgentJournalRecord.self,
                    from: Data(line)
                )
            } catch {
                throw DetachedAgentPersistenceError.corruptJournalRecord(
                    line: lineNumber
                )
            }

            guard DetachedAgentRuntimeProtocol.supportsLiveAttemptSchemaVersion(
                record.schemaVersion
            ) else {
                throw DetachedAgentPersistenceError.unsupportedSchemaVersion(record.schemaVersion)
            }
            guard record.runID == expectedRunID else {
                throw DetachedAgentPersistenceError.runIDMismatch(
                    expected: expectedRunID,
                    actual: record.runID
                )
            }
            guard record.attemptID == expectedAttemptID else {
                throw DetachedAgentPersistenceError.attemptIDMismatch(
                    expected: expectedAttemptID,
                    actual: record.attemptID
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

    /// Reads a live runner's journal without acquiring its writer lease and
    /// without truncating an in-progress final JSONL record.
    static func loadReadOnly(
        rootDirectoryURL: URL,
        runID: UUID,
        attemptID: UUID,
        limits: DetachedAgentJournalLimits = .standard
    ) throws -> [DetachedAgentJournalRecord] {
        let runDirectoryURL = DetachedAgentRuntimePaths.runDirectoryURL(
            rootDirectoryURL: rootDirectoryURL,
            runID: runID
        )
        let attemptDirectoryURL = DetachedAgentRuntimePaths.attemptDirectoryURL(
            rootDirectoryURL: rootDirectoryURL,
            runID: runID,
            attemptID: attemptID
        )
        let fileURL = attemptDirectoryURL.appendingPathComponent("events.jsonl", isDirectory: false)
        guard DetachedAgentSecureFiles.pathExistsWithoutFollowingLinks(fileURL) else { return [] }
        try DetachedAgentSecureFiles.validateDirectory(rootDirectoryURL)
        try DetachedAgentSecureFiles.validateDirectory(runDirectoryURL)
        try DetachedAgentSecureFiles.validateDirectory(attemptDirectoryURL)
        return try loadAndRecover(
            journalFileURL: fileURL,
            expectedRunID: runID,
            expectedAttemptID: attemptID,
            truncateIncompleteFinalRecord: false,
            limits: limits
        )
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
    let attemptID: UUID
    let directoryURL: URL
    let stateFileURL: URL
    private let writerLease: DetachedAgentExclusiveFileLease

    init(rootDirectoryURL: URL, runID: UUID, attemptID: UUID) throws {
        self.runID = runID
        self.attemptID = attemptID
        let runDirectoryURL = DetachedAgentRuntimePaths.runDirectoryURL(
            rootDirectoryURL: rootDirectoryURL,
            runID: runID
        )
        directoryURL = DetachedAgentRuntimePaths.attemptDirectoryURL(
            rootDirectoryURL: rootDirectoryURL,
            runID: runID,
            attemptID: attemptID
        )
        stateFileURL = directoryURL.appendingPathComponent("state.json", isDirectory: false)
        try DetachedAgentSecureFiles.ensureDirectory(rootDirectoryURL)
        try DetachedAgentSecureFiles.ensureDirectory(runDirectoryURL)
        try DetachedAgentSecureFiles.ensureDirectory(directoryURL)
        writerLease = try DetachedAgentExclusiveFileLease(
            fileURL: directoryURL.appendingPathComponent("state-writer.lock")
        )
    }

    func load() throws -> DetachedAgentDurableState? {
        try Self.loadState(
            stateFileURL: stateFileURL,
            expectedRunID: runID,
            expectedAttemptID: attemptID
        )
    }

    static func loadReadOnly(
        rootDirectoryURL: URL,
        runID: UUID,
        attemptID: UUID
    ) throws -> DetachedAgentDurableState? {
        let runDirectoryURL = DetachedAgentRuntimePaths.runDirectoryURL(
            rootDirectoryURL: rootDirectoryURL,
            runID: runID
        )
        let attemptDirectoryURL = DetachedAgentRuntimePaths.attemptDirectoryURL(
            rootDirectoryURL: rootDirectoryURL,
            runID: runID,
            attemptID: attemptID
        )
        let stateFileURL = attemptDirectoryURL.appendingPathComponent("state.json", isDirectory: false)
        guard DetachedAgentSecureFiles.pathExistsWithoutFollowingLinks(stateFileURL) else { return nil }
        try DetachedAgentSecureFiles.validateDirectory(rootDirectoryURL)
        try DetachedAgentSecureFiles.validateDirectory(runDirectoryURL)
        try DetachedAgentSecureFiles.validateDirectory(attemptDirectoryURL)
        return try loadState(
            stateFileURL: stateFileURL,
            expectedRunID: runID,
            expectedAttemptID: attemptID
        )
    }

    private static func loadState(
        stateFileURL: URL,
        expectedRunID: UUID,
        expectedAttemptID: UUID
    ) throws -> DetachedAgentDurableState? {
        guard DetachedAgentSecureFiles.pathExistsWithoutFollowingLinks(stateFileURL) else { return nil }
        let state = try DetachedAgentRuntimeJournal.makeDecoder().decode(
            DetachedAgentDurableState.self,
            from: DetachedAgentSecureFiles.readRegularFile(stateFileURL)
        )
        guard DetachedAgentRuntimeProtocol.supportsLiveAttemptSchemaVersion(
            state.schemaVersion
        ) else {
            throw DetachedAgentPersistenceError.unsupportedSchemaVersion(state.schemaVersion)
        }
        guard state.runID == expectedRunID else {
            throw DetachedAgentPersistenceError.runIDMismatch(
                expected: expectedRunID,
                actual: state.runID
            )
        }
        guard state.attemptID == expectedAttemptID else {
            throw DetachedAgentPersistenceError.attemptIDMismatch(
                expected: expectedAttemptID,
                actual: state.attemptID
            )
        }
        try validateProcessOwnership(in: state)
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
        guard state.attemptID == attemptID else {
            throw DetachedAgentPersistenceError.attemptIDMismatch(
                expected: attemptID,
                actual: state.attemptID
            )
        }
        try Self.validateProcessOwnership(in: state)

        let data = try DetachedAgentRuntimeJournal.makeEncoder().encode(
            state.sanitizedForPersistence()
        )
        try DetachedAgentSecureFiles.atomicDurableWrite(data, to: stateFileURL)
    }

    private static func validateProcessOwnership(
        in state: DetachedAgentDurableState
    ) throws {
        if let runnerIdentity = state.runnerIdentity,
           !AgentProcessIdentityInspector.isTrustworthy(runnerIdentity) {
            throw DetachedAgentPersistenceError.invalidPersistencePath(
                "Untrustworthy runner process identity"
            )
        }
        if let childIdentity = state.childIdentity,
           !AgentProcessIdentityInspector.isTrustworthy(childIdentity) {
            throw DetachedAgentPersistenceError.invalidPersistencePath(
                "Untrustworthy child process identity"
            )
        }
        if let childProcessGroupID = state.childProcessGroupID {
            guard childProcessGroupID > 1,
                  state.childIdentity?.pid == childProcessGroupID else {
                throw DetachedAgentPersistenceError.invalidProcessGroupIdentity
            }
        }
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

nonisolated final class DetachedAgentExclusiveFileLease: @unchecked Sendable {
    private static let registry = Registry()

    private let descriptor: Int32
    private let path: String

    init(fileURL: URL) throws {
        let path = fileURL.standardizedFileURL.path
        guard Self.registry.acquire(path) else {
            throw DetachedAgentPersistenceError.writerAlreadyActive(path)
        }
        var keepsRegistryLease = false
        defer {
            if !keepsRegistryLease { Self.registry.release(path) }
        }
        try DetachedAgentSecureFiles.ensureFile(fileURL)
        let descriptor = fileURL.path.withCString {
            Darwin.open($0, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw DetachedAgentSecureFiles.posixError(operation: "open writer lease")
        }
        guard Self.setLock(descriptor: descriptor, type: F_WRLCK) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw DetachedAgentPersistenceError.writerAlreadyActive(fileURL.path)
            }
            throw DetachedAgentPersistenceError.posixFailure(
                operation: "lock writer lease",
                code: code
            )
        }
        self.descriptor = descriptor
        self.path = path
        keepsRegistryLease = true
    }

    deinit {
        _ = Self.setLock(descriptor: descriptor, type: F_UNLCK)
        Darwin.close(descriptor)
        Self.registry.release(path)
    }

    private static func setLock(descriptor: Int32, type: Int32) -> Int32 {
        var fileLock = flock()
        fileLock.l_type = Int16(type)
        fileLock.l_whence = Int16(SEEK_SET)
        fileLock.l_start = 0
        fileLock.l_len = 0
        return Darwin.fcntl(descriptor, F_SETLK, &fileLock)
    }

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []

        func acquire(_ path: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return paths.insert(path).inserted
        }

        func release(_ path: String) {
            lock.lock()
            paths.remove(path)
            lock.unlock()
        }
    }
}

nonisolated enum DetachedAgentSecureFiles {
    private static let expectedOwner = UInt32(getuid())

    static func pathExistsWithoutFollowingLinks(_ url: URL) -> Bool {
        var information = stat()
        let result = url.path.withCString { Darwin.lstat($0, &information) }
        return result == 0
    }

    static func ensureDirectory(_ url: URL) throws {
        var information = stat()
        let status = url.path.withCString { Darwin.lstat($0, &information) }
        if status != 0 {
            guard errno == ENOENT else { throw posixError(operation: "lstat directory") }
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw DetachedAgentPersistenceError.unsafeSymbolicLink(url.path) }
            throw posixError(operation: "open directory")
        }
        defer { Darwin.close(descriptor) }
        let existing = try validatedInformation(
            descriptor: descriptor,
            path: url.path,
            expectedType: mode_t(S_IFDIR)
        )
        guard Darwin.fchmod(descriptor, 0o700) == 0 else {
            throw posixError(operation: "chmod directory")
        }
        _ = existing
    }

    /// Read-only validation used before recovery follows a runtime hierarchy.
    /// Unlike `ensureDirectory`, this never repairs permissions or creates a
    /// missing component.
    static func validateDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw DetachedAgentPersistenceError.unsafeSymbolicLink(url.path) }
            throw posixError(operation: "open directory for validation")
        }
        defer { Darwin.close(descriptor) }
        let information = try validatedInformation(
            descriptor: descriptor,
            path: url.path,
            expectedType: mode_t(S_IFDIR)
        )
        try requirePermissions(information, expected: 0o700, path: url.path)
    }

    static func ensureFile(_ url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw DetachedAgentPersistenceError.unsafeSymbolicLink(url.path) }
            throw posixError(operation: "open file")
        }
        defer { Darwin.close(descriptor) }
        _ = try validatedInformation(
            descriptor: descriptor,
            path: url.path,
            expectedType: mode_t(S_IFREG)
        )
        guard Darwin.fchmod(descriptor, 0o600) == 0 else {
            throw posixError(operation: "chmod file")
        }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    static func readRegularFile(
        _ url: URL,
        maximumByteCount: UInt64? = nil
    ) throws -> Data {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw DetachedAgentPersistenceError.unsafeSymbolicLink(url.path) }
            throw posixError(operation: "open file for reading")
        }
        do {
            let information = try validatedInformation(
                descriptor: descriptor,
                path: url.path,
                expectedType: mode_t(S_IFREG)
            )
            try requirePermissions(information, expected: 0o600, path: url.path)
            guard information.st_size >= 0 else {
                throw DetachedAgentPersistenceError.posixFailure(
                    operation: "negative file size",
                    code: EIO
                )
            }
            let existingByteCount = UInt64(information.st_size)
            if let maximumByteCount, existingByteCount > maximumByteCount {
                throw DetachedAgentPersistenceError.artifactTooLarge(
                    path: url.path,
                    maximumBytes: maximumByteCount,
                    actualBytes: existingByteCount
                )
            }

            let boundedCapacity = maximumByteCount.map {
                min(existingByteCount, $0)
            } ?? existingByteCount
            var data = Data()
            data.reserveCapacity(Int(boundedCapacity))
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                let requestedByteCount: Int
                if let maximumByteCount {
                    let currentByteCount = UInt64(data.count)
                    guard currentByteCount <= maximumByteCount else {
                        throw DetachedAgentPersistenceError.artifactTooLarge(
                            path: url.path,
                            maximumBytes: maximumByteCount,
                            actualBytes: currentByteCount
                        )
                    }
                    let remainingThroughSentinel = maximumByteCount - currentByteCount + 1
                    requestedByteCount = Int(min(UInt64(buffer.count), remainingThroughSentinel))
                } else {
                    requestedByteCount = buffer.count
                }

                let readByteCount = Darwin.read(descriptor, &buffer, requestedByteCount)
                if readByteCount < 0, errno == EINTR { continue }
                guard readByteCount >= 0 else { throw posixError(operation: "read file") }
                guard readByteCount > 0 else { break }
                data.append(contentsOf: buffer.prefix(readByteCount))
                if let maximumByteCount, UInt64(data.count) > maximumByteCount {
                    throw DetachedAgentPersistenceError.artifactTooLarge(
                        path: url.path,
                        maximumBytes: maximumByteCount,
                        actualBytes: UInt64(data.count)
                    )
                }
            }
            Darwin.close(descriptor)
            return data
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func appendDurably(
        _ data: Data,
        to url: URL,
        maximumFileByteCount: UInt64? = nil
    ) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw DetachedAgentPersistenceError.unsafeSymbolicLink(url.path) }
            throw posixError(operation: "open journal for append")
        }
        defer { Darwin.close(descriptor) }
        let information = try validatedInformation(
            descriptor: descriptor,
            path: url.path,
            expectedType: mode_t(S_IFREG)
        )
        try requirePermissions(information, expected: 0o600, path: url.path)
        guard information.st_size >= 0 else {
            throw DetachedAgentPersistenceError.posixFailure(
                operation: "negative journal size",
                code: EIO
            )
        }
        if let maximumFileByteCount {
            let existingByteCount = UInt64(information.st_size)
            let appendedByteCount = UInt64(data.count)
            guard existingByteCount <= maximumFileByteCount,
                  appendedByteCount <= maximumFileByteCount - existingByteCount else {
                let actualByteCount = existingByteCount.addingReportingOverflow(appendedByteCount)
                throw DetachedAgentPersistenceError.artifactTooLarge(
                    path: url.path,
                    maximumBytes: maximumFileByteCount,
                    actualBytes: actualByteCount.overflow ? UInt64.max : actualByteCount.partialValue
                )
            }
        }
        try writeAll(data, descriptor: descriptor)
        guard Darwin.fsync(descriptor) == 0 else { throw posixError(operation: "fsync journal") }
    }

    static func truncateDurably(_ url: URL, to length: UInt64) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw DetachedAgentPersistenceError.unsafeSymbolicLink(url.path) }
            throw posixError(operation: "open journal for recovery")
        }
        defer { Darwin.close(descriptor) }
        _ = try validatedInformation(
            descriptor: descriptor,
            path: url.path,
            expectedType: mode_t(S_IFREG)
        )
        guard Darwin.ftruncate(descriptor, off_t(length)) == 0 else {
            throw posixError(operation: "truncate journal")
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError(operation: "fsync recovered journal")
        }
    }

    static func atomicDurableWrite(_ data: Data, to destinationURL: URL) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        try ensureDirectory(directoryURL)
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { _ = temporaryURL.path.withCString { Darwin.unlink($0) } }

        if pathExistsWithoutFollowingLinks(destinationURL) {
            let descriptor = destinationURL.path.withCString {
                Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else {
                if errno == ELOOP {
                    throw DetachedAgentPersistenceError.unsafeSymbolicLink(destinationURL.path)
                }
                throw posixError(operation: "validate atomic destination")
            }
            defer { Darwin.close(descriptor) }
            _ = try validatedInformation(
                descriptor: descriptor,
                path: destinationURL.path,
                expectedType: mode_t(S_IFREG)
            )
        }

        let temporaryDescriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard temporaryDescriptor >= 0 else { throw posixError(operation: "create atomic temporary file") }
        do {
            try writeAll(data, descriptor: temporaryDescriptor)
            guard Darwin.fsync(temporaryDescriptor) == 0 else {
                throw posixError(operation: "fsync atomic temporary file")
            }
            Darwin.close(temporaryDescriptor)
        } catch {
            Darwin.close(temporaryDescriptor)
            throw error
        }

        let renameResult = temporaryURL.path.withCString { temporaryPath in
            destinationURL.path.withCString { destinationPath in
                Darwin.rename(temporaryPath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw posixError(operation: "rename")
        }
        let destinationDescriptor = destinationURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard destinationDescriptor >= 0 else {
            throw posixError(operation: "open atomic destination")
        }
        defer { Darwin.close(destinationDescriptor) }
        _ = try validatedInformation(
            descriptor: destinationDescriptor,
            path: destinationURL.path,
            expectedType: mode_t(S_IFREG)
        )
        try synchronizeDirectory(directoryURL)
    }

    /// Publishes a fully synchronized file only when the destination does not
    /// already exist. A hard link makes the completed temporary inode visible
    /// atomically and gives command message IDs natural collision protection.
    static func atomicDurableCreate(_ data: Data, at destinationURL: URL) throws -> Bool {
        let directoryURL = destinationURL.deletingLastPathComponent()
        try ensureDirectory(directoryURL)
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { _ = temporaryURL.path.withCString { Darwin.unlink($0) } }

        let descriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else { throw posixError(operation: "create atomic inbox file") }
        do {
            try writeAll(data, descriptor: descriptor)
            guard Darwin.fsync(descriptor) == 0 else {
                throw posixError(operation: "fsync atomic inbox file")
            }
            Darwin.close(descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }

        let linkResult = temporaryURL.path.withCString { temporaryPath in
            destinationURL.path.withCString { destinationPath in
                Darwin.link(temporaryPath, destinationPath)
            }
        }
        if linkResult != 0 {
            if errno == EEXIST { return false }
            throw posixError(operation: "publish atomic inbox file")
        }
        try synchronizeDirectory(directoryURL)
        return true
    }

    static func removeRegularFileDurably(_ url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw DetachedAgentPersistenceError.unsafeSymbolicLink(url.path) }
            if errno == ENOENT { return }
            throw posixError(operation: "open file for removal")
        }
        defer { Darwin.close(descriptor) }
        _ = try validatedInformation(
            descriptor: descriptor,
            path: url.path,
            expectedType: mode_t(S_IFREG)
        )
        guard url.path.withCString({ Darwin.unlink($0) }) == 0 else {
            if errno == ENOENT { return }
            throw posixError(operation: "remove file")
        }
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private static func validatedInformation(
        descriptor: Int32,
        path: String,
        expectedType: mode_t
    ) throws -> stat {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw posixError(operation: "fstat")
        }
        let actualType = information.st_mode & mode_t(S_IFMT)
        guard actualType == expectedType else {
            throw DetachedAgentPersistenceError.wrongFileType(path)
        }
        guard information.st_uid == expectedOwner else {
            throw DetachedAgentPersistenceError.wrongFileOwner(
                path: path,
                expected: expectedOwner,
                actual: information.st_uid
            )
        }
        return information
    }

    private static func requirePermissions(_ information: stat, expected: Int, path: String) throws {
        let actual = Int(information.st_mode & 0o777)
        guard actual == expected else {
            throw DetachedAgentPersistenceError.insecureFilePermissions(
                path: path,
                expected: expected,
                actual: actual
            )
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var writtenByteCount = 0
            while writtenByteCount < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: writtenByteCount),
                    bytes.count - writtenByteCount
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw posixError(operation: "write") }
                writtenByteCount += result
            }
        }
    }

    static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw posixError(operation: "open directory")
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError(operation: "fsync directory")
        }
    }

    static func posixError(operation: String) -> DetachedAgentPersistenceError {
        DetachedAgentPersistenceError.posixFailure(operation: operation, code: errno)
    }
}
