//
//  AgentPersistenceSecurityTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct AgentPersistenceSecurityTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentPersistenceSecurityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func makeRun(id: UUID = UUID(), workspaceURL: URL) -> AgentRun {
        var run = AgentRun.queued(
            id: id,
            title: "Test run",
            prompt: "Change one file",
            workspaceURL: workspaceURL,
            executor: .codex,
            origin: .attached,
            sessionIdentifier: "session"
        )
        run.status = .running
        return run
    }

    @Test func runStoreUsesPrivatePermissionsAndCanPreserveDetachedRuns() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let storeDirectoryURL = rootURL.appendingPathComponent("store", isDirectory: true)
        let fileURL = storeDirectoryURL.appendingPathComponent("agent-runs.json")
        let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        let preservedRun = makeRun(workspaceURL: workspaceURL)
        let interruptedRun = makeRun(workspaceURL: workspaceURL)
        let store = FileAgentRunStore(fileURL: fileURL)
        store.upsert(preservedRun)
        store.upsert(interruptedRun)

        let reconciled = store.reconcileInterruptedRuns(
            excludingRunIDs: [preservedRun.id],
            finishedAt: Date(timeIntervalSince1970: 100)
        )

        #expect(reconciled == [interruptedRun.id])
        #expect(store.run(id: preservedRun.id)?.status == .running)
        #expect(store.run(id: interruptedRun.id)?.status == .failed)
        #expect(try permissions(at: storeDirectoryURL) == 0o700)
        #expect(try permissions(at: fileURL) == 0o600)
    }

    @Test func preparedUndoStaysUnavailableWhileDetachedWriterLives() throws {
        let rootURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        let ledgerURL = rootURL.appendingPathComponent("ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try Data("before".utf8).write(to: workspaceURL.appendingPathComponent("file.txt"))
        let run = makeRun(workspaceURL: workspaceURL)

        let writerLedger = FileAgentUndoLedger(
            rootDirectoryURL: ledgerURL,
            recoverPreparedEntriesOnInit: false
        )
        let entry = try writerLedger.prepareSnapshot(for: run)
        #expect(writerLedger.entry(id: entry.id)?.status == .prepared)

        let relaunchedLedger = FileAgentUndoLedger(
            rootDirectoryURL: ledgerURL,
            recoverPreparedEntriesOnInit: false
        )
        relaunchedLedger.recoverInterruptedPreparedEntries(excludingRunIDs: [run.id])
        #expect(relaunchedLedger.entry(id: entry.id)?.status == .prepared)
        #expect(relaunchedLedger.latestReadyEntry() == nil)

        relaunchedLedger.recoverInterruptedPreparedEntries()
        #expect(relaunchedLedger.entry(id: entry.id)?.status == .ready)
        #expect(try permissions(at: ledgerURL) == 0o700)
        #expect(try permissions(at: ledgerURL.appendingPathComponent("ledger.json")) == 0o600)
    }
}
