//
//  DetachedAgentRunReducerTests.swift
//  HeyMateTests
//

import Foundation
import Testing
@testable import HeyMate

struct DetachedAgentRunReducerTests {

    private struct JournalFixture {
        let rootURL: URL
        let journal: DetachedAgentRuntimeJournal
    }

    private let runnerIdentity = AgentProcessIdentity(
        pid: 4242,
        startSeconds: 10,
        startMicroseconds: 20,
        executablePath: "/Applications/HeyMate.app/Contents/MacOS/HeyMate",
        uid: 501,
        bootSessionID: "1.2"
    )

    private func makeRun(
        runID: UUID = UUID(),
        attemptID: UUID = UUID()
    ) -> AgentRun {
        var run = AgentRun.queued(
            id: runID,
            title: "Detached run",
            prompt: "Make the change",
            workspaceURL: URL(fileURLWithPath: "/tmp/detached-reducer", isDirectory: true),
            executor: .codex,
            origin: .attached,
            sessionIdentifier: "owned-session"
        )
        run.status = .running
        run.latestAction = "Old action"
        run.pid = 99
        run.detachedAttemptIdentifier = attemptID.uuidString
        run.undoEntryIdentifier = "undo-entry"
        run.queuedFollowUpInstructions = ["Follow up later"]
        return run
    }

    private func makeState(
        for run: AgentRun,
        attemptID: UUID? = nil,
        leg: DetachedAgentRunLegKind = .execute,
        phase: DetachedAgentRuntimePhase,
        sequence: UInt64 = 0,
        summary: String? = nil,
        terminalSummary: String? = nil,
        terminalError: String? = nil,
        approvalToken: DetachedAgentApprovalToken? = nil,
        handedOff: Bool = false
    ) -> DetachedAgentDurableState {
        DetachedAgentDurableState(
            runID: run.id,
            attemptID: attemptID ?? run.detachedAttemptID!,
            leg: leg,
            phase: phase,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200),
            lastJournalSequence: sequence,
            latestSafeSummary: summary,
            runnerIdentity: runnerIdentity,
            terminalSafeSummary: terminalSummary,
            terminalSafeError: terminalError,
            pendingApprovalToken: approvalToken,
            handedOffToTerminal: handedOff
        )
    }

    private func makeJournalFixture(
        runID: UUID,
        attemptID: UUID
    ) throws -> JournalFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DetachedReducer-\(UUID().uuidString)", isDirectory: true)
        return JournalFixture(
            rootURL: rootURL,
            journal: try DetachedAgentRuntimeJournal(
                rootDirectoryURL: rootURL,
                runID: runID,
                attemptID: attemptID
            )
        )
    }

    @Test func runningWaitingAndInterruptingStayOwnedByRunner() throws {
        let run = makeRun()
        let token = DetachedAgentApprovalToken(
            rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )

        let running = try DetachedAgentRunReducer.reduce(
            run: run,
            state: makeState(
                for: run,
                phase: .running,
                sequence: 3,
                summary: "Running tests"
            ),
            journal: []
        )
        #expect(running.status == .running)
        #expect(running.latestAction == "Running tests")
        #expect(running.pid == runnerIdentity.pid)
        #expect(running.startedAt == Date(timeIntervalSince1970: 100))
        #expect(running.lastDetachedJournalSequence == 3)

        let waiting = try DetachedAgentRunReducer.reduce(
            run: run,
            state: makeState(
                for: run,
                phase: .waitingForApproval,
                summary: "Approve running tests",
                approvalToken: token
            ),
            journal: []
        )
        #expect(waiting.status == .waitingForApproval)
        #expect(waiting.pendingApprovalID == token.rawValue.uuidString.lowercased())
        #expect(waiting.latestAction == "Approve running tests")
        #expect(waiting.pid == runnerIdentity.pid)

        let interrupting = try DetachedAgentRunReducer.reduce(
            run: run,
            state: makeState(for: run, phase: .interrupting),
            journal: []
        )
        #expect(interrupting.status == .running)
        #expect(!interrupting.status.isTerminal)
        #expect(interrupting.latestAction == "Stopping safely…")
        #expect(interrupting.pid == runnerIdentity.pid)
        #expect(interrupting.finishedAt == nil)
    }

    @Test func terminalPhasesUseSafeFieldsClearPIDAndPreserveUndo() throws {
        let run = makeRun()

        let succeeded = try DetachedAgentRunReducer.reduce(
            run: run,
            state: makeState(
                for: run,
                phase: .succeeded,
                terminalSummary: "Changed three files"
            ),
            journal: []
        )
        #expect(succeeded.status == .succeeded)
        #expect(succeeded.summary == "Changed three files")
        #expect(succeeded.latestAction == "Changed three files")
        #expect(succeeded.pid == nil)
        #expect(succeeded.pendingApprovalID.isEmpty)
        #expect(succeeded.finishedAt == Date(timeIntervalSince1970: 200))
        #expect(succeeded.undoEntryIdentifier == run.undoEntryIdentifier)

        let failed = try DetachedAgentRunReducer.reduce(
            run: run,
            state: makeState(
                for: run,
                phase: .failed,
                terminalSummary: "Work stopped",
                terminalError: "Compiler failed"
            ),
            journal: []
        )
        #expect(failed.status == .failed)
        #expect(failed.summary == "Work stopped")
        #expect(failed.error == "Compiler failed")
        #expect(failed.latestAction == "Compiler failed")
        #expect(failed.pid == nil)
        #expect(failed.undoEntryIdentifier == run.undoEntryIdentifier)

        let cancelled = try DetachedAgentRunReducer.reduce(
            run: run,
            state: makeState(
                for: run,
                phase: .cancelled,
                terminalSummary: "Cancelled by user"
            ),
            journal: []
        )
        #expect(cancelled.status == .cancelled)
        #expect(cancelled.latestAction == "Cancelled by user")
        #expect(cancelled.error.isEmpty)
        #expect(cancelled.pid == nil)
        #expect(cancelled.undoEntryIdentifier == run.undoEntryIdentifier)
    }

    @Test func journalReplaysNewSequencesOnceAndIgnoresDuplicates() throws {
        var run = makeRun()
        run.lastDetachedJournalSequence = 1
        let attemptID = run.detachedAttemptID!
        let token = DetachedAgentApprovalToken(
            rawValue: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )
        let fixture = try makeJournalFixture(runID: run.id, attemptID: attemptID)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        _ = try fixture.journal.append(
            DetachedAgentEventEnvelope(
                runID: run.id,
                attemptID: attemptID,
                event: .progress("Already applied")
            )
        )
        _ = try fixture.journal.append(
            DetachedAgentEventEnvelope(
                runID: run.id,
                attemptID: attemptID,
                event: .phaseChanged(.running)
            )
        )
        _ = try fixture.journal.append(
            DetachedAgentEventEnvelope(
                runID: run.id,
                attemptID: attemptID,
                event: .progress("New progress")
            )
        )
        _ = try fixture.journal.append(
            DetachedAgentEventEnvelope(
                runID: run.id,
                attemptID: attemptID,
                event: .approvalRequested(token: token, summary: "Approve deploy")
            )
        )
        let records = fixture.journal.records()

        let reduced = try DetachedAgentRunReducer.reduce(
            run: run,
            state: makeState(
                for: run,
                phase: .running,
                sequence: 2,
                summary: "Snapshot progress"
            ),
            journal: records + records
        )
        #expect(reduced.status == .waitingForApproval)
        #expect(reduced.latestAction == "Approve deploy")
        #expect(reduced.pendingApprovalID == token.rawValue.uuidString.lowercased())
        #expect(reduced.lastDetachedJournalSequence == 4)

        var caughtUpState = makeState(
            for: reduced,
            phase: .waitingForApproval,
            sequence: 4,
            summary: "Approve deploy",
            approvalToken: token
        )
        caughtUpState.updatedAt = Date(timeIntervalSince1970: 300)
        let replayed = try DetachedAgentRunReducer.reduce(
            run: reduced,
            state: caughtUpState,
            journal: records
        )
        #expect(replayed == reduced)
    }

    @Test func handedOffStateAndEventClearSessionOwnership() throws {
        let run = makeRun()
        let stateHandoff = try DetachedAgentRunReducer.reduce(
            run: run,
            state: makeState(
                for: run,
                // Ownership is authoritative even if a crash leaves the
                // phase write one step behind the handoff flag.
                phase: .running,
                handedOff: true
            ),
            journal: []
        )
        #expect(stateHandoff.status == .cancelled)
        #expect(
            stateHandoff.latestAction
                == "Handed off to Terminal — you are driving this session now"
        )
        #expect(stateHandoff.sessionIdentifier.isEmpty)
        #expect(stateHandoff.queuedFollowUpInstructions.isEmpty)
        #expect(stateHandoff.undoEntryIdentifier == run.undoEntryIdentifier)

        let attemptID = run.detachedAttemptID!
        let fixture = try makeJournalFixture(runID: run.id, attemptID: attemptID)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        _ = try fixture.journal.append(
            DetachedAgentEventEnvelope(
                runID: run.id,
                attemptID: attemptID,
                event: .handedOff
            )
        )
        let eventHandoff = try DetachedAgentRunReducer.reduce(
            run: run,
            state: makeState(for: run, phase: .running),
            journal: fixture.journal.records()
        )
        #expect(eventHandoff.status == .cancelled)
        #expect(eventHandoff.sessionIdentifier.isEmpty)
        #expect(eventHandoff.queuedFollowUpInstructions.isEmpty)
        #expect(eventHandoff.pid == nil)
    }

    @Test func mismatchedAndStaleInputsRejectWithoutAResult() throws {
        let run = makeRun()
        let original = run
        let otherRunID = UUID()
        let otherAttemptID = UUID()

        var wrongRunState = makeState(for: run, phase: .running)
        let encodedState = try JSONEncoder().encode(wrongRunState)
        var stateObject = try #require(
            JSONSerialization.jsonObject(with: encodedState) as? [String: Any]
        )
        stateObject["runID"] = otherRunID.uuidString
        wrongRunState = try JSONDecoder().decode(
            DetachedAgentDurableState.self,
            from: JSONSerialization.data(withJSONObject: stateObject)
        )

        #expect(throws: DetachedAgentRunReductionError.runIDMismatch(
            expected: run.id,
            actual: otherRunID
        )) {
            try DetachedAgentRunReducer.reduce(run: run, state: wrongRunState, journal: [])
        }
        #expect(run == original)

        #expect(throws: DetachedAgentRunReductionError.attemptIDMismatch(
            expected: run.detachedAttemptID!,
            actual: otherAttemptID
        )) {
            try DetachedAgentRunReducer.reduce(
                run: run,
                state: makeState(
                    for: run,
                    attemptID: otherAttemptID,
                    phase: .running
                ),
                journal: []
            )
        }
        #expect(run == original)

        var caughtUpRun = run
        caughtUpRun.lastDetachedJournalSequence = 8
        #expect(throws: DetachedAgentRunReductionError.staleState(
            lastAppliedSequence: 8,
            stateSequence: 7
        )) {
            try DetachedAgentRunReducer.reduce(
                run: caughtUpRun,
                state: makeState(
                    for: caughtUpRun,
                    phase: .running,
                    sequence: 7
                ),
                journal: []
            )
        }
        #expect(caughtUpRun.lastDetachedJournalSequence == 8)
    }

    @Test func mismatchedJournalAttemptRejectsBeforeProjection() throws {
        let run = makeRun()
        let otherAttemptID = UUID()
        let fixture = try makeJournalFixture(runID: run.id, attemptID: otherAttemptID)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let record = try fixture.journal.append(
            DetachedAgentEventEnvelope(
                runID: run.id,
                attemptID: otherAttemptID,
                event: .progress("Wrong attempt")
            )
        )

        #expect(throws: DetachedAgentRunReductionError.journalAttemptIDMismatch(
            sequence: record.sequence,
            expected: run.detachedAttemptID!,
            actual: otherAttemptID
        )) {
            try DetachedAgentRunReducer.reduce(
                run: run,
                state: makeState(
                    for: run,
                    phase: .running,
                    sequence: 1,
                    summary: "Must not apply"
                ),
                journal: [record]
            )
        }
        #expect(run.latestAction == "Old action")
    }

    @Test func nonExecuteLegIsExplicitlyUnsupported() throws {
        let run = makeRun()
        #expect(throws: DetachedAgentRunReductionError.unsupportedLeg(.plan)) {
            try DetachedAgentRunReducer.reduce(
                run: run,
                state: makeState(for: run, leg: .plan, phase: .running),
                journal: []
            )
        }
        #expect(run.status == .running)
        #expect(run.latestAction == "Old action")
    }
}
