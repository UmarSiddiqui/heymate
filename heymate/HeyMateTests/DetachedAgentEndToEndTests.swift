//
//  DetachedAgentEndToEndTests.swift
//  HeyMateTests
//

import Darwin
import AppKit
import Foundation
import Testing
@testable import HeyMate

@MainActor
struct DetachedAgentEndToEndTests {

    @Test func embeddedRunnerSurvivesLauncherDropReattachesAndCancelsSafely() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("DetachedAgentE2E-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = fixture.appendingPathComponent("workspace", isDirectory: true)
        let storeURL = fixture.appendingPathComponent("runs.json")
        let undoRootURL = fixture.appendingPathComponent("undo", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try Data("baseline\n".utf8).write(
            to: workspaceURL.appendingPathComponent("Existing.txt")
        )
        let fakeCLIURL = try makeLongRunningExecutable(in: fixture)
        let runnerExecutableURL = try #require(DetachedAgentRunnerExecutable.bundledURL())
        #expect(runnerExecutableURL.lastPathComponent == "HeyMateAgentRunner")
        #expect(runnerExecutableURL.deletingLastPathComponent().lastPathComponent == "Helpers")
        #expect(runnerExecutableURL != Bundle.main.executableURL)

        let runID = UUID()
        var run = AgentRun.queued(
            id: runID,
            title: "Detached E2E",
            prompt: "Keep working across app restart",
            workspaceURL: workspaceURL,
            executor: .claudeCode,
            origin: .attached,
            sessionIdentifier: UUID().uuidString.lowercased()
        )
        run.status = .awaitingPlanApproval
        run.planText = "Run until cancelled."

        let firstStore = FileAgentRunStore(fileURL: storeURL)
        firstStore.upsert(run)
        let firstUndoLedger = FileAgentUndoLedger(
            rootDirectoryURL: undoRootURL,
            recoverPreparedEntriesOnInit: false
        )
        var firstLauncher: HeadlessAgentLauncher? = HeadlessAgentLauncher(
            store: firstStore,
            undoLedger: firstUndoLedger
        )
        firstLauncher?.resolveExecutable = { _ in fakeCLIURL }
        firstLauncher?.detachedRunnerExecutableURL = { runnerExecutableURL }
        firstLauncher?.runtimeLimitForLeg = { _ in 30 }
        firstLauncher?.approvePlan(runID: runID)

        let attemptID = try #require(firstStore.run(id: runID)?.detachedAttemptID)
        let runtimeRunDirectoryURL = DetachedAgentRuntimePaths.runDirectoryURL(
            rootDirectoryURL: DetachedAgentRuntimePaths.defaultRootURL,
            runID: runID
        )
        var lastKnownState: DetachedAgentDurableState?
        defer {
            if let state = lastKnownState {
                Self.stopForCleanup(state)
            }
            try? FileManager.default.removeItem(at: runtimeRunDirectoryURL)
            try? FileManager.default.removeItem(at: fixture)
        }

        let started = await waitUntil(timeout: 8) {
            guard let state = try? DetachedAgentDurableStateStore.loadReadOnly(
                rootDirectoryURL: DetachedAgentRuntimePaths.defaultRootURL,
                runID: runID,
                attemptID: attemptID
            ) else { return false }
            lastKnownState = state
            return state.phase == .running
                && state.childIdentity != nil
                && state.childProcessGroupID != nil
        }
        #expect(started)
        let liveState = try #require(lastKnownState)
        let liveRunnerIdentity = try #require(liveState.runnerIdentity)
        #expect(liveRunnerIdentity.pid != getpid())
        #expect(AgentProcessIdentityInspector.matchesLiveProcess(liveRunnerIdentity))
        #expect(!NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.heymate.app"
        ).contains(where: { $0.processIdentifier == liveRunnerIdentity.pid }))

        // Simulates app-owned launcher disappearing. Runner has no pipe or Task
        // ownership relationship with this object and must stay alive.
        firstLauncher = nil
        let clock = ContinuousClock()
        try? await clock.sleep(for: .milliseconds(500))
        #expect(AgentProcessIdentityInspector.matchesLiveProcess(liveRunnerIdentity))
        let resumedState = try DetachedAgentDurableStateStore.loadReadOnly(
            rootDirectoryURL: DetachedAgentRuntimePaths.defaultRootURL,
            runID: runID,
            attemptID: attemptID
        )
        #expect(try #require(resumedState).phase == .running)

        let recoveredStore = FileAgentRunStore(fileURL: storeURL)
        let recoveredUndoLedger = FileAgentUndoLedger(
            rootDirectoryURL: undoRootURL,
            recoverPreparedEntriesOnInit: false
        )
        let recoveredLauncher = HeadlessAgentLauncher(
            store: recoveredStore,
            undoLedger: recoveredUndoLedger
        )
        recoveredLauncher.detachedRunnerExecutableURL = { runnerExecutableURL }
        recoveredLauncher.recoverPersistedRuns()
        #expect(recoveredStore.run(id: runID)?.status == .running)
        #expect(recoveredLauncher.terminationBlockingRunCount == 0)
        #expect(recoveredUndoLedger.latestReadyEntry() == nil)

        recoveredLauncher.cancel(runID: runID)
        let cancelled = await waitUntil(timeout: 10) {
            if let state = try? DetachedAgentDurableStateStore.loadReadOnly(
                rootDirectoryURL: DetachedAgentRuntimePaths.defaultRootURL,
                runID: runID,
                attemptID: attemptID
            ) {
                lastKnownState = state
            }
            return recoveredStore.run(id: runID)?.status == .cancelled
        }
        #expect(cancelled)
        let terminalState = try #require(lastKnownState)
        #expect(terminalState.phase == .cancelled)
        #expect(recoveredUndoLedger.latestReadyEntry()?.runID == runID)
        if let childIdentity = terminalState.childIdentity,
           let processGroupID = terminalState.childProcessGroupID {
            #expect(!AgentProcessIdentityInspector.matchesLiveProcessGroup(
                leader: childIdentity,
                processGroupID: processGroupID
            ))
            #expect(Darwin.kill(-processGroupID, 0) != 0 && errno == ESRCH)
        }

        let runnerExited = await waitUntil(timeout: 5) {
            guard let runnerIdentity = terminalState.runnerIdentity else { return true }
            return !AgentProcessIdentityInspector.matchesLiveProcess(runnerIdentity)
        }
        #expect(runnerExited)
        lastKnownState = nil
    }

    private func makeLongRunningExecutable(in directoryURL: URL) throws -> URL {
        let sourceURL = directoryURL.appendingPathComponent("fake-agent.c")
        let executableURL = directoryURL.appendingPathComponent("fake-agent")
        let source = """
        #include <signal.h>
        #include <unistd.h>
        static volatile sig_atomic_t stopping = 0;
        static void stop(int signal_number) { (void)signal_number; stopping = 1; }
        int main(void) {
            signal(SIGTERM, stop);
            signal(SIGINT, stop);
            while (!stopping) pause();
            return 0;
        }
        """
        try Data(source.utf8).write(to: sourceURL)

        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["clang", sourceURL.path, "-o", executableURL.path]
        compiler.standardOutput = FileHandle.nullDevice
        compiler.standardError = FileHandle.nullDevice
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { throw POSIXError(.ENOEXEC) }
        return executableURL
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while clock.now < deadline {
            if condition() { return true }
            try? await clock.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private static func stopForCleanup(_ state: DetachedAgentDurableState) {
        if let runnerIdentity = state.runnerIdentity,
           AgentProcessIdentityInspector.matchesLiveProcess(runnerIdentity) {
            Darwin.kill(runnerIdentity.pid, SIGKILL)
        }
        if let childIdentity = state.childIdentity,
           let processGroupID = state.childProcessGroupID,
           AgentProcessIdentityInspector.matchesLiveProcessGroup(
               leader: childIdentity,
               processGroupID: processGroupID
           ) {
            Darwin.kill(-processGroupID, SIGKILL)
        }
    }
}
