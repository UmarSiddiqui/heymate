//
//  CompanionState.swift
//  leanring-buddy
//
//  Explicit, testable state machine for the companion interaction loop
//  (master spec: idle → listening → finalizing → capturing → thinking →
//  guiding/speaking, plus agent and error states). All transitions go
//  through CompanionStateMachine.transition(from:on:) which returns nil for
//  illegal combinations — stale async callbacks therefore cannot corrupt
//  pipeline-owned state.
//

import Foundation

/// What kind of input the user is currently providing while holding a shortcut.
enum CompanionInputMode: Equatable {
    case talk
    case dictate
    case spatial
}

/// Canonical companion states. `voiceState` on CompanionManager is derived
/// from this so existing overlay/panel UI keeps working unchanged.
enum CompanionState: Equatable {
    case idle
    case listening(CompanionInputMode)
    case finalizingTranscript
    case capturingContext
    case thinking
    /// A visual action (pointer flight/annotation) is playing for the user.
    case guiding
    /// TTS audio is playing.
    case speaking
    case agentRunning(UUID)
    case waitingForApproval(UUID)
    case error(String)

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}

/// Events that drive CompanionState transitions.
enum CompanionEvent: Equatable {
    case startListening(CompanionInputMode)
    case finishListening
    case beginContextCapture
    case contextCaptured
    case beginGuidance
    case beginSpeaking
    case interactionFinished
    case agentStarted(UUID)
    case approvalRequested(UUID)
    case approvalResolved(UUID)
    case fail(String)
    case cancel
}

enum CompanionStateMachine {

    /// Pure transition function. Returns the next state, or nil when the
    /// event is illegal for the current state (caller should ignore it).
    static func transition(
        from state: CompanionState,
        on event: CompanionEvent
    ) -> CompanionState? {
        switch event {

        // Interruption parity: pressing Talk interrupts anything — TTS,
        // an in-flight response, even an agent run — and starts listening.
        case .startListening(let mode):
            return .listening(mode)

        // Cancellation must be available from every non-idle state.
        case .cancel:
            return state.isIdle ? nil : .idle

        // Natural completion also returns to idle from any active state.
        case .interactionFinished:
            return state.isIdle ? nil : .idle

        case .finishListening:
            switch state {
            case .listening:
                return .finalizingTranscript
            default:
                return nil
            }

        case .beginContextCapture:
            switch state {
            case .idle, .error, .listening, .finalizingTranscript:
                return .capturingContext
            default:
                return nil
            }

        case .contextCaptured:
            switch state {
            case .capturingContext:
                return .thinking
            default:
                return nil
            }

        case .beginGuidance:
            switch state {
            case .thinking:
                return .guiding
            default:
                return nil
            }

        case .beginSpeaking:
            switch state {
            case .thinking, .guiding:
                return .speaking
            default:
                return nil
            }

        case .agentStarted(let id):
            switch state {
            case .idle, .error, .agentRunning, .waitingForApproval:
                return .agentRunning(id)
            default:
                return nil
            }

        case .approvalRequested(let id):
            switch state {
            case .agentRunning(id):
                return .waitingForApproval(id)
            default:
                return nil
            }

        case .approvalResolved(let id):
            switch state {
            case .waitingForApproval(id):
                return .agentRunning(id)
            default:
                return nil
            }

        case .fail:
            return state.isIdle ? nil : .error(failureMessage(from: event))
        }
    }

    private static func failureMessage(from event: CompanionEvent) -> String {
        if case .fail(let message) = event { return message }
        return "unknown failure"
    }
}
