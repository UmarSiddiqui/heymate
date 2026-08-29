//
//  DetachedAgentRunReducer.swift
//  leanring-buddy
//
//  Pure projection from a detached runner's durable view into the existing
//  AgentRun card. Persistence and process ownership stay with the caller.
//

import Foundation

nonisolated enum DetachedAgentRunReductionError: Error, Equatable {
    case runIDMismatch(expected: UUID, actual: UUID)
    case missingAttemptIdentifier(runID: UUID)
    case attemptIDMismatch(expected: UUID, actual: UUID)
    case journalRunIDMismatch(sequence: UInt64, expected: UUID, actual: UUID)
    case journalAttemptIDMismatch(sequence: UInt64, expected: UUID, actual: UUID)
    case staleState(lastAppliedSequence: UInt64, stateSequence: UInt64)
    case unsupportedLeg(DetachedAgentRunLegKind)
}

nonisolated enum DetachedAgentRunReducer {

    /// Returns a new run or rejects the complete input. Validation finishes
    /// before the first field is projected, so a bad attempt cannot partially
    /// update a card when the caller assigns the result.
    static func reduce(
        run: AgentRun,
        state: DetachedAgentDurableState,
        journal: [DetachedAgentJournalRecord]
    ) throws -> AgentRun {
        guard state.runID == run.id else {
            throw DetachedAgentRunReductionError.runIDMismatch(
                expected: run.id,
                actual: state.runID
            )
        }
        guard let attemptID = run.detachedAttemptID else {
            throw DetachedAgentRunReductionError.missingAttemptIdentifier(runID: run.id)
        }
        guard state.attemptID == attemptID else {
            throw DetachedAgentRunReductionError.attemptIDMismatch(
                expected: attemptID,
                actual: state.attemptID
            )
        }
        guard state.leg == .execute else {
            throw DetachedAgentRunReductionError.unsupportedLeg(state.leg)
        }
        guard state.lastJournalSequence >= run.lastDetachedJournalSequence else {
            throw DetachedAgentRunReductionError.staleState(
                lastAppliedSequence: run.lastDetachedJournalSequence,
                stateSequence: state.lastJournalSequence
            )
        }

        for record in journal {
            guard record.runID == run.id else {
                throw DetachedAgentRunReductionError.journalRunIDMismatch(
                    sequence: record.sequence,
                    expected: run.id,
                    actual: record.runID
                )
            }
            guard record.attemptID == attemptID else {
                throw DetachedAgentRunReductionError.journalAttemptIDMismatch(
                    sequence: record.sequence,
                    expected: attemptID,
                    actual: record.attemptID
                )
            }
        }

        var reduced = run
        apply(state, to: &reduced)
        reduced.lastDetachedJournalSequence = state.lastJournalSequence

        // The state snapshot is authoritative through its recorded sequence.
        // A read racing the runner may also see newer journal lines; replay
        // those in order and advance the checkpoint after each one. Sorting
        // also makes duplicate delivery harmless.
        for record in journal.sorted(by: journalOrder) {
            guard record.sequence > reduced.lastDetachedJournalSequence else { continue }
            apply(record, runnerPID: state.runnerIdentity?.pid, to: &reduced)
            reduced.lastDetachedJournalSequence = record.sequence
        }

        return reduced
    }

    private static func journalOrder(
        _ lhs: DetachedAgentJournalRecord,
        _ rhs: DetachedAgentJournalRecord
    ) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.messageID.uuidString < rhs.messageID.uuidString
    }

    private static func apply(
        _ state: DetachedAgentDurableState,
        to run: inout AgentRun
    ) {
        apply(
            phase: state.phase,
            latestSafeSummary: state.latestSafeSummary,
            terminalSafeSummary: state.terminalSafeSummary,
            terminalSafeError: state.terminalSafeError,
            approvalToken: state.pendingApprovalToken,
            runnerPID: state.runnerIdentity?.pid,
            startedAt: state.createdAt,
            updatedAt: state.updatedAt,
            to: &run
        )

        if state.handedOffToTerminal {
            apply(
                phase: .cancelled,
                latestSafeSummary: state.latestSafeSummary,
                terminalSafeSummary: state.terminalSafeSummary
                    ?? "Handed off to Terminal — you are driving this session now",
                terminalSafeError: nil,
                approvalToken: nil,
                runnerPID: state.runnerIdentity?.pid,
                startedAt: state.createdAt,
                updatedAt: state.updatedAt,
                to: &run
            )
            clearSessionOwnership(of: &run)
        }
    }

    private static func apply(
        _ record: DetachedAgentJournalRecord,
        runnerPID: Int32?,
        to run: inout AgentRun
    ) {
        switch record.kind {
        case .phaseChanged:
            guard let phase = record.phase else { return }
            apply(
                phase: phase,
                latestSafeSummary: record.safeSummary,
                terminalSafeSummary: phase.isTerminal ? record.safeSummary : nil,
                terminalSafeError: phase == .failed ? record.safeSummary : nil,
                approvalToken: record.pendingApprovalToken,
                runnerPID: runnerPID,
                startedAt: record.emittedAt,
                updatedAt: record.emittedAt,
                to: &run
            )

        case .progress, .warning:
            guard !run.status.isTerminal,
                  let summary = nonempty(record.safeSummary) else { return }
            run.latestAction = summary

        case .approvalRequested:
            guard !run.status.isTerminal else { return }
            run.status = .waitingForApproval
            run.pendingApprovalID = approvalString(record.pendingApprovalToken)
            run.latestAction = nonempty(record.safeSummary) ?? "Needs your approval"
            run.pid = runnerPID
            run.finishedAt = nil
            run.error = ""

        case .finished:
            guard let phase = record.phase else { return }
            apply(
                phase: phase,
                latestSafeSummary: record.safeSummary,
                terminalSafeSummary: record.safeSummary,
                terminalSafeError: phase == .failed ? record.safeSummary : nil,
                approvalToken: nil,
                runnerPID: runnerPID,
                startedAt: record.emittedAt,
                updatedAt: record.emittedAt,
                to: &run
            )

        case .handedOff:
            apply(
                phase: record.phase ?? .cancelled,
                latestSafeSummary: record.safeSummary,
                terminalSafeSummary: record.safeSummary
                    ?? "Handed off to Terminal — you are driving this session now",
                terminalSafeError: nil,
                approvalToken: nil,
                runnerPID: runnerPID,
                startedAt: record.emittedAt,
                updatedAt: record.emittedAt,
                to: &run
            )
            clearSessionOwnership(of: &run)

        case .ready, .output, .sessionIdentified, .heartbeat:
            break
        }
    }

    private static func apply(
        phase: DetachedAgentRuntimePhase,
        latestSafeSummary: String?,
        terminalSafeSummary: String?,
        terminalSafeError: String?,
        approvalToken: DetachedAgentApprovalToken?,
        runnerPID: Int32?,
        startedAt: Date,
        updatedAt: Date,
        to run: inout AgentRun
    ) {
        let latestSummary = nonempty(latestSafeSummary)
        let terminalSummary = nonempty(terminalSafeSummary)
        let terminalError = nonempty(terminalSafeError)

        switch phase {
        case .queued:
            run.status = .queued
            run.latestAction = latestSummary ?? "Queued"
            run.pid = runnerPID
            run.pendingApprovalID = ""
            run.finishedAt = nil
            run.error = ""

        case .launching:
            run.status = .running
            run.latestAction = latestSummary ?? "Starting agent…"
            run.startedAt = run.startedAt ?? startedAt
            run.pid = runnerPID
            run.pendingApprovalID = ""
            run.finishedAt = nil
            run.error = ""

        case .running:
            run.status = .running
            run.latestAction = latestSummary ?? "Working…"
            run.startedAt = run.startedAt ?? startedAt
            run.pid = runnerPID
            run.pendingApprovalID = ""
            run.finishedAt = nil
            run.error = ""

        case .waitingForApproval:
            run.status = .waitingForApproval
            run.latestAction = latestSummary ?? "Needs your approval"
            run.startedAt = run.startedAt ?? startedAt
            run.pid = runnerPID
            run.pendingApprovalID = approvalString(approvalToken)
            run.finishedAt = nil
            run.error = ""

        case .interrupting:
            // AgentRun has no stopping enum. Keep it nonterminal until the
            // runner confirms its whole process group has exited.
            run.status = .running
            run.latestAction = latestSummary ?? "Stopping safely…"
            run.startedAt = run.startedAt ?? startedAt
            run.pid = runnerPID
            run.pendingApprovalID = ""
            run.finishedAt = nil
            run.error = ""

        case .detached:
            run.status = .running
            run.latestAction = latestSummary ?? "Working in background…"
            run.startedAt = run.startedAt ?? startedAt
            run.pid = runnerPID
            run.pendingApprovalID = ""
            run.finishedAt = nil
            run.error = ""

        case .succeeded:
            let summary = terminalSummary ?? latestSummary ?? nonempty(run.summary) ?? "Done"
            run.status = .succeeded
            run.summary = summary
            run.latestAction = summary
            run.error = ""
            finish(&run, at: updatedAt)

        case .failed:
            let summary = terminalSummary ?? latestSummary
            let error = terminalError ?? summary ?? "Agent stopped with an error"
            run.status = .failed
            if let summary { run.summary = summary }
            run.latestAction = error
            run.error = error
            finish(&run, at: updatedAt)

        case .cancelled:
            run.status = .cancelled
            run.latestAction = terminalSummary ?? latestSummary ?? "Cancelled"
            run.error = ""
            finish(&run, at: updatedAt)
        }
    }

    private static func finish(_ run: inout AgentRun, at date: Date) {
        run.finishedAt = date
        run.pid = nil
        run.pendingApprovalID = ""
    }

    private static func clearSessionOwnership(of run: inout AgentRun) {
        run.sessionIdentifier = ""
        run.queuedFollowUpInstructions.removeAll()
        run.pendingApprovalID = ""
    }

    private static func approvalString(_ token: DetachedAgentApprovalToken?) -> String {
        token?.rawValue.uuidString.lowercased() ?? ""
    }

    private static func nonempty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
