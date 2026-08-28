//
//  AgentRunStoreTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct AgentRunStoreTests {

    private func makeTemporaryStoreFileURL() -> URL {
        let uniqueSubdirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRunStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: uniqueSubdirectory, withIntermediateDirectories: true)
        return uniqueSubdirectory.appendingPathComponent("agent-runs.json")
    }

    private func makeRun(id: UUID = UUID(), createdAt: Date, title: String = "Job") -> AgentRun {
        var run = AgentRun.queued(
            id: id,
            title: title,
            prompt: title,
            workspaceURL: URL(fileURLWithPath: "/tmp/\(id.uuidString)", isDirectory: true),
            executor: .openCode,
            origin: .sandbox,
            createdAt: createdAt
        )
        run.status = .succeeded
        return run
    }

    @Test func upsertPersistsAcrossInstancesNewestFirst() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { try? FileManager.default.removeItem(at: storeFileURL.deletingLastPathComponent()) }

        let older = makeRun(createdAt: Date(timeIntervalSinceReferenceDate: 10), title: "older")
        let newer = makeRun(createdAt: Date(timeIntervalSinceReferenceDate: 20), title: "newer")
        let firstStore = FileAgentRunStore(fileURL: storeFileURL)
        firstStore.upsert(older)
        firstStore.upsert(newer)

        let reloaded = FileAgentRunStore(fileURL: storeFileURL).loadAll()
        #expect(reloaded.map(\.title) == ["newer", "older"])
    }

    @Test func updateMutatesExistingRecord() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { try? FileManager.default.removeItem(at: storeFileURL.deletingLastPathComponent()) }

        let run = makeRun(createdAt: Date())
        let store = FileAgentRunStore(fileURL: storeFileURL)
        store.upsert(run)
        _ = store.update(id: run.id) { current in
            current.status = .failed
            current.error = "Timed out"
        }
        #expect(store.run(id: run.id)?.status == .failed)
        #expect(store.run(id: run.id)?.error == "Timed out")
    }

    @Test func corruptFileDegradesToEmpty() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { try? FileManager.default.removeItem(at: storeFileURL.deletingLastPathComponent()) }
        try? "not json".write(to: storeFileURL, atomically: true, encoding: .utf8)
        #expect(FileAgentRunStore(fileURL: storeFileURL).loadAll().isEmpty)
    }

    @Test func reconcileInterruptedRunsClosesOnlyProcessBackedStatesAndPersists() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { try? FileManager.default.removeItem(at: storeFileURL.deletingLastPathComponent()) }

        let interruptedStatuses: [AgentRunStatus] = [
            .queued,
            .planning,
            .running,
            .waitingForApproval
        ]
        let preservedStatuses: [AgentRunStatus] = [
            .awaitingPlanApproval,
            .succeeded,
            .failed,
            .cancelled
        ]
        let finishedAt = Date(timeIntervalSinceReferenceDate: 123)
        let store = FileAgentRunStore(fileURL: storeFileURL)

        var runsByID: [UUID: AgentRunStatus] = [:]
        for status in interruptedStatuses + preservedStatuses {
            var run = AgentRun.queued(
                id: UUID(),
                title: status.rawValue,
                prompt: status.rawValue,
                workspaceURL: URL(fileURLWithPath: "/tmp/\(status.rawValue)", isDirectory: true),
                executor: .claudeCode,
                origin: .sandbox
            )
            run.status = status
            run.pid = 42
            run.pendingApprovalID = "approval"
            store.upsert(run)
            runsByID[run.id] = status
        }

        let reconciledIDs = Set(store.reconcileInterruptedRuns(finishedAt: finishedAt))
        let reloaded = FileAgentRunStore(fileURL: storeFileURL)

        for (id, originalStatus) in runsByID {
            let run = reloaded.run(id: id)
            if interruptedStatuses.contains(originalStatus) {
                #expect(reconciledIDs.contains(id))
                #expect(run?.status == .failed)
                #expect(run?.error == "Interrupted — HeyMate quit while this was running.")
                #expect(run?.latestAction == "Interrupted")
                #expect(run?.finishedAt == finishedAt)
                #expect(run?.pid == nil)
                #expect(run?.pendingApprovalID.isEmpty == true)
            } else {
                #expect(!reconciledIDs.contains(id))
                #expect(run?.status == originalStatus)
                #expect(run?.finishedAt == nil)
                #expect(run?.pid == 42)
                #expect(run?.pendingApprovalID == "approval")
            }
        }
    }

    @Test func activityAndQueuedFollowUpsPersistAcrossInstances() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { try? FileManager.default.removeItem(at: storeFileURL.deletingLastPathComponent()) }

        var run = AgentRun.queued(
            id: UUID(),
            title: "Build site",
            prompt: "Build a site",
            workspaceURL: URL(fileURLWithPath: "/tmp/build-site", isDirectory: true),
            executor: .codex,
            origin: .sandbox
        )
        run.appendActivity(kind: .progress, text: "Reading package.json")
        run.queuedFollowUpInstructions = ["Also add dark mode"]

        FileAgentRunStore(fileURL: storeFileURL).upsert(run)
        let reloaded = FileAgentRunStore(fileURL: storeFileURL).run(id: run.id)

        #expect(reloaded?.activity.map(\.text).contains("Build a site") == true)
        #expect(reloaded?.activity.map(\.text).contains("Reading package.json") == true)
        #expect(reloaded?.queuedFollowUpInstructions == ["Also add dark mode"])
    }

    @Test func previewFindsLocalServerFromAgentActivity() {
        var run = AgentRun.queued(
            id: UUID(),
            title: "Build site",
            prompt: "Build a site",
            workspaceURL: URL(fileURLWithPath: "/tmp/build-site", isDirectory: true),
            executor: .openCode,
            origin: .sandbox
        )
        run.appendActivity(kind: .agent, text: "Ready at http://0.0.0.0:5173/game")

        #expect(
            AgentWorkspacePreviewTarget.resolve(for: run)
                == .localServer(URL(string: "http://127.0.0.1:5173/game")!)
        )
    }

    @Test func dayGroupingUsesTodayYesterdayAndDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_776_960_000) // 2026-05-01 00:00 UTC-ish; grouping uses calendar
        let today = now
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let earlier = calendar.date(byAdding: .day, value: -5, to: now)!

        let sections = AgentRunDayGrouping.sections(
            from: [
                makeRun(createdAt: today, title: "t"),
                makeRun(createdAt: yesterday, title: "y"),
                makeRun(createdAt: earlier, title: "e")
            ],
            now: now,
            calendar: calendar
        )
        #expect(sections.map(\.title) == ["TODAY", "YESTERDAY", sections[2].title])
        #expect(sections[0].runs.map(\.title) == ["t"])
        #expect(sections[2].title != "TODAY")
        #expect(sections[2].title != "YESTERDAY")
    }
}

@MainActor
struct HeadlessAgentLauncherTests {

    @Test func completedWriteLegPersistsMeasuredReceiptChanges() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-receipt-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        let storeFileURL = rootURL.appendingPathComponent("runs.json")
        let undoRootURL = rootURL.appendingPathComponent("undo", isDirectory: true)
        let executableURL = rootURL.appendingPathComponent("fake-agent.sh")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try "baseline\n".write(
            to: workspaceURL.appendingPathComponent("Existing.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/bin/sh\nprintf 'agent output\\n' > Added.txt\n".write(
            to: executableURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )

        let store = FileAgentRunStore(fileURL: storeFileURL)
        let undoLedger = FileAgentUndoLedger(rootDirectoryURL: undoRootURL)
        var run = AgentRun.queued(
            id: UUID(),
            title: "Create file",
            prompt: "Create file",
            workspaceURL: workspaceURL,
            executor: .claudeCode,
            origin: .attached,
            sessionIdentifier: UUID().uuidString.lowercased()
        )
        run.status = .awaitingPlanApproval
        run.planText = "Add one file."
        store.upsert(run)

        let launcher = HeadlessAgentLauncher(store: store, undoLedger: undoLedger)
        launcher.resolveExecutable = { _ in executableURL }
        launcher.approvePlan(runID: run.id)

        for _ in 0..<100 {
            if store.run(id: run.id)?.workspaceChangeSummary != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let completedRun = try #require(store.run(id: run.id))
        #expect(completedRun.status == .succeeded)
        #expect(completedRun.workspaceChangeSummary?.addedCount == 1)
        #expect(completedRun.workspaceChangeSummary?.modifiedCount == 0)
        #expect(completedRun.workspaceChangeSummary?.deletedCount == 0)
        #expect(completedRun.workspaceChangeSummary?.displayedChanges == [
            AgentWorkspaceChange(kind: .added, path: "Added.txt")
        ])

        let reloadedStore = FileAgentRunStore(fileURL: storeFileURL)
        #expect(reloadedStore.run(id: run.id)?.workspaceChangeSummary == completedRun.workspaceChangeSummary)
    }

    @Test func followUpQueuesWhileAgentIsBusy() {
        let storeFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeFileURL) }
        let store = FileAgentRunStore(fileURL: storeFileURL)
        let undoLedger = FileAgentUndoLedger(
            rootDirectoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("undo-\(UUID().uuidString)", isDirectory: true)
        )
        var run = AgentRun.queued(
            id: UUID(),
            title: "Build site",
            prompt: "Build a site",
            workspaceURL: URL(fileURLWithPath: "/tmp/build-site", isDirectory: true),
            executor: .claudeCode,
            origin: .sandbox
        )
        run.status = .running
        store.upsert(run)
        let launcher = HeadlessAgentLauncher(store: store, undoLedger: undoLedger)

        let accepted = launcher.sendFollowUp(runID: run.id, instruction: "Also add dark mode")

        #expect(accepted)
        #expect(store.run(id: run.id)?.status == .running)
        #expect(store.run(id: run.id)?.queuedFollowUpInstructions == ["Also add dark mode"])
        #expect(store.run(id: run.id)?.activity.last?.text == "Follow-up queued for after the current step")
    }

    @Test func statusQuestionAnswersImmediatelyWithoutQueueingWork() {
        let storeFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: storeFileURL) }
        let store = FileAgentRunStore(fileURL: storeFileURL)
        let undoLedger = FileAgentUndoLedger(
            rootDirectoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("undo-\(UUID().uuidString)", isDirectory: true)
        )
        var run = AgentRun.queued(
            id: UUID(),
            title: "Build site",
            prompt: "Build a site",
            workspaceURL: URL(fileURLWithPath: "/tmp/build-site", isDirectory: true),
            executor: .openCode,
            origin: .sandbox
        )
        run.status = .running
        run.startedAt = Date().addingTimeInterval(-125)
        run.latestAction = "Running tests"
        store.upsert(run)
        let launcher = HeadlessAgentLauncher(store: store, undoLedger: undoLedger)

        let accepted = launcher.sendFollowUp(runID: run.id, instruction: "What are you up to, isn't it done?")

        #expect(accepted)
        #expect(store.run(id: run.id)?.queuedFollowUpInstructions.isEmpty == true)
        #expect(store.run(id: run.id)?.activity.last?.kind == .agent)
        #expect(store.run(id: run.id)?.activity.last?.text.contains("Still working") == true)
        #expect(store.run(id: run.id)?.activity.last?.text.contains("Running tests") == true)
    }

    @Test func emptyPromptFailsWithoutCreatingAFolder() {
        let storeFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-\(UUID().uuidString).json")
        let store = FileAgentRunStore(fileURL: storeFileURL)
        let undoLedger = FileAgentUndoLedger(
            rootDirectoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("undo-\(UUID().uuidString)", isDirectory: true)
        )
        let launcher = HeadlessAgentLauncher(store: store, undoLedger: undoLedger)
        launcher.resolveExecutable = { _ in nil }

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        let runID = launcher.startSandbox(
            prompt: "   ",
            executor: .openCode,
            screenContext: AgentScreenContext(activeAppName: "Xcode", windowTitle: "App"),
            homeDirectoryURL: home
        )
        let run = store.run(id: runID)
        #expect(run?.status == .failed)
        #expect(run?.error == "Say what you want the agent to do.")
        let parent = AgentFolderNaming.sandboxParentURL(homeDirectoryURL: home)
        #expect(FileManager.default.fileExists(atPath: parent.path) == false)
    }

    /// A job that cannot start leaves nothing behind. The prompt is already on
    /// the run record, so a folder would only be litter the user has to clean
    /// out of ~/Projects/heymate.
    @Test func missingCLIFailsWithoutCreatingAFolder() {
        let storeFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-\(UUID().uuidString).json")
        let store = FileAgentRunStore(fileURL: storeFileURL)
        let undoLedger = FileAgentUndoLedger(
            rootDirectoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("undo-\(UUID().uuidString)", isDirectory: true)
        )
        let launcher = HeadlessAgentLauncher(store: store, undoLedger: undoLedger)
        launcher.resolveExecutable = { _ in nil }

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let runID = launcher.startSandbox(
            prompt: "make a landing page",
            executor: .claudeCode,
            screenContext: AgentScreenContext(activeAppName: "Safari", windowTitle: "Docs"),
            homeDirectoryURL: home
        )
        let run = store.run(id: runID)
        #expect(run?.status == .failed)
        #expect(run?.error.contains("claude") == true)
        #expect(run?.prompt == "make a landing page")

        let parent = AgentFolderNaming.sandboxParentURL(homeDirectoryURL: home)
        #expect(FileManager.default.fileExists(atPath: parent.path) == false)
    }

    /// A signed-out CLI is caught before anything is spawned, and the run card
    /// carries the remedy rather than an exit code.
    @Test func signedOutExecutorFailsWithItsRemedy() {
        let storeFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-\(UUID().uuidString).json")
        let store = FileAgentRunStore(fileURL: storeFileURL)
        let undoLedger = FileAgentUndoLedger(
            rootDirectoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("undo-\(UUID().uuidString)", isDirectory: true)
        )
        let launcher = HeadlessAgentLauncher(store: store, undoLedger: undoLedger)
        launcher.resolveExecutable = { _ in URL(fileURLWithPath: "/usr/bin/true") }
        launcher.readinessForExecutor = { _ in
            HeadlessExecutorReadiness(
                state: .notSignedIn,
                detail: "Signed out",
                remedy: "Run `claude` in Terminal and sign in with /login, then try again."
            )
        }

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let runID = launcher.startSandbox(
            prompt: "make a landing page",
            executor: .claudeCode,
            screenContext: AgentScreenContext(activeAppName: "Safari", windowTitle: "Docs"),
            homeDirectoryURL: home
        )
        let run = store.run(id: runID)
        #expect(run?.status == .failed)
        #expect(run?.error.contains("/login") == true)

        let parent = AgentFolderNaming.sandboxParentURL(homeDirectoryURL: home)
        #expect(FileManager.default.fileExists(atPath: parent.path) == false)
    }

    @Test func titleTruncatesLongPrompts() {
        let long = String(repeating: "a", count: 80)
        let title = HeadlessAgentLauncher.title(from: long)
        #expect(title.count == 58)
        #expect(title.hasSuffix("…"))
    }
}
