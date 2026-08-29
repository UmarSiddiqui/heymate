//
//  DetachedAgentLauncherIntegrationTests.swift
//  leanring-buddyTests
//

import Darwin
import Foundation
import Testing
@testable import HeyMate

@MainActor
struct DetachedAgentLauncherIntegrationTests {

    private struct Harness {
        let rootURL: URL
        let runtimeRootURL: URL
        let store: FileAgentRunStore
        let undoLedger: FileAgentUndoLedger
        let launcher: HeadlessAgentLauncher
        let runID: UUID
        let runnerIdentity: AgentProcessIdentity
    }

    private func makeHarness(
        attemptID: UUID? = nil,
        status: AgentRunStatus = .awaitingPlanApproval
    ) throws -> Harness {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DetachedLauncher-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        let runtimeRootURL = rootURL.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try "baseline\n".write(
            to: workspaceURL.appendingPathComponent("Existing.txt"),
            atomically: true,
            encoding: .utf8
        )

        let store = FileAgentRunStore(fileURL: rootURL.appendingPathComponent("runs.json"))
        let undoLedger = FileAgentUndoLedger(
            rootDirectoryURL: rootURL.appendingPathComponent("undo", isDirectory: true),
            recoverPreparedEntriesOnInit: false
        )
        var run = AgentRun.queued(
            id: UUID(),
            title: "Detached integration",
            prompt: "Perform approved work",
            workspaceURL: workspaceURL,
            executor: .claudeCode,
            origin: .attached,
            sessionIdentifier: "detached-session"
        )
        run.status = status
        run.planText = "Perform approved work."
        if let attemptID {
            let entry = try undoLedger.prepareSnapshot(for: run)
            run.undoEntryIdentifier = entry.id.uuidString
            run.detachedAttemptIdentifier = attemptID.uuidString.lowercased()
            run.startedAt = Date()
        }
        store.upsert(run)

        let runnerIdentity = AgentProcessIdentity(
            pid: 42_424,
            startSeconds: 123,
            startMicroseconds: 456,
            executablePath: "/Applications/HeyMate.app/Contents/MacOS/HeyMate",
            uid: UInt32(getuid()),
            bootSessionID: "test-boot"
        )
        let launcher = HeadlessAgentLauncher(store: store, undoLedger: undoLedger)
        launcher.detachedRuntimeRootURL = runtimeRootURL
        launcher.detachedMonitorInterval = .seconds(60)
        launcher.inspectProcessIdentity = { pid in
            pid == runnerIdentity.pid ? runnerIdentity : nil
        }
        launcher.matchesLiveProcessIdentity = { $0 == runnerIdentity }
        launcher.matchesLiveChildProcessGroup = { _, _ in false }

        return Harness(
            rootURL: rootURL,
            runtimeRootURL: runtimeRootURL,
            store: store,
            undoLedger: undoLedger,
            launcher: launcher,
            runID: run.id,
            runnerIdentity: runnerIdentity
        )
    }

    private func persistState(
        rootURL: URL,
        runID: UUID,
        attemptID: UUID,
        phase: DetachedAgentRuntimePhase,
        runnerIdentity: AgentProcessIdentity?,
        approvalToken: DetachedAgentApprovalToken? = nil,
        childIdentity: AgentProcessIdentity? = nil,
        childProcessGroupID: Int32? = nil,
        terminalSummary: String? = nil
    ) throws {
        let journal = try DetachedAgentRuntimeJournal(
            rootDirectoryURL: rootURL,
            runID: runID,
            attemptID: attemptID
        )
        let event: DetachedAgentRuntimeEvent
        if phase.isTerminal {
            event = .finished(phase: phase, exitCode: phase == .succeeded ? 0 : 1, summary: terminalSummary)
        } else if phase == .waitingForApproval, let approvalToken {
            event = .approvalRequested(token: approvalToken, summary: "Approve file edit")
        } else {
            event = .phaseChanged(phase)
        }
        let record = try journal.append(
            DetachedAgentEventEnvelope(runID: runID, attemptID: attemptID, event: event)
        )
        let stateStore = try DetachedAgentDurableStateStore(
            rootDirectoryURL: rootURL,
            runID: runID,
            attemptID: attemptID
        )
        try stateStore.save(
            DetachedAgentDurableState(
                runID: runID,
                attemptID: attemptID,
                leg: .execute,
                phase: phase,
                lastJournalSequence: record.sequence,
                latestSafeSummary: terminalSummary,
                runnerIdentity: runnerIdentity,
                childIdentity: childIdentity,
                childProcessGroupID: childProcessGroupID,
                terminalSafeSummary: phase.isTerminal ? terminalSummary : nil,
                terminalSafeError: phase == .failed ? terminalSummary : nil,
                pendingApprovalToken: approvalToken,
                exitCode: phase.isTerminal ? (phase == .succeeded ? 0 : 1) : nil
            )
        )
    }

    private func persistHandoff(
        rootURL: URL,
        runID: UUID,
        attemptID: UUID,
        runnerIdentity: AgentProcessIdentity
    ) throws {
        let journal = try DetachedAgentRuntimeJournal(
            rootDirectoryURL: rootURL,
            runID: runID,
            attemptID: attemptID
        )
        let record = try journal.append(
            DetachedAgentEventEnvelope(
                runID: runID,
                attemptID: attemptID,
                event: .handedOff
            )
        )
        let stateStore = try DetachedAgentDurableStateStore(
            rootDirectoryURL: rootURL,
            runID: runID,
            attemptID: attemptID
        )
        try stateStore.save(
            DetachedAgentDurableState(
                runID: runID,
                attemptID: attemptID,
                leg: .execute,
                phase: .cancelled,
                lastJournalSequence: record.sequence,
                latestSafeSummary: "Handed off to Terminal",
                runnerIdentity: runnerIdentity,
                terminalSafeSummary: "Handed off to Terminal",
                handedOffToTerminal: true
            )
        )
    }

    @Test func approvedExecuteLaunchesDetachedAndBecomesSafeToQuitAfterIdentityVerification() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.rootURL) }
        let fakeCLIURL = harness.rootURL.appendingPathComponent("claude")
        let fakeRunnerURL = harness.rootURL.appendingPathComponent("HeyMate")
        var capturedRequest: DetachedAgentLaunchRequest?

        harness.launcher.resolveExecutable = { _ in fakeCLIURL }
        harness.launcher.detachedRunnerExecutableURL = { fakeRunnerURL }
        harness.launcher.spawnDetachedRunner = { _, request in
            capturedRequest = request
            try persistState(
                rootURL: harness.runtimeRootURL,
                runID: request.runID,
                attemptID: request.attemptID,
                phase: .running,
                runnerIdentity: harness.runnerIdentity
            )
            return harness.runnerIdentity.pid
        }

        harness.launcher.approvePlan(runID: harness.runID)

        let request = try #require(capturedRequest)
        #expect(request.leg == .execute)
        #expect(request.executor == .claudeCode)
        #expect(request.spec.executableURL == fakeCLIURL)
        #expect(request.spec.environmentOverrides["HEYMATE_BRIDGE_TOKEN"] == nil)
        #expect(harness.store.run(id: harness.runID)?.detachedAttemptID == request.attemptID)
        #expect(harness.store.run(id: harness.runID)?.status == .running)
        #expect(harness.launcher.terminationBlockingRunCount == 0)
        #expect(harness.undoLedger.latestReadyEntry() == nil)
    }

    @Test func missingExecuteCLIReleasesPreparedUndoWithoutStartingRunner() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.rootURL) }
        var didAttemptRunnerSpawn = false
        harness.launcher.resolveExecutable = { _ in nil }
        harness.launcher.spawnDetachedRunner = { _, _ in
            didAttemptRunnerSpawn = true
            return harness.runnerIdentity.pid
        }

        harness.launcher.approvePlan(runID: harness.runID)

        #expect(didAttemptRunnerSpawn == false)
        #expect(harness.store.run(id: harness.runID)?.status == .failed)
        #expect(harness.undoLedger.latestReadyEntry()?.runID == harness.runID)
    }

    @Test func recoveryKeepsLiveRunnerAndRoutesApprovalAndCancelThroughMailbox() throws {
        let attemptID = UUID()
        let harness = try makeHarness(attemptID: attemptID, status: .running)
        defer { try? FileManager.default.removeItem(at: harness.rootURL) }
        let token = DetachedAgentApprovalToken()
        try persistState(
            rootURL: harness.runtimeRootURL,
            runID: harness.runID,
            attemptID: attemptID,
            phase: .waitingForApproval,
            runnerIdentity: harness.runnerIdentity,
            approvalToken: token
        )

        harness.launcher.recoverPersistedRuns()
        #expect(harness.store.run(id: harness.runID)?.status == .waitingForApproval)
        #expect(harness.launcher.terminationBlockingRunCount == 0)
        #expect(harness.undoLedger.latestReadyEntry() == nil)

        harness.launcher.resolveApproval(runID: harness.runID, approve: true)
        let mailbox = try DetachedAgentCommandMailbox(
            rootDirectoryURL: harness.runtimeRootURL,
            runID: harness.runID,
            attemptID: attemptID
        )
        var commands: [DetachedAgentRuntimeCommand] = []
        _ = try mailbox.drain { envelope in
            commands.append(envelope.command)
            return true
        }
        #expect(commands.count == 1)
        #expect(commands[0].kind == .respondToApproval)
        #expect(commands[0].approvalToken == token)

        harness.launcher.cancel(runID: harness.runID)
        _ = try mailbox.drain { envelope in
            commands.append(envelope.command)
            return true
        }
        #expect(commands.last?.kind == .cancel)
        #expect(harness.store.run(id: harness.runID)?.status.isTerminal == false)
    }

    @Test func terminalJournalWinsWhenFinalStateSaveWasLost() throws {
        let attemptID = UUID()
        let harness = try makeHarness(attemptID: attemptID, status: .running)
        defer { try? FileManager.default.removeItem(at: harness.rootURL) }
        harness.launcher.matchesLiveProcessIdentity = { _ in false }

        let journal = try DetachedAgentRuntimeJournal(
            rootDirectoryURL: harness.runtimeRootURL,
            runID: harness.runID,
            attemptID: attemptID
        )
        let runningRecord = try journal.append(
            DetachedAgentEventEnvelope(
                runID: harness.runID,
                attemptID: attemptID,
                event: .phaseChanged(.running)
            )
        )
        let stateStore = try DetachedAgentDurableStateStore(
            rootDirectoryURL: harness.runtimeRootURL,
            runID: harness.runID,
            attemptID: attemptID
        )
        try stateStore.save(
            DetachedAgentDurableState(
                runID: harness.runID,
                attemptID: attemptID,
                leg: .execute,
                phase: .running,
                lastJournalSequence: runningRecord.sequence,
                runnerIdentity: harness.runnerIdentity
            )
        )
        _ = try journal.append(
            DetachedAgentEventEnvelope(
                runID: harness.runID,
                attemptID: attemptID,
                event: .finished(phase: .succeeded, exitCode: 0, summary: "Finished safely")
            )
        )

        harness.launcher.recoverPersistedRuns()

        #expect(harness.store.run(id: harness.runID)?.status == .succeeded)
        #expect(harness.store.run(id: harness.runID)?.summary == "Finished safely")
        #expect(harness.undoLedger.latestReadyEntry()?.runID == harness.runID)
        #expect(harness.launcher.terminationBlockingRunCount == 0)
    }

    @Test func deadRunnerDoesNotReleaseUndoUntilVerifiedChildGroupExits() throws {
        let attemptID = UUID()
        let harness = try makeHarness(attemptID: attemptID, status: .running)
        defer { try? FileManager.default.removeItem(at: harness.rootURL) }
        let childIdentity = AgentProcessIdentity(
            pid: 43_434,
            startSeconds: 789,
            startMicroseconds: 12,
            executablePath: "/usr/bin/fake-agent",
            uid: UInt32(getuid()),
            bootSessionID: "test-boot"
        )
        try persistState(
            rootURL: harness.runtimeRootURL,
            runID: harness.runID,
            attemptID: attemptID,
            phase: .running,
            runnerIdentity: harness.runnerIdentity,
            childIdentity: childIdentity,
            childProcessGroupID: childIdentity.pid
        )
        harness.launcher.matchesLiveProcessIdentity = { _ in false }
        var childGroupIsLive = true
        harness.launcher.matchesLiveChildProcessGroup = { identity, groupID in
            childGroupIsLive && identity == childIdentity && groupID == childIdentity.pid
        }

        harness.launcher.recoverPersistedRuns()
        #expect(harness.store.run(id: harness.runID)?.status.isTerminal == false)
        #expect(harness.undoLedger.latestReadyEntry() == nil)
        #expect(harness.launcher.terminationBlockingRunCount == 1)

        childGroupIsLive = false
        harness.launcher.recoverPersistedRuns()
        #expect(harness.store.run(id: harness.runID)?.status == .failed)
        #expect(harness.undoLedger.latestReadyEntry()?.runID == harness.runID)
    }

    @Test func takeoverWaitsForRunnerHandoffBeforeReleasingSession() async throws {
        let attemptID = UUID()
        let harness = try makeHarness(attemptID: attemptID, status: .running)
        defer { try? FileManager.default.removeItem(at: harness.rootURL) }
        try persistState(
            rootURL: harness.runtimeRootURL,
            runID: harness.runID,
            attemptID: attemptID,
            phase: .running,
            runnerIdentity: harness.runnerIdentity
        )
        harness.launcher.recoverPersistedRuns()

        let simulator = Task { @MainActor in
            let clock = SuspendingClock()
            for _ in 0..<100 {
                let mailbox = try DetachedAgentCommandMailbox(
                    rootDirectoryURL: harness.runtimeRootURL,
                    runID: harness.runID,
                    attemptID: attemptID
                )
                var receivedTakeover = false
                _ = try mailbox.drain { envelope in
                    receivedTakeover = envelope.command.kind == .takeOverInTerminal
                    return true
                }
                if receivedTakeover {
                    try persistHandoff(
                        rootURL: harness.runtimeRootURL,
                        runID: harness.runID,
                        attemptID: attemptID,
                        runnerIdentity: harness.runnerIdentity
                    )
                    return
                }
                try? await clock.sleep(for: .milliseconds(10))
            }
            Issue.record("Runner did not receive takeover command")
        }

        let result = await harness.launcher.beginTerminalTakeover(runID: harness.runID)
        try await simulator.value

        guard case .success(let command) = result else {
            Issue.record("Expected successful detached takeover")
            return
        }
        #expect(command.contains("detached-session"))
        #expect(harness.store.run(id: harness.runID)?.status == .cancelled)
        #expect(harness.store.run(id: harness.runID)?.sessionIdentifier.isEmpty == true)
    }
}
