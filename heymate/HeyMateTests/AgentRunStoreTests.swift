//
//  AgentRunStoreTests.swift
//  HeyMateTests
//

import Darwin
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

    private struct StubbornProcessTreeFixture {
        let executableURL: URL
        let rootPIDURL: URL
        let childPIDURL: URL
        let grandchildPIDURL: URL

        var pidFileURLs: [URL] {
            [rootPIDURL, childPIDURL, grandchildPIDURL]
        }
    }

    private func makeStubbornProcessTreeFixture(
        in directoryURL: URL
    ) throws -> StubbornProcessTreeFixture {
        let executableURL = directoryURL.appendingPathComponent("fake-agent.sh")
        let childScriptURL = directoryURL.appendingPathComponent("fake-child.sh")
        let grandchildScriptURL = directoryURL.appendingPathComponent("fake-grandchild.sh")
        let rootPIDURL = directoryURL.appendingPathComponent("root.pid")
        let childPIDURL = directoryURL.appendingPathComponent("child.pid")
        let grandchildPIDURL = directoryURL.appendingPathComponent("grandchild.pid")

        try """
        #!/bin/sh
        trap '' TERM
        printf '%s\\n' "$$" > "\(rootPIDURL.path)"
        /bin/sh "\(childScriptURL.path)" &
        wait
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        trap '' TERM
        printf '%s\\n' "$$" > "\(childPIDURL.path)"
        /bin/sh "\(grandchildScriptURL.path)" &
        wait
        """.write(to: childScriptURL, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        trap '' TERM
        printf '%s\\n' "$$" > "\(grandchildPIDURL.path)"
        while :; do sleep 30; done
        """.write(to: grandchildScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executableURL.path
        )

        return StubbornProcessTreeFixture(
            executableURL: executableURL,
            rootPIDURL: rootPIDURL,
            childPIDURL: childPIDURL,
            grandchildPIDURL: grandchildPIDURL
        )
    }

    private func makeWriteLegRun(
        rootURL: URL,
        fixture: StubbornProcessTreeFixture
    ) throws -> (
        launcher: HeadlessAgentLauncher,
        store: FileAgentRunStore,
        undoLedger: FileAgentUndoLedger,
        run: AgentRun
    ) {
        let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try "baseline\n".write(
            to: workspaceURL.appendingPathComponent("Existing.txt"),
            atomically: true,
            encoding: .utf8
        )

        let store = FileAgentRunStore(fileURL: rootURL.appendingPathComponent("runs.json"))
        let undoLedger = FileAgentUndoLedger(
            rootDirectoryURL: rootURL.appendingPathComponent("undo", isDirectory: true)
        )
        var run = AgentRun.queued(
            id: UUID(),
            title: "Lifecycle test",
            prompt: "Exercise lifecycle",
            workspaceURL: workspaceURL,
            executor: .claudeCode,
            origin: .attached,
            sessionIdentifier: UUID().uuidString.lowercased()
        )
        run.status = .awaitingPlanApproval
        run.planText = "Run the fixture."
        store.upsert(run)

        let launcher = HeadlessAgentLauncher(store: store, undoLedger: undoLedger)
        launcher.detachedExecutionEnabled = false
        launcher.resolveExecutable = { _ in fixture.executableURL }
        return (launcher, store, undoLedger, run)
    }

    private func processIdentifiers(
        from fixture: StubbornProcessTreeFixture
    ) throws -> [pid_t] {
        try fixture.pidFileURLs.map { url in
            let text = try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return try #require(pid_t(text))
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(7),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await clock.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    nonisolated private static func processExists(_ processID: pid_t) -> Bool {
        kill(processID, 0) == 0 || errno == EPERM
    }

    nonisolated private static func terminateFixtureIfNeeded(
        _ fixture: StubbornProcessTreeFixture
    ) {
        guard let text = try? String(contentsOf: fixture.rootPIDURL, encoding: .utf8),
              let processID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              processID > 1,
              processExists(processID) else { return }
        kill(-processID, SIGKILL)
    }

    @Test func cancelWaitsForWholeProcessTreeAndIsIdempotent() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let fixture = try makeStubbornProcessTreeFixture(in: rootURL)
        defer {
            Self.terminateFixtureIfNeeded(fixture)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let harness = try makeWriteLegRun(rootURL: rootURL, fixture: fixture)
        let runID = harness.run.id
        var terminalEventCount = 0
        harness.launcher.onEvent = { eventRunID, event in
            guard eventRunID == runID else { return }
            if case .finished = event { terminalEventCount += 1 }
        }
        harness.launcher.approvePlan(runID: runID)

        let treeStarted = await waitUntil {
            fixture.pidFileURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        }
        #expect(treeStarted)
        let processIDs = try processIdentifiers(from: fixture)

        harness.launcher.cancel(runID: runID)
        harness.launcher.cancel(runID: runID)

        let stoppingRun = try #require(harness.store.run(id: runID))
        #expect(!stoppingRun.status.isTerminal)
        #expect(stoppingRun.latestAction == "Stopping safely…")
        #expect(harness.undoLedger.latestReadyEntry() == nil)
        #expect(
            stoppingRun.activity.filter { $0.text == "Stopping safely…" }.count == 1
        )

        let cancelled = await waitUntil {
            harness.store.run(id: runID)?.status == .cancelled
        }
        #expect(cancelled)
        #expect(processIDs.allSatisfy { !Self.processExists($0) })
        #expect(harness.undoLedger.latestReadyEntry()?.runID == runID)
        #expect(terminalEventCount == 1)

        // Let already-enqueued waitpid callbacks run. They must not overwrite
        // the cancellation after its process-group waiter finalized it.
        for _ in 0..<20 { await Task.yield() }
        #expect(harness.store.run(id: runID)?.status == .cancelled)
        #expect(terminalEventCount == 1)
    }

    @Test func timeoutStaysNonTerminalUntilWholeProcessTreeStops() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let fixture = try makeStubbornProcessTreeFixture(in: rootURL)
        defer {
            Self.terminateFixtureIfNeeded(fixture)
            try? FileManager.default.removeItem(at: rootURL)
        }

        let harness = try makeWriteLegRun(rootURL: rootURL, fixture: fixture)
        let runID = harness.run.id
        var timeoutContinuation: AsyncStream<Void>.Continuation?
        let timeoutSignal = AsyncStream<Void> { continuation in
            timeoutContinuation = continuation
        }
        harness.launcher.waitForRuntimeLimit = { _ in
            for await _ in timeoutSignal { return }
        }
        harness.launcher.approvePlan(runID: runID)

        let treeStarted = await waitUntil {
            fixture.pidFileURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        }
        #expect(treeStarted)
        let processIDs = try processIdentifiers(from: fixture)

        timeoutContinuation?.yield(())
        timeoutContinuation?.finish()

        let beganStopping = await waitUntil(timeout: .seconds(3)) {
            harness.store.run(id: runID)?.latestAction
                == "Timed out — stopping safely…"
        }
        #expect(beganStopping)
        let stoppingRun = try #require(harness.store.run(id: runID))
        #expect(!stoppingRun.status.isTerminal)
        #expect(harness.undoLedger.latestReadyEntry() == nil)

        let failed = await waitUntil {
            harness.store.run(id: runID)?.status == .failed
        }
        #expect(failed)
        #expect(harness.store.run(id: runID)?.error == "Timed out")
        #expect(processIDs.allSatisfy { !Self.processExists($0) })
        #expect(harness.undoLedger.latestReadyEntry()?.runID == runID)
    }

    @Test func terminalTakeoverClearsSessionOwnershipAndQueuedFollowUps() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-takeover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let storeFileURL = rootURL.appendingPathComponent("runs.json")
        let store = FileAgentRunStore(fileURL: storeFileURL)
        let undoLedger = FileAgentUndoLedger(
            rootDirectoryURL: rootURL.appendingPathComponent("undo", isDirectory: true)
        )
        var run = AgentRun.queued(
            id: UUID(),
            title: "Take over",
            prompt: "Take over",
            workspaceURL: workspaceURL,
            executor: .claudeCode,
            origin: .attached,
            sessionIdentifier: "owned-session"
        )
        run.status = .succeeded
        run.queuedFollowUpInstructions = ["Queued one", "Queued two"]
        store.upsert(run)
        let launcher = HeadlessAgentLauncher(store: store, undoLedger: undoLedger)

        let result = await launcher.beginTerminalTakeover(runID: run.id)
        guard case .success(let command) = result else {
            Issue.record("Expected successful terminal takeover")
            return
        }
        #expect(command.contains("owned-session"))

        let handedOffRun = try #require(store.run(id: run.id))
        #expect(handedOffRun.status == .cancelled)
        #expect(handedOffRun.sessionIdentifier.isEmpty)
        #expect(handedOffRun.queuedFollowUpInstructions.isEmpty)
        #expect(!launcher.canSendFollowUp(runID: run.id))

        let reloadedRun = try #require(FileAgentRunStore(fileURL: storeFileURL).run(id: run.id))
        #expect(reloadedRun.sessionIdentifier.isEmpty)
        #expect(reloadedRun.queuedFollowUpInstructions.isEmpty)
    }

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
        launcher.detachedExecutionEnabled = false
        launcher.resolveExecutable = { _ in executableURL }
        launcher.approvePlan(runID: run.id)

        // Receipt scanning and terminal projection are separate asynchronous
        // work. Wait for both instead of racing whichever one publishes first.
        let persistedTerminalReceipt = await waitUntil(timeout: .seconds(7)) {
            guard let current = store.run(id: run.id) else { return false }
            return current.status == .succeeded && current.workspaceChangeSummary != nil
        }
        #expect(persistedTerminalReceipt)

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
        // Plain language pointing at the one-click sign-in, not at PATH.
        #expect(run?.error.contains("Claude") == true)
        #expect(run?.error.contains("Settings → AI & Accounts") == true)
        #expect(run?.error.contains("PATH") == false)
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
