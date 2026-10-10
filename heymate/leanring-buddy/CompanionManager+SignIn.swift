//
//  CompanionManager+SignIn.swift
//  leanring-buddy
//
//  The onboarding question "which AI do you already pay for?" and the
//  "sign in to Claude" action a failed question surfaces. The work itself
//  lives in `SubscriptionSignInCoordinator`; this only maps answers to brains.
//

import Foundation

/// The three answers onboarding offers.
nonisolated enum OnboardingAIChoice: String, CaseIterable, Identifiable {
    case claude
    case chatGPT
    case neither

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .chatGPT: return "ChatGPT"
        case .neither: return "Neither"
        }
    }

    var brain: AgentBrain {
        switch self {
        case .claude: return .claudeCode
        case .chatGPT: return .codex
        case .neither: return .onDevice
        }
    }

    /// The CLI to install and sign in. Nil for "Neither".
    var executor: HeadlessExecutor? {
        switch self {
        case .claude: return .claudeCode
        case .chatGPT: return .codex
        case .neither: return nil
        }
    }

    init?(executor: HeadlessExecutor) {
        switch executor {
        case .claudeCode: self = .claude
        case .codex: self = .chatGPT
        case .openCode: return nil
        }
    }
}

extension CompanionManager {

    /// Onboarding answer: pick the brain, then install and sign in its CLI.
    func chooseOnboardingAI(_ choice: OnboardingAIChoice) {
        setSelectedBrain(choice.brain)
        if let executor = choice.executor {
            // One that is already signed in needs nothing more.
            if subscriptionSignIn.executor == executor, subscriptionSignIn.phase.isReady { return }
            subscriptionSignIn.begin(executor)
        } else {
            subscriptionSignIn.cancel()
        }
    }

    /// Before the user answers: the subscription CLI that is already signed
    /// in, if any, so onboarding can preselect it. The current brain wins a
    /// tie. Does not change the brain — the caller does that only if the
    /// user has not picked something in the meantime.
    func findSignedInSubscription() async -> OnboardingAIChoice? {
        var preferredOrder: [HeadlessExecutor] = [.claudeCode, .codex]
        if let current = selectedBrain.executor, current.usesSubscriptionSignIn {
            preferredOrder.removeAll { $0 == current }
            preferredOrder.insert(current, at: 0)
        }
        guard let executor = await subscriptionSignIn.adoptExistingSignIn(among: preferredOrder) else {
            return nil
        }
        return OnboardingAIChoice(executor: executor)
    }

    /// The executor whose missing sign-in just failed a question, if the
    /// selected brain runs on one. Records it so the notch offers the fix.
    @discardableResult
    func noteSubscriptionSignInNeeded() -> HeadlessExecutor? {
        guard let executor = selectedBrain.executor, executor.usesSubscriptionSignIn else { return nil }
        subscriptionSignIn.noteSignInNeeded(for: executor)
        return executor
    }

    /// Chat line for a question that failed on a signed-out or missing CLI.
    func subscriptionSignInNeededMessage() -> String {
        if let executor = selectedBrain.executor {
            return SubscriptionSignInCopy.signInNeededMessage(for: executor)
        }
        return "\(selectedBrain.displayName) needs you to sign in again. Open Settings → AI & Accounts to sign in."
    }
}
