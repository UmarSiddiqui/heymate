//
//  DesktopSettingsAccountsTab.swift
//  HeyMate
//
//  Settings › AI & Accounts: which AI answers you, its model and effort, voice chat,
//  the engines most people never need, and the helper apps that keep it all
//  current.
//
//  The everyday question is "which plan do you already pay for", answered
//  with three choices. OpenCode and a custom API are real options too, but
//  sit in their own section below and only show their setup once chosen.
//  Model and effort live together now; they used to be split across two
//  tabs with footnotes pointing at each other.
//
//  Signing in is handed off by notification rather than called directly:
//  a separate coordinator owns the subscription sign-in flow, and this page
//  only says which account the user wants to connect.
//

import SwiftUI

/// Plain-language sign-in status for a subscription account row.
///
/// The readiness probe speaks in CLI terms ("Signed out of the Codex CLI",
/// "API key (not claude.ai)"). This turns it into what a user would say about
/// their account, plus the one action that fixes it.
nonisolated enum SubscriptionAccountStatus {

    enum Tone: Equatable {
        case good
        case attention
        case neutral
    }

    struct Line: Equatable {
        var text: String
        var tone: Tone
        /// Title for the row's button. Nil when there is nothing to do.
        var actionTitle: String?
    }

    /// The probe's default before it has run once. Shown as "Checking…"
    /// rather than as a failure.
    static let unprobedDetail = HeadlessExecutorReadiness.indeterminate().detail

    static func line(
        for readiness: HeadlessExecutorReadiness,
        executor: HeadlessExecutor
    ) -> Line {
        switch readiness.state {
        case .ready:
            return Line(
                text: "Signed in · \(planDescription(from: readiness.detail, executor: executor))",
                tone: .good,
                actionTitle: "Switch account"
            )
        case .usingAPIKey:
            return Line(
                text: "Signed in with an API key, which may bill separately from your plan",
                tone: .attention,
                actionTitle: "Sign in"
            )
        case .notInstalled:
            return Line(text: "Not installed", tone: .attention, actionTitle: "Set up")
        case .notSignedIn:
            return Line(text: "Not signed in", tone: .attention, actionTitle: "Sign in")
        case .indeterminate:
            if readiness.detail == unprobedDetail {
                return Line(text: "Checking…", tone: .neutral, actionTitle: "Sign in")
            }
            return Line(
                text: "Installed · couldn't confirm sign-in",
                tone: .neutral,
                actionTitle: "Sign in"
            )
        }
    }

    /// "Claude Pro · you@example.com" reads fine as is. The Codex probe says
    /// "Codex · ChatGPT subscription"; the user knows it as ChatGPT, so the
    /// CLI's name is dropped.
    static func planDescription(from detail: String, executor: HeadlessExecutor) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard executor == .codex else { return trimmed.isEmpty ? executor.displayName : trimmed }
        let codexPrefix = "Codex · "
        let withoutCLIName = trimmed.hasPrefix(codexPrefix)
            ? String(trimmed.dropFirst(codexPrefix.count))
            : trimmed
        return withoutCLIName.isEmpty ? "ChatGPT" : withoutCLIName
    }
}

/// The single Brain page. Historical type name is retained for source compatibility.
struct DesktopSettingsAccountsTab: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var navigation: SettingsNavigationModel
    static let everydayBrains: [AgentBrain] = [.claudeCode, .codex]
    static let otherBrains: [AgentBrain] = []
    @State private var mateAgentSetupBusy = false
    @State private var executablePath = ""
    @State private var profilePath = MateAgentEngineConfiguration.defaultProfilePath
    @State private var runtimePath = ""

    private var isLocked: Bool {
        companionManager.isResponseInFlight || companionManager.isMateAgentTurnInFlight
            || !companionManager.mateAgentRecoveryBlockedChatIDs.isEmpty
    }

    var body: some View {
        SettingsPage(tab: .brain, navigation: navigation) {
            if isLocked {
                SettingsNotice(text: companionManager.mateAgentRecoveryBlockedChatIDs.isEmpty
                    ? "HeyMate is answering right now. Brain unlocks when it finishes."
                    : "A chat needs review after an interrupted turn. Open it and review before changing Brain.",
                    tone: .attention)
            }
            // The pane draws its own Subscription, Model and Effort sections.
            MateAgentSetupPane(executablePath: $executablePath, profilePath: $profilePath,
                               runtimePath: $runtimePath, isWorking: $mateAgentSetupBusy)
                .settingsAnchor(.yourAI)
                .disabled(isLocked)
        }
    }
}
