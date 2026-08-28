//
//  CompanionStateMachineTests.swift
//  leanring-buddyTests
//
//  Tests for the explicit companion state machine: happy paths,
//  interruption parity, cancellation from every non-idle state, agent
//  approval loops, and rejection of illegal transitions.
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct CompanionStateMachineTests {

    private static let agentID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// Every distinct shape of CompanionState, used by the cancellation
    /// and interruption parity tests.
    private var allStates: [CompanionState] {
        [
            .idle,
            .listening(.talk),
            .listening(.dictate),
            .listening(.spatial),
            .finalizingTranscript,
            .capturingContext,
            .thinking,
            .guiding,
            .speaking,
            .agentRunning(Self.agentID),
            .waitingForApproval(Self.agentID),
            .error("test")
        ]
    }

    // MARK: - Talk happy path

    @Test func talkHappyPathTransitionsAreLegal() {
        var state = CompanionState.idle

        let events: [CompanionEvent] = [
            .startListening(.talk),
            .finishListening,
            .beginContextCapture,
            .contextCaptured,
            .beginGuidance,
            .beginSpeaking,
            .interactionFinished
        ]

        for event in events {
            guard let next = CompanionStateMachine.transition(from: state, on: event) else {
                Issue.record("Illegal transition: \(state) + \(event)")
                return
            }
            state = next
        }

        #expect(state == .idle)
    }

    @Test func talkWithoutPointingGoesStraightToSpeaking() {
        var state = CompanionState.thinking
        state = CompanionStateMachine.transition(from: state, on: .beginSpeaking)!
        #expect(state == .speaking)
        state = CompanionStateMachine.transition(from: state, on: .interactionFinished)!
        #expect(state == .idle)
    }

    // MARK: - Interruption parity

    @Test func pressingTalkInterruptsEveryActiveState() {
        // FR-1: pressing Talk must interrupt anything and restart listening.
        for state in allStates {
            let next = CompanionStateMachine.transition(from: state, on: .startListening(.talk))
            #expect(next == .listening(.talk), "startListening from \(state)")
        }
    }

    // MARK: - Cancellation availability

    @Test func cancelIsAvailableFromEveryNonIdleState() {
        for state in allStates where !state.isIdle {
            let next = CompanionStateMachine.transition(from: state, on: .cancel)
            #expect(next == .idle, "cancel from \(state) must return to idle")
        }
    }

    @Test func cancelFromIdleIsRejected() {
        #expect(CompanionStateMachine.transition(from: .idle, on: .cancel) == nil)
        #expect(CompanionStateMachine.transition(from: .idle, on: .interactionFinished) == nil)
    }

    // MARK: - Agent loop

    @Test func agentApprovalLoopTransitions() {
        var state = CompanionState.idle

        state = CompanionStateMachine.transition(from: state, on: .agentStarted(Self.agentID))!
        #expect(state == .agentRunning(Self.agentID))

        state = CompanionStateMachine.transition(from: state, on: .approvalRequested(Self.agentID))!
        #expect(state == .waitingForApproval(Self.agentID))

        state = CompanionStateMachine.transition(from: state, on: .approvalResolved(Self.agentID))!
        #expect(state == .agentRunning(Self.agentID))

        state = CompanionStateMachine.transition(from: state, on: .interactionFinished)!
        #expect(state == .idle)
    }

    @Test func approvalResolutionRequiresMatchingWaitingState() {
        // Resolving an approval while merely running the agent is illegal.
        #expect(
            CompanionStateMachine.transition(
                from: .agentRunning(Self.agentID),
                on: .approvalResolved(Self.agentID)
            ) == nil
        )
        // Requesting a second approval while already waiting is illegal.
        #expect(
            CompanionStateMachine.transition(
                from: .waitingForApproval(Self.agentID),
                on: .approvalRequested(Self.agentID)
            ) == nil
        )
    }

    @Test func agentsStartFromIdleErrorOrAnExistingAgent() {
        #expect(CompanionStateMachine.transition(from: .idle, on: .agentStarted(Self.agentID)) != nil)
        #expect(CompanionStateMachine.transition(from: .error("x"), on: .agentStarted(Self.agentID)) != nil)
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        #expect(
            CompanionStateMachine.transition(
                from: .agentRunning(Self.agentID),
                on: .agentStarted(secondID)
            ) == .agentRunning(secondID)
        )
        #expect(CompanionStateMachine.transition(from: .thinking, on: .agentStarted(Self.agentID)) == nil)
        #expect(CompanionStateMachine.transition(from: .speaking, on: .agentStarted(Self.agentID)) == nil)
    }

    @Test func fakeAdapterApprovalAndFinishDriveTheTable() {
        let firstID = Self.agentID
        var state = CompanionState.idle
        state = CompanionStateMachine.transition(from: state, on: .agentStarted(firstID))!
        #expect(state == .agentRunning(firstID))

        state = CompanionStateMachine.transition(from: state, on: .approvalRequested(firstID))!
        #expect(state == .waitingForApproval(firstID))

        state = CompanionStateMachine.transition(from: state, on: .approvalResolved(firstID))!
        #expect(state == .agentRunning(firstID))

        state = CompanionStateMachine.transition(from: state, on: .interactionFinished)!
        #expect(state == .idle)
    }

    // MARK: - Failure handling

    @Test func failEntersErrorStateThenRecoversViaInteractionFinished() {
        var state = CompanionState.thinking
        state = CompanionStateMachine.transition(from: state, on: .fail("provider down"))!
        #expect(state == .error("provider down"))

        // Recovery: either natural completion or a new Talk press.
        state = CompanionStateMachine.transition(from: state, on: .interactionFinished)!
        #expect(state == .idle)
    }

    @Test func failFromIdleIsRejected() {
        #expect(CompanionStateMachine.transition(from: .idle, on: .fail("nope")) == nil)
    }

    // MARK: - Illegal stomps rejected

    @Test func domainEventsAreRejectedFromWrongStates() {
        #expect(CompanionStateMachine.transition(from: .idle, on: .contextCaptured) == nil)
        #expect(CompanionStateMachine.transition(from: .idle, on: .beginSpeaking) == nil)
        #expect(CompanionStateMachine.transition(from: .thinking, on: .finishListening) == nil)
        #expect(CompanionStateMachine.transition(from: .capturingContext, on: .beginGuidance) == nil)
        #expect(CompanionStateMachine.transition(from: .guiding, on: .beginGuidance) == nil)
        #expect(CompanionStateMachine.transition(from: .speaking, on: .beginSpeaking) == nil)
    }

    @Test func typedTalkCanCaptureFromIdle() {
        var state = CompanionState.idle
        state = CompanionStateMachine.transition(from: state, on: .beginContextCapture)!
        #expect(state == .capturingContext)
        state = CompanionStateMachine.transition(from: state, on: .contextCaptured)!
        #expect(state == .thinking)

        state = CompanionStateMachine.transition(from: .error("x"), on: .beginContextCapture)!
        #expect(state == .capturingContext)
    }
    /// A Talk turn taken while an agent works leaves the machine in `.idle`,
    /// and an approval request is only legal from that run's own
    /// `.agentRunning`. This is why `handleAgentEvent` claims the foreground
    /// before asking — without it the notch never interrupts and the agent
    /// blocks on an answer nobody can give.
    @Test func approvalRequestIsIllegalOnceATalkTurnHasReturnedToIdle() {
        #expect(
            CompanionStateMachine.transition(
                from: .idle,
                on: .approvalRequested(Self.agentID)
            ) == nil
        )
    }

    /// The two-step the manager performs instead: reclaim `.agentRunning`,
    /// then ask. Legal from idle, so a decision survives an intervening Talk.
    @Test func reclaimingTheForegroundMakesTheApprovalRequestLegalAgain() {
        let reclaimedState = CompanionStateMachine.transition(
            from: .idle,
            on: .agentStarted(Self.agentID)
        )
        #expect(reclaimedState == .agentRunning(Self.agentID))

        #expect(
            CompanionStateMachine.transition(
                from: .agentRunning(Self.agentID),
                on: .approvalRequested(Self.agentID)
            ) == .waitingForApproval(Self.agentID)
        )
    }

    /// The same two-step run from where a finished Talk turn actually lands,
    /// including a run that was already waiting when the user spoke.
    @Test func aPendingDecisionCanBeRestoredFromWaitingForApproval() {
        #expect(
            CompanionStateMachine.transition(
                from: .waitingForApproval(Self.agentID),
                on: .agentStarted(Self.agentID)
            ) == .agentRunning(Self.agentID)
        )
    }

}
