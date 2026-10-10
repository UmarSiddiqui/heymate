//
//  DesktopSettingsAccountsTab.swift
//  leanring-buddy
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

/// Settings › AI & Accounts. Keeps its historical name: tests and the `accounts` deep
/// link both refer to it.
struct DesktopSettingsAccountsTab: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var navigation: SettingsNavigationModel

    /// The answers to "Which AI do you pay for?", in the order shown.
    static let everydayBrains: [AgentBrain] = [.claudeCode, .codex, .onDevice]

    /// The engines that are not a plan most people already pay for.
    static let otherBrains: [AgentBrain] = [.openCode, .customAPI]

    /// Posted with `["executor": HeadlessExecutor.rawValue]`. Handled by the
    /// subscription sign-in coordinator.
    @State private var showsOtherEngines = false

    private static let beginSubscriptionSignInNotification = Notification.Name("heyMateBeginSubscriptionSignIn")

    var body: some View {
        SettingsPage(tab: .accounts, navigation: navigation) {
            yourAISection
            selectedBrainSection
            if companionManager.selectedBrain.offersSubscriptionVoiceChat {
                voiceChatSection
            }
            otherEnginesSection
            helperAppsSection
        }
    }

    // MARK: Your AI

    private var yourAISection: some View {
        SettingsSection(
            SettingsItem.yourAI.title,
            footer: "HeyMate runs on the plan you already pay for. It never bills you for AI on its own.",
            headerAccessory: AnyView(
                Button("Check again") {
                    companionManager.refreshHeadlessExecutorReadiness()
                }
                .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                .help("Check the Claude and ChatGPT sign-ins again")
            )
        ) {
            ForEach(Array(Self.everydayBrains.enumerated()), id: \.element) { index, brain in
                if index > 0 {
                    SettingsDivider()
                }
                accountRow(brain)
            }

            if !Self.everydayBrains.contains(companionManager.selectedBrain) {
                SettingsNotice(
                    text: "HeyMate is using \(companionManager.selectedBrain.displayName), under Other engines below. Pick one above to switch back.",
                    tone: .neutral
                )
                .settingsRowContentInsets()
                .padding(.top, DS.Spacing.sm)
            }
        }
        .settingsAnchor(.yourAI)
    }

    private func accountRow(_ brain: AgentBrain) -> some View {
        let isSelected = companionManager.selectedBrain == brain
        let executor = brain.executor
        let readiness = executor.map { companionManager.readiness(for: $0) }
        let line: SubscriptionAccountStatus.Line? = executor.flatMap { executor in
            readiness.map { SubscriptionAccountStatus.line(for: $0, executor: executor) }
        }
        let status = statusPresentation(line: line, readiness: readiness)

        return SettingsChoiceRow(
            accountTitle(brain),
            subtitle: accountSubtitle(brain),
            status: status,
            systemImage: brain.settingsSymbolName,
            isSelected: isSelected,
            select: { companionManager.setSelectedBrain(brain) }
        ) {
            if let executor, let actionTitle = line?.actionTitle {
                Button(actionTitle) {
                    beginSubscriptionSignIn(executor)
                }
                .dsCapsuleButtonStyle(line?.tone == .good ? .quiet : .secondary)
                .help(actionTitle == "Set up"
                    ? "Install \(accountTitle(brain)) on this Mac and sign in"
                    : "Sign in to \(accountTitle(brain)) with your own account")
                .accessibilityLabel("\(actionTitle), \(accountTitle(brain))")
            }
        }
        .brandMark(brain)
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

    /// The status shown under an account. "Checking…" spins rather than
    /// sitting there looking like a verdict.
    private func statusPresentation(
        line: SubscriptionAccountStatus.Line?,
        readiness: HeadlessExecutorReadiness?
    ) -> (text: String, tone: SettingsStatusTone)? {
        guard let line, let readiness else { return nil }
        let isChecking = readiness.state == .indeterminate
            && readiness.detail == SubscriptionAccountStatus.unprobedDetail
        return (text: line.text, tone: isChecking ? .progress : statusTone(line.tone))
    }

    private func statusTone(_ tone: SubscriptionAccountStatus.Tone) -> SettingsStatusTone {
        switch tone {
        case .good: return .positive
        case .attention: return .attention
        case .neutral: return .neutral
        }
    }

    private func beginSubscriptionSignIn(_ executor: HeadlessExecutor) {
        NotificationCenter.default.post(
            name: Self.beginSubscriptionSignInNotification,
            object: nil,
            userInfo: ["executor": executor.rawValue]
        )
    }

    // MARK: Model and effort

    @ViewBuilder
    private var selectedBrainSection: some View {
        switch companionManager.selectedBrain {
        case .claudeCode:
            claudeModelSection
        case .codex:
            codexModelSection
        case .onDevice:
            onDeviceSection
        case .openCode, .customAPI:
            EmptyView()
        }
    }

    private var claudeModelSection: some View {
        SettingsSection(
            "Claude model",
            footer: "Models come from the Claude app on this Mac. Talk and agent jobs use the model and effort you pick."
        ) {
            SettingsRow(SettingsItem.model.title, item: .model) {
                HStack(spacing: DS.Spacing.xs) {
                    SettingsRefreshButton(
                        isRefreshing: companionManager.isClaudeModelRefreshInFlight,
                        accessibilityTitle: "Refresh Claude models"
                    ) {
                        Task { await companionManager.refreshClaudeModelCatalog() }
                    }
                    DSMenuPicker(
                        accessibilityTitle: "Claude model",
                        selection: Binding(
                            get: { companionManager.selectedClaudeModelID },
                            set: { modelID in
                                if let option = companionManager.claudeModels.first(where: { $0.id == modelID }) {
                                    companionManager.setSelectedClaudeModel(option)
                                }
                            }
                        ),
                        options: companionManager.claudeModels.map {
                            DSMenuOption(value: $0.id, title: $0.displayName)
                        },
                        placeholder: companionManager.selectedClaudeModelLabel
                    )
                }
            }

            SettingsDivider()

            if companionManager.claudeEfforts.isEmpty {
                SettingsRow(
                    SettingsItem.effort.title,
                    subtitle: "The selected Claude model has no effort setting.",
                    item: .effort
                )
            } else {
                SettingsPickerRow(
                    SettingsItem.effort.title,
                    subtitle: "Higher effort thinks longer before answering. Auto lets Claude choose.",
                    item: .effort,
                    selection: Binding(
                        get: { companionManager.selectedClaudeEffortIfSupported ?? "" },
                        set: { companionManager.setSelectedClaudeEffort($0) }
                    ),
                    options: [DSMenuOption(value: "", title: "Auto")]
                        + companionManager.claudeEfforts.enumerated().map { index, option in
                            DSMenuOption(value: option.effort, title: option.displayName, startsGroup: index == 0)
                        },
                    placeholder: "Auto"
                )
            }

            if let errorText = companionManager.claudeModelCatalogErrorText {
                SettingsNotice(text: errorText, tone: .attention)
                    .settingsRowContentInsets()
            }
        }
    }

    private var codexModelSection: some View {
        SettingsSection(
            "ChatGPT model",
            footer: "Models come from your ChatGPT sign-in. Quick typed questions use a fast model; screen questions and agent jobs use the one you pick."
        ) {
            if companionManager.codexModels.isEmpty {
                SettingsRow(
                    SettingsItem.model.title,
                    subtitle: companionManager.isCodexModelRefreshInFlight
                        ? "Loading ChatGPT models…"
                        : "No ChatGPT models yet. Sign in to ChatGPT above, then refresh.",
                    item: .model
                ) {
                    SettingsRefreshButton(
                        isRefreshing: companionManager.isCodexModelRefreshInFlight,
                        accessibilityTitle: "Refresh ChatGPT models"
                    ) {
                        Task { await companionManager.refreshCodexModelCatalog() }
                    }
                }
            } else {
                SettingsRow(SettingsItem.model.title, item: .model) {
                    HStack(spacing: DS.Spacing.xs) {
                        SettingsRefreshButton(
                            isRefreshing: companionManager.isCodexModelRefreshInFlight,
                            accessibilityTitle: "Refresh ChatGPT models"
                        ) {
                            Task { await companionManager.refreshCodexModelCatalog() }
                        }
                        DSMenuPicker(
                            accessibilityTitle: "ChatGPT model",
                            selection: Binding(
                                get: { companionManager.selectedCodexModelID },
                                set: { modelID in
                                    if let option = companionManager.codexModels.first(where: { $0.model == modelID }) {
                                        companionManager.setSelectedCodexModel(option)
                                    }
                                }
                            ),
                            options: companionManager.codexModels.map {
                                DSMenuOption(value: $0.model, title: $0.displayName)
                            },
                            placeholder: "Choose model"
                        )
                    }
                }
            }

            SettingsDivider()

            if let selectedModel = companionManager.selectedCodexModel,
               !selectedModel.supportedReasoningEfforts.isEmpty {
                SettingsPickerRow(
                    SettingsItem.effort.title,
                    subtitle: "Higher effort thinks longer before answering.",
                    item: .effort,
                    selection: Binding(
                        get: { companionManager.selectedCodexReasoningEffort },
                        set: { companionManager.setSelectedCodexReasoningEffort($0) }
                    ),
                    options: selectedModel.supportedReasoningEfforts.map {
                        DSMenuOption(value: $0.reasoningEffort, title: $0.displayName)
                    },
                    placeholder: companionManager.selectedCodexReasoningEffort.capitalized
                )
            } else {
                SettingsRow(
                    SettingsItem.effort.title,
                    subtitle: "The selected ChatGPT model has no effort setting.",
                    item: .effort
                )
            }

            if let errorText = companionManager.codexModelCatalogErrorText {
                SettingsNotice(text: errorText, tone: .attention)
                    .settingsRowContentInsets()
            }
        }
    }

    private var onDeviceSection: some View {
        SettingsSection("On this Mac") {
            SettingsRow(
                "Apple Intelligence",
                subtitle: OnDeviceLanguageAvailability.statusLine,
                systemImage: "apple.intelligence",
                item: .model
            )
            if let reason = companionManager.selectedBrain.unavailableReason {
                SettingsNotice(text: reason, tone: .attention)
                    .settingsRowContentInsets()
            }
            SettingsDivider()
            SettingsRow(
                "Things to try",
                subtitle: "Say “image playground” and a description to open Apple's Image Playground. Say “start meeting notes” to keep the words of a call. Audio is not saved.",
                systemImage: "lightbulb"
            )
        }
    }

    // MARK: Voice chat

    private var voiceChatSection: some View {
        SettingsSection(
            footer: "It's the plan you already pay for, not a separate voice service."
        ) {
            SettingsRow(
                SettingsItem.voiceChat.title,
                subtitle: "Listens, your plan answers, and this Mac speaks the reply.",
                systemImage: "waveform",
                item: .voiceChat
            ) {
                HStack(spacing: DS.Spacing.sm) {
                    if companionManager.isSubscriptionVoiceChatActive {
                        SettingsStatusBadge(text: "On", tone: .positive)
                    }
                    Button(companionManager.isSubscriptionVoiceChatActive ? "Stop voice chat" : "Start voice chat") {
                        companionManager.toggleSubscriptionVoiceChat()
                    }
                    .dsCapsuleButtonStyle(.secondary)
                }
            }
        }
    }

    // MARK: Other engines

    private var otherEnginesSection: some View {
        SettingsSection(
            footer: usesOtherEngine ? "To go back to a plan, pick Claude, ChatGPT, or On this Mac above." : nil
        ) {
            SettingsDisclosureRow(
                SettingsItem.otherEngines.title,
                subtitle: "OpenCode or your own API server.",
                isExpanded: Binding(
                    get: { showsOtherEngines || usesOtherEngine },
                    set: { showsOtherEngines = $0 }
                )
            ) {
            SettingsDivider()
            ForEach(Array(Self.otherBrains.enumerated()), id: \.element) { index, brain in
                if index > 0 {
                    SettingsDivider()
                }
                SettingsChoiceRow(
                    brain.displayName,
                    subtitle: brain.subtitle,
                    systemImage: brain.settingsSymbolName,
                    isSelected: companionManager.selectedBrain == brain,
                    select: { companionManager.setSelectedBrain(brain) }
                )
                .brandMark(brain)
                if companionManager.selectedBrain == brain {
                    otherEngineSetup(brain)
                }
            }
            }
        }
        .settingsAnchor(.otherEngines)
    }

    private var usesOtherEngine: Bool {
        Self.otherBrains.contains(companionManager.selectedBrain)
    }

    @ViewBuilder
    private func otherEngineSetup(_ brain: AgentBrain) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let reason = brain.unavailableReason {
                SettingsNotice(text: reason, tone: .attention)
                    .settingsRowContentInsets()
            }
            switch brain {
            case .openCode:
                OpenCodeSettingsRows(companionManager: companionManager)
            case .customAPI:
                CustomAPISettingsRows(companionManager: companionManager)
            default:
                EmptyView()
            }
        }
        .background(DS.Colors.surface2)
    }

    // MARK: Helper apps

    private var helperAppsSection: some View {
        SettingsSection(
            "Helper apps",
            footer: "Keeps Claude, Codex, and OpenCode current so new models appear."
        ) {
            SettingsToggleRow(
                SettingsItem.helperApps.title,
                subtitle: "Once a day, when HeyMate opens.",
                item: .helperApps,
                isOn: $companionManager.keepsSubscriptionCLIsUpdated
            )
            SettingsDivider()
            SettingsRow(
                "Update now",
                subtitle: companionManager.subscriptionCLIUpdateStatusText
            ) {
                if companionManager.isSubscriptionCLIUpdateInFlight {
                    SettingsStatusBadge(text: "Updating…", tone: .progress)
                } else {
                    Button("Update now") {
                        Task { await companionManager.updateSubscriptionCLIsNow() }
                    }
                    .dsCapsuleButtonStyle(.secondary)
                }
            }
        }
    }
}
