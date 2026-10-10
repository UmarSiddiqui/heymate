//
//  DetachedAgentCommandMailbox.swift
//  HeyMate
//
//  Attempt-scoped, crash-safe command inbox. Each message is one atomic 0600
//  file. Processed IDs persist separately, so replaying the same message ID
//  cannot repeat a command after the runner drains it.
//

import Foundation

nonisolated enum DetachedAgentCommandMailboxError: Error, Equatable {
    case payloadTooLarge(maximumBytes: Int)
    case messageIDCollision(UUID)
    case tooManyPendingCommands(maximumCount: Int)
}

nonisolated final class DetachedAgentCommandMailbox {
    static let maximumEncodedCommandBytes = 1 * 1024 * 1024
    static let maximumPendingCommandCount = 256

    let runID: UUID
    let attemptID: UUID
    let directoryURL: URL

    private let processedMessageIDsURL: URL
    private let drainLeaseURL: URL
    private let lock = NSLock()

    init(rootDirectoryURL: URL, runID: UUID, attemptID: UUID) throws {
        self.runID = runID
        self.attemptID = attemptID
        let runDirectoryURL = DetachedAgentRuntimePaths.runDirectoryURL(
            rootDirectoryURL: rootDirectoryURL,
            runID: runID
        )
        let attemptDirectoryURL = DetachedAgentRuntimePaths.attemptDirectoryURL(
            rootDirectoryURL: rootDirectoryURL,
            runID: runID,
            attemptID: attemptID
        )
        directoryURL = attemptDirectoryURL.appendingPathComponent("commands", isDirectory: true)
        processedMessageIDsURL = directoryURL.appendingPathComponent(
            "processed-message-ids.json",
            isDirectory: false
        )
        drainLeaseURL = directoryURL.appendingPathComponent("drain.lock", isDirectory: false)

        try DetachedAgentSecureFiles.ensureDirectory(rootDirectoryURL)
        try DetachedAgentSecureFiles.ensureDirectory(runDirectoryURL)
        try DetachedAgentSecureFiles.ensureDirectory(attemptDirectoryURL)
        try DetachedAgentSecureFiles.ensureDirectory(directoryURL)
    }

    /// Returns false for an already-pending or already-processed message ID.
    /// A reused ID with different contents fails rather than replacing the
    /// original command.
    @discardableResult
    func enqueue(_ envelope: DetachedAgentCommandEnvelope) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        try validate(envelope)

        let data = try Self.makeEncoder().encode(envelope)
        guard data.count <= Self.maximumEncodedCommandBytes else {
            throw DetachedAgentCommandMailboxError.payloadTooLarge(
                maximumBytes: Self.maximumEncodedCommandBytes
            )
        }
        if try processedMessageIDs().contains(envelope.messageID) { return false }

        let pendingFiles = try pendingCommandFileURLs()
        guard pendingFiles.count < Self.maximumPendingCommandCount else {
            throw DetachedAgentCommandMailboxError.tooManyPendingCommands(
                maximumCount: Self.maximumPendingCommandCount
            )
        }
        let destinationURL = commandFileURL(messageID: envelope.messageID)
        if try DetachedAgentSecureFiles.atomicDurableCreate(data, at: destinationURL) {
            return true
        }

        let existing = try decodeCommand(at: destinationURL)
        guard existing == envelope else {
            throw DetachedAgentCommandMailboxError.messageIDCollision(envelope.messageID)
        }
        return false
    }

    /// Calls `handler` in mailbox order. A command remains pending until the
    /// handler reports success; only then is its message ID durably recorded
    /// and its payload removed. Returning false stops the drain without losing
    /// that command or any command after it.
    @discardableResult
    func drain(
        handler: (DetachedAgentCommandEnvelope) throws -> Bool
    ) throws -> [DetachedAgentCommandEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        let drainLease = try DetachedAgentExclusiveFileLease(fileURL: drainLeaseURL)
        defer { withExtendedLifetime(drainLease) {} }

        var processedIDs = try processedMessageIDs()
        var decoded: [(url: URL, envelope: DetachedAgentCommandEnvelope)] = []
        for url in try pendingCommandFileURLs() {
            let envelope = try decodeCommand(at: url)
            if processedIDs.contains(envelope.messageID) {
                try DetachedAgentSecureFiles.removeRegularFileDurably(url)
                continue
            }
            decoded.append((url, envelope))
        }
        decoded.sort {
            if $0.envelope.sentAt != $1.envelope.sentAt {
                return $0.envelope.sentAt < $1.envelope.sentAt
            }
            return $0.envelope.messageID.uuidString < $1.envelope.messageID.uuidString
        }
        var handled: [DetachedAgentCommandEnvelope] = []
        for item in decoded {
            guard try handler(item.envelope) else { break }
            processedIDs.insert(item.envelope.messageID)
            try persistProcessedMessageIDs(processedIDs)
            try DetachedAgentSecureFiles.removeRegularFileDurably(item.url)
            handled.append(item.envelope)
        }
        return handled
    }

    private func persistProcessedMessageIDs(_ processedIDs: Set<UUID>) throws {
        let ledger = ProcessedMessageIDs(
            schemaVersion: DetachedAgentRuntimeProtocol.currentSchemaVersion,
            runID: runID,
            attemptID: attemptID,
            messageIDs: processedIDs.sorted { $0.uuidString < $1.uuidString }
        )
        try DetachedAgentSecureFiles.atomicDurableWrite(
            try Self.makeEncoder().encode(ledger),
            to: processedMessageIDsURL
        )
    }

    private func validate(_ envelope: DetachedAgentCommandEnvelope) throws {
        guard DetachedAgentRuntimeProtocol.supportsLiveAttemptSchemaVersion(
            envelope.schemaVersion
        ) else {
            throw DetachedAgentPersistenceError.unsupportedSchemaVersion(envelope.schemaVersion)
        }
        guard envelope.runID == runID else {
            throw DetachedAgentPersistenceError.runIDMismatch(expected: runID, actual: envelope.runID)
        }
        guard envelope.attemptID == attemptID else {
            throw DetachedAgentPersistenceError.attemptIDMismatch(
                expected: attemptID,
                actual: envelope.attemptID
            )
        }
    }

    private func decodeCommand(at url: URL) throws -> DetachedAgentCommandEnvelope {
        let envelope = try Self.makeDecoder().decode(
            DetachedAgentCommandEnvelope.self,
            from: DetachedAgentSecureFiles.readRegularFile(url)
        )
        try validate(envelope)
        // FileManager may canonicalize `/var` to `/private/var` while listing.
        // The direct-child listing already fixes the parent; bind payload to
        // its UUID filename without comparing those equivalent path spellings.
        guard commandFileURL(messageID: envelope.messageID).lastPathComponent
                == url.lastPathComponent else {
            throw DetachedAgentPersistenceError.invalidPersistencePath(url.path)
        }
        return envelope
    }

    private func processedMessageIDs() throws -> Set<UUID> {
        guard DetachedAgentSecureFiles.pathExistsWithoutFollowingLinks(processedMessageIDsURL) else {
            return []
        }
        let ledger = try Self.makeDecoder().decode(
            ProcessedMessageIDs.self,
            from: DetachedAgentSecureFiles.readRegularFile(processedMessageIDsURL)
        )
        guard DetachedAgentRuntimeProtocol.supportsLiveAttemptSchemaVersion(
            ledger.schemaVersion
        ) else {
            throw DetachedAgentPersistenceError.unsupportedSchemaVersion(ledger.schemaVersion)
        }
        guard ledger.runID == runID else {
            throw DetachedAgentPersistenceError.runIDMismatch(expected: runID, actual: ledger.runID)
        }
        guard ledger.attemptID == attemptID else {
            throw DetachedAgentPersistenceError.attemptIDMismatch(
                expected: attemptID,
                actual: ledger.attemptID
            )
        }
        return Set(ledger.messageIDs)
    }

    private func pendingCommandFileURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter {
            $0.pathExtension == "json"
                && $0.lastPathComponent != processedMessageIDsURL.lastPathComponent
        }
    }

    private func commandFileURL(messageID: UUID) -> URL {
        directoryURL.appendingPathComponent(
            "\(messageID.uuidString.lowercased()).json",
            isDirectory: false
        )
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private struct ProcessedMessageIDs: Codable {
        let schemaVersion: Int
        let runID: UUID
        let attemptID: UUID
        let messageIDs: [UUID]
    }
}
