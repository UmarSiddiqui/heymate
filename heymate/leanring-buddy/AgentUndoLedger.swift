//
//  AgentUndoLedger.swift
//  leanring-buddy
//
//  Recoverable workspace snapshots for approved agent work. Snapshot is
//  complete before write-enabled leg starts. Undo swaps current workspace
//  into a recovery folder, then restores approved baseline.
//

import Foundation

nonisolated enum AgentUndoEntryStatus: String, Codable, Equatable {
    case prepared
    case ready
    case undone
}

nonisolated struct AgentUndoEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let runID: UUID
    let runTitle: String
    let workspacePath: String
    let snapshotPath: String
    var recoveryPath: String
    let createdAt: Date
    var completedAt: Date?
    var undoneAt: Date?
    var status: AgentUndoEntryStatus
}

nonisolated enum AgentUndoLedgerError: LocalizedError, Equatable {
    case workspaceMissing
    case snapshotMissing
    case workspaceTooLarge(maximumBytes: Int64)
    case couldNotCreateSnapshot(String)
    case couldNotRestore(String)

    var errorDescription: String? {
        switch self {
        case .workspaceMissing:
            return "Workspace is missing, so HeyMate cannot prepare a safe undo."
        case .snapshotMissing:
            return "Undo snapshot is missing."
        case .workspaceTooLarge(let maximumBytes):
            let megabytes = maximumBytes / 1_048_576
            return "Workspace exceeds the \(megabytes) MB undo limit. Nothing was started."
        case .couldNotCreateSnapshot(let detail):
            return "Could not prepare undo: \(detail)"
        case .couldNotRestore(let detail):
            return "Could not restore workspace: \(detail)"
        }
    }
}

@MainActor
final class FileAgentUndoLedger {

    /// Refuse work rather than promise undo while silently skipping bytes.
    /// Sandbox jobs are tiny; large attached repos receive a clear blocker.
    nonisolated static let maximumSnapshotBytes: Int64 = 512 * 1_048_576

    private let rootDirectoryURL: URL
    private let ledgerFileURL: URL
    private let fileManager: FileManager
    private let durableWrite: (Data, URL) throws -> Void
    private var entries: [AgentUndoEntry]

    init(
        rootDirectoryURL: URL,
        fileManager: FileManager = .default,
        recoverPreparedEntriesOnInit: Bool = true,
        durableWrite: @escaping (Data, URL) throws -> Void = {
            try DetachedAgentSecureFiles.atomicDurableWrite($0, to: $1)
        }
    ) {
        self.rootDirectoryURL = rootDirectoryURL
        self.ledgerFileURL = rootDirectoryURL.appendingPathComponent("ledger.json")
        self.fileManager = fileManager
        self.durableWrite = durableWrite
        try? fileManager.createDirectory(
            at: rootDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootDirectoryURL.path
        )
        if fileManager.fileExists(atPath: ledgerFileURL.path) {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: ledgerFileURL.path
            )
        }
        if let data = try? Data(contentsOf: ledgerFileURL),
           let decoded = try? JSONDecoder().decode([AgentUndoEntry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
        if recoverPreparedEntriesOnInit {
            recoverInterruptedPreparedEntries()
        }
    }

    func prepareSnapshot(for run: AgentRun) throws -> AgentUndoEntry {
        let workspaceURL = run.workspaceURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: workspaceURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AgentUndoLedgerError.workspaceMissing
        }

        let standardizedLedgerRoot = rootDirectoryURL.standardizedFileURL.path
        let workspacePrefix = workspaceURL.path.hasSuffix("/") ? workspaceURL.path : workspaceURL.path + "/"
        guard !standardizedLedgerRoot.hasPrefix(workspacePrefix) else {
            throw AgentUndoLedgerError.couldNotCreateSnapshot(
                "Choose a workspace that does not contain HeyMate's Undo Ledger."
            )
        }

        let byteCount = try snapshotByteCount(for: workspaceURL)
        guard byteCount <= Self.maximumSnapshotBytes else {
            throw AgentUndoLedgerError.workspaceTooLarge(maximumBytes: Self.maximumSnapshotBytes)
        }

        let entryID = UUID()
        let entryDirectoryURL = rootDirectoryURL.appendingPathComponent(entryID.uuidString, isDirectory: true)
        let snapshotURL = entryDirectoryURL.appendingPathComponent("before", isDirectory: true)
        do {
            try fileManager.createDirectory(at: entryDirectoryURL, withIntermediateDirectories: true)
            try fileManager.copyItem(at: workspaceURL, to: snapshotURL)
        } catch {
            try? fileManager.removeItem(at: entryDirectoryURL)
            throw AgentUndoLedgerError.couldNotCreateSnapshot(error.localizedDescription)
        }

        let entry = AgentUndoEntry(
            id: entryID,
            runID: run.id,
            runTitle: run.title,
            workspacePath: workspaceURL.path,
            snapshotPath: snapshotURL.path,
            recoveryPath: "",
            createdAt: Date(),
            completedAt: nil,
            undoneAt: nil,
            status: .prepared
        )
        var candidateEntries = entries
        candidateEntries.append(entry)
        do {
            try persistDurably(candidateEntries)
        } catch {
            try? fileManager.removeItem(at: entryDirectoryURL)
            throw AgentUndoLedgerError.couldNotCreateSnapshot(error.localizedDescription)
        }
        entries = candidateEntries
        return entry
    }

    /// Removes a baseline prepared for work that never started. Ledger update
    /// commits before snapshot deletion, so a failed discard keeps a safe (if
    /// unnecessary) recovery entry rather than losing an undo record.
    func discardPrepared(entryID: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.id == entryID }),
              entries[index].status == .prepared else { return }
        let entry = entries[index]
        var candidateEntries = entries
        candidateEntries.remove(at: index)
        try persistDurably(candidateEntries)
        entries = candidateEntries

        let snapshotURL = URL(fileURLWithPath: entry.snapshotPath, isDirectory: true)
        let entryDirectoryURL = snapshotURL.deletingLastPathComponent()
        try? fileManager.removeItem(at: entryDirectoryURL)
    }

    func markReady(entryID: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }),
              entries[index].status == .prepared else { return }
        entries[index].status = .ready
        entries[index].completedAt = Date()
        persist()
    }

    func latestReadyEntry() -> AgentUndoEntry? {
        entries
            .filter { $0.status == .ready }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    func entry(id: UUID) -> AgentUndoEntry? {
        entries.first { $0.id == id }
    }

    /// Current workspace is retained beside snapshot as `after-undo-*`.
    /// Failed restore moves it back, so this method never knowingly leaves
    /// workspace absent.
    func undo(entryID: UUID) throws -> AgentUndoEntry {
        guard let index = entries.firstIndex(where: { $0.id == entryID }),
              entries[index].status == .ready else {
            throw AgentUndoLedgerError.snapshotMissing
        }

        let entry = entries[index]
        let workspaceURL = URL(fileURLWithPath: entry.workspacePath, isDirectory: true).standardizedFileURL
        let snapshotURL = URL(fileURLWithPath: entry.snapshotPath, isDirectory: true).standardizedFileURL
        var snapshotIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: snapshotURL.path, isDirectory: &snapshotIsDirectory),
              snapshotIsDirectory.boolValue else {
            throw AgentUndoLedgerError.snapshotMissing
        }

        let entryDirectoryURL = snapshotURL.deletingLastPathComponent()
        let recoveryURL = entryDirectoryURL.appendingPathComponent(
            "after-undo-\(Int(Date().timeIntervalSince1970))",
            isDirectory: true
        )
        let workspaceExisted = fileManager.fileExists(atPath: workspaceURL.path)

        do {
            if workspaceExisted {
                try fileManager.moveItem(at: workspaceURL, to: recoveryURL)
            }
            try fileManager.copyItem(at: snapshotURL, to: workspaceURL)
        } catch {
            if !fileManager.fileExists(atPath: workspaceURL.path), workspaceExisted {
                try? fileManager.moveItem(at: recoveryURL, to: workspaceURL)
            }
            throw AgentUndoLedgerError.couldNotRestore(error.localizedDescription)
        }

        entries[index].status = .undone
        entries[index].undoneAt = Date()
        entries[index].recoveryPath = workspaceExisted ? recoveryURL.path : ""
        persist()
        return entries[index]
    }

    nonisolated static func appSupportDirectoryURL() -> URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupportDirectory
            .appendingPathComponent("heymate", isDirectory: true)
            .appendingPathComponent("undo-ledger", isDirectory: true)
    }

    private func snapshotByteCount(for workspaceURL: URL) throws -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: workspaceURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else { return 0 }

        var totalBytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            totalBytes += Int64(values.fileSize ?? 0)
            if totalBytes > Self.maximumSnapshotBytes { return totalBytes }
        }
        return totalBytes
    }

    /// A `.prepared` entry means its baseline copy completed before a
    /// write-enabled agent leg started. If HeyMate exits before that leg can
    /// report its terminal event, no in-memory callback remains to mark the
    /// entry ready. On the next launch, make that intact baseline undoable.
    ///
    /// Only snapshots at the path generated by this ledger are recovered.
    /// Missing or edited ledger records stay unavailable rather than making
    /// an unrelated directory eligible for restore.
    func recoverInterruptedPreparedEntries(
        excludingRunIDs: Set<UUID> = [],
        recoveredAt: Date = Date()
    ) {
        var didRecoverEntry = false

        for index in entries.indices where entries[index].status == .prepared {
            let entry = entries[index]
            guard !excludingRunIDs.contains(entry.runID) else { continue }
            let expectedSnapshotURL = rootDirectoryURL
                .appendingPathComponent(entry.id.uuidString, isDirectory: true)
                .appendingPathComponent("before", isDirectory: true)
                .standardizedFileURL
            let persistedSnapshotURL = URL(
                fileURLWithPath: entry.snapshotPath,
                isDirectory: true
            ).standardizedFileURL

            guard persistedSnapshotURL.path == expectedSnapshotURL.path else { continue }

            var snapshotIsDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: persistedSnapshotURL.path,
                isDirectory: &snapshotIsDirectory
            ), snapshotIsDirectory.boolValue else { continue }

            entries[index].status = .ready
            entries[index].completedAt = entries[index].completedAt ?? recoveredAt
            didRecoverEntry = true
        }

        if didRecoverEntry {
            persist()
        }
    }

    private func persist() {
        try? persistDurably(entries)
    }

    private func persistDurably(_ entries: [AgentUndoEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try durableWrite(encoder.encode(entries), ledgerFileURL)
    }
}
