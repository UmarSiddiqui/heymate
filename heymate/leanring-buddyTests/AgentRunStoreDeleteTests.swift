//
//  AgentRunStoreDeleteTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct AgentRunStoreDeleteTests {

    private struct WriteError: Error, LocalizedError {
        var errorDescription: String? { "Could not save agent runs" }
    }

    private final class PersistNotice: @unchecked Sendable {
        var didPost = false
    }

    private func makeTemporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRunStoreDeleteTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeRun(
        id: UUID = UUID(),
        status: AgentRunStatus,
        workspaceURL: URL,
        title: String = "Job"
    ) -> AgentRun {
        var run = AgentRun.queued(
            id: id,
            title: title,
            prompt: title,
            workspaceURL: workspaceURL,
            executor: .openCode,
            origin: .sandbox
        )
        run.status = status
        return run
    }

    @Test func deleteRemovesTerminalRunAndLeavesTheFolder() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "stay".write(to: workspace.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let storeFileURL = root.appendingPathComponent("agent-runs.json")
        let store = FileAgentRunStore(fileURL: storeFileURL)
        let finished = makeRun(status: .succeeded, workspaceURL: workspace, title: "finished")
        let sibling = makeRun(
            status: .failed,
            workspaceURL: root.appendingPathComponent("other", isDirectory: true),
            title: "sibling"
        )
        store.upsert(finished)
        store.upsert(sibling)

        #expect(store.delete(id: finished.id))
        #expect(store.run(id: finished.id) == nil)
        #expect(store.run(id: sibling.id)?.title == "sibling")
        #expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("note.txt").path))

        let reloaded = FileAgentRunStore(fileURL: storeFileURL)
        #expect(reloaded.run(id: finished.id) == nil)
        #expect(reloaded.run(id: sibling.id)?.title == "sibling")
    }

    @Test func deleteRefusesARunThatIsNotTerminal() {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileAgentRunStore(fileURL: root.appendingPathComponent("agent-runs.json"))
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)

        for status in [AgentRunStatus.running, .awaitingPlanApproval, .queued, .planning, .waitingForApproval] {
            let run = makeRun(status: status, workspaceURL: workspace, title: status.rawValue)
            store.upsert(run)
            #expect(store.delete(id: run.id) == false)
            #expect(store.run(id: run.id)?.status == status)
        }

        let reloaded = FileAgentRunStore(fileURL: root.appendingPathComponent("agent-runs.json"))
        #expect(reloaded.loadAll().count == 5)
        #expect(store.delete(id: UUID()) == false)
    }

    @Test func persistFailureRecordsDefaultsAndPostsNotification() {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsKey = "heymate.lastPersistError"
        let previous = UserDefaults.standard.string(forKey: defaultsKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        let notice = PersistNotice()
        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name("heymate.persistFailed"),
            object: nil,
            queue: nil
        ) { _ in
            notice.didPost = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let store = FileAgentRunStore(
            fileURL: root.appendingPathComponent("agent-runs.json"),
            durableWrite: { _, _ in throw WriteError() }
        )
        let run = makeRun(
            status: .succeeded,
            workspaceURL: root.appendingPathComponent("workspace", isDirectory: true)
        )
        store.upsert(run)

        #expect(notice.didPost)
        #expect(UserDefaults.standard.string(forKey: defaultsKey) == "Could not save agent runs")
        #expect(store.delete(id: run.id) == false)
        #expect(store.run(id: run.id)?.id == run.id)
    }

    @Test func deleteAgentRunRefreshesThePublishedList() {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileAgentRunStore(fileURL: root.appendingPathComponent("agent-runs.json"))
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let finished = makeRun(status: .succeeded, workspaceURL: workspace, title: "done")
        store.upsert(finished)

        let manager = makeManager(root: root, store: store)
        #expect(manager.agentRuns.contains { $0.id == finished.id })
        #expect(manager.deleteAgentRun(runID: finished.id))
        #expect(manager.agentRuns.contains { $0.id == finished.id } == false)

        let live = makeRun(status: .running, workspaceURL: workspace, title: "live")
        store.upsert(live)
        #expect(manager.deleteAgentRun(runID: live.id) == false)
        #expect(manager.agentRuns.contains { $0.id == live.id })
    }

    @Test func missingFolderIsReportedAndTheListEntryStays() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileAgentRunStore(fileURL: root.appendingPathComponent("agent-runs.json"))
        let missing = makeRun(
            status: .cancelled,
            workspaceURL: root.appendingPathComponent("gone", isDirectory: true),
            title: "gone"
        )
        store.upsert(missing)
        let manager = makeManager(root: root, store: store)

        manager.moveAgentFolderToTrash(runID: missing.id)
        #expect(manager.agentRevealErrorText == CompanionManager.missingAgentFolderMessage)
        #expect(manager.agentRuns.contains { $0.id == missing.id })
        #expect(manager.deleteAgentRun(runID: missing.id))
        #expect(manager.agentRuns.contains { $0.id == missing.id } == false)
    }

    @Test func trashMovesTheFolderThenRemovesTheRun() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "bytes".write(to: workspace.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let store = FileAgentRunStore(fileURL: root.appendingPathComponent("agent-runs.json"))
        let finished = makeRun(status: .succeeded, workspaceURL: workspace, title: "site")
        store.upsert(finished)
        let manager = makeManager(root: root, store: store)

        manager.moveAgentFolderToTrash(runID: finished.id)
        #expect(manager.agentRevealErrorText.isEmpty)
        #expect(FileManager.default.fileExists(atPath: workspace.path) == false)
        #expect(manager.agentRuns.contains { $0.id == finished.id } == false)
        #expect(FileAgentRunStore(fileURL: root.appendingPathComponent("agent-runs.json")).run(id: finished.id) == nil)
    }

    @Test func readyEntriesListsOnlyStoredRestorableSnapshots() throws {
        let root = makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let ledgerRoot = root.appendingPathComponent("ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try "before".write(to: workspace.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let run = makeRun(status: .succeeded, workspaceURL: workspace, title: "Change site")
        let ledger = FileAgentUndoLedger(rootDirectoryURL: ledgerRoot, recoverPreparedEntriesOnInit: false)
        let older = try ledger.prepareSnapshot(for: run)
        ledger.markReady(entryID: older.id)
        Thread.sleep(forTimeInterval: 0.05)
        let newer = try ledger.prepareSnapshot(for: run)
        ledger.markReady(entryID: newer.id)

        let ready = ledger.readyEntries()
        #expect(ready.map(\.id) == [newer.id, older.id])
        #expect(ledger.latestReadyEntry()?.id == newer.id)

        _ = try ledger.undo(entryID: older.id)
        #expect(ledger.readyEntries().map(\.id) == [newer.id])
        #expect(ledger.entry(id: older.id)?.status == .undone)
    }

    private func makeManager(root: URL, store: FileAgentRunStore) -> CompanionManager {
        CompanionManager(
            agentRunStore: store,
            standingOrderRepository: FileStandingOrderRepository(
                directoryURL: root.appendingPathComponent("orders", isDirectory: true)
            ),
            agentUndoLedger: FileAgentUndoLedger(
                rootDirectoryURL: root.appendingPathComponent("undo", isDirectory: true),
                recoverPreparedEntriesOnInit: false
            )
        )
    }
}
