//
//  DesktopSettingsAccountsTab.swift
//  leanring-buddy
//
//  Settings › Accounts: the one AI question an everyday user has to answer.
//
//  The brain picker used to offer five engines side by side — Codex,
//  Claude, OpenCode, Custom API, On this Mac — with CLI vocabulary under
//  each. Most people only need to say which plan they already pay for, so
//  this tab asks exactly that and offers three answers. OpenCode and a
//  custom API still exist; they live under Advanced.
//
//  Signing in is handed off by notification rather than called directly:
//  a separate coordinator owns the subscription sign-in flow, and this tab
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

struct DesktopSettingsAccountsTab: View {
    @ObservedObject var companionManager: CompanionManager
    /// Jumps to the Advanced tab, for someone on OpenCode or a custom API.
    var onShowAdvanced: () -> Void

    /// The answers to "Which AI do you pay for?", in the order shown.
    static let everydayBrains: [AgentBrain] = [.claudeCode, .codex, .onDevice]

    /// Posted with `["executor": HeadlessExecutor.rawValue]`. Handled by the
    /// subscription sign-in coordinator.
    private static let beginSubscriptionSignInNotification = Notification.Name("heyMateBeginSubscriptionSignIn")

    var body: some View {
        DesktopPage(
            title: "Accounts",
            subtitle: "Which AI answers you, and the apps HeyMate can use for you."
        ) {
            yourAICard
            selectedBrainCard
            connectedAppsCard
        }
    }

    // MARK: Your AI

    private var yourAICard: some View {
        DesktopCard(
            title: "Your AI",
            footnote: "HeyMate runs on the plan you already pay for. It never bills you for AI on its own."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Which AI do you pay for?")
                        .font(DS.Fonts.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                    Spacer(minLength: 12)
                    Button("Check again") {
                        companionManager.refreshHeadlessExecutorReadiness()
                    }
                    .buttonStyle(DSTertiaryButtonStyle())
                    .help("Check the Claude and ChatGPT sign-ins again")
                }

                VStack(spacing: 8) {
                    ForEach(Self.everydayBrains, id: \.self) { brain in
                        accountRow(brain)
                    }
                }

                if !Self.everydayBrains.contains(companionManager.selectedBrain) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textTertiary)
                        Text("HeyMate is using \(companionManager.selectedBrain.displayName), set up in Advanced. Pick one above to switch back.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Open Advanced", action: onShowAdvanced)
                            .buttonStyle(DSTertiaryButtonStyle())
                    }
                }
            }
        }
    }

    private func accountRow(_ brain: AgentBrain) -> some View {
        let isSelected = companionManager.selectedBrain == brain
        let executor = brain.executor
        let status = executor.map {
            SubscriptionAccountStatus.line(for: companionManager.readiness(for: $0), executor: $0)
        }

        return HStack(spacing: 12) {
            Button {
                companionManager.setSelectedBrain(brain)
            } label: {
                HStack(spacing: 12) {
                    radioMark(isSelected: isSelected)

                    Image(systemName: brain.settingsSymbolName)
                        .font(DS.Glyph.regular)
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(accountTitle(brain))
                            .font(DS.Fonts.bodyLarge)
                            .foregroundColor(DS.Colors.textPrimary)
                        if let status {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(statusColor(status.tone))
                                    .frame(width: 6, height: 6)
                                Text(status.text)
                                    .font(DS.Fonts.caption)
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        } else {
                            Text(accountSubtitle(brain))
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Use \(accountTitle(brain))")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if let executor, let actionTitle = status?.actionTitle {
                Button(actionTitle) {
                    beginSubscriptionSignIn(executor)
                }
                .buttonStyle(DSSecondaryButtonStyle())
                .help(actionTitle == "Set up"
                    ? "Install \(accountTitle(brain)) on this Mac and sign in"
                    : "Sign in to \(accountTitle(brain)) with your own account")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(isSelected ? DS.Colors.surface2 : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(isSelected ? DS.Colors.borderStrong : DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private func radioMark(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(isSelected ? DS.Colors.textPrimary : DS.Colors.borderStrong, lineWidth: 1.5)
                .frame(width: 16, height: 16)
            if isSelected {
                Circle()
                    .fill(DS.Colors.textPrimary)
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityHidden(true)
    }

    private func accountTitle(_ brain: AgentBrain) -> String {
        switch brain {
        case .claudeCode: return "Claude"
        case .codex: return "ChatGPT"
        case .onDevice: return "On this Mac (free)"
        case .openCode, .customAPI: return brain.displayName
        }
    }

    private func accountSubtitle(_ brain: AgentBrain) -> String {
        switch brain {
        case .onDevice: return "Apple Intelligence. Private, and no plan needed."
        default: return brain.subtitle
        }
    }

    private func statusColor(_ tone: SubscriptionAccountStatus.Tone) -> Color {
        switch tone {
        case .good: return DS.Colors.success
        case .attention: return DS.Colors.warning
        case .neutral: return DS.Colors.textTertiary
        }
    }

    private func beginSubscriptionSignIn(_ executor: HeadlessExecutor) {
        NotificationCenter.default.post(
            name: Self.beginSubscriptionSignInNotification,
            object: nil,
            userInfo: ["executor": executor.rawValue]
        )
    }

    // MARK: Selected brain

    @ViewBuilder
    private var selectedBrainCard: some View {
        switch companionManager.selectedBrain {
        case .claudeCode:
            DesktopCard(
                title: "Claude model",
                footnote: "Effort and other tuning are in Advanced."
            ) {
                ClaudeModelSettingsContent(companionManager: companionManager, parts: .modelOnly)
            }
        case .codex:
            DesktopCard(
                title: "ChatGPT model",
                footnote: "Effort and other tuning are in Advanced."
            ) {
                CodexModelSettingsContent(companionManager: companionManager, parts: .modelOnly)
            }
        case .onDevice:
            DesktopCard(
                title: "On this Mac",
                footnote: companionManager.selectedBrain.unavailableReason
            ) {
                OnDeviceBrainSettingsContent(companionManager: companionManager)
            }
        case .openCode, .customAPI:
            EmptyView()
        }
    }

    // MARK: Connected apps

    private var connectedAppsCard: some View {
        DesktopCard(title: "Connected apps") {
            HStack(spacing: 12) {
                Image(systemName: "app.connected.to.app.below.fill")
                    .font(DS.Glyph.regular)
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Gmail, Slack, Calendar, and more")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Let HeyMate read and act in the apps you use. Anything it sends asks you first.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Manage") {
                    NotificationCenter.default.post(
                        name: .heyMateDesktopSelectSection,
                        object: nil,
                        userInfo: ["section": DesktopSection.connectors.rawValue]
                    )
                }
                .buttonStyle(DSSecondaryButtonStyle())
            }
        }
    }
}
