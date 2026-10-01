//
//  AISettingsComponents.swift
//  leanring-buddy
//
//  The brain, model, audio, and agent controls, cut out of AISettingsView so
//  two surfaces can place the same controls differently: the notch keeps one
//  long column, and the desktop Settings tabs put the everyday choice under
//  Accounts and the power-user knobs under Advanced.
//
//  Each piece is card *content* only — no card chrome. The notch wraps it in
//  `AISettingsCard`, the desktop in `DesktopCard`, so neither surface ends up
//  with a card inside a card. Pieces that need draft state (the custom API
//  fields, the OpenCode search, a pending sign-out) own it, so a control
//  behaves the same wherever it is placed.
//

import SwiftUI

// MARK: - Refresh

enum AISettingsRefresh {
    /// Everything the brain and model controls read from a CLI or a probe.
    /// Run once when a settings surface appears; the Google card refreshes
    /// its own status.
    static func refreshCatalogsAndReadiness(_ companionManager: CompanionManager) async {
        await companionManager.refreshClaudeModelCatalog()
        await companionManager.refreshCodexModelCatalog()
        await companionManager.refreshOpenCodeServerStatus()
        companionManager.refreshHeadlessCLIStatus()
    }
}

// MARK: - Building blocks

/// The notch's settings card. Desktop pages use `DesktopCard` instead.
struct AISettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard()
    }
}

struct AISettingsLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(DS.Fonts.body)
            .foregroundColor(DS.Colors.textSecondary)
    }
}

struct AISettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(DS.Fonts.micro)
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The closed state of a model or effort menu.
struct AISettingsMenuLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(DS.Fonts.micro)
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .fill(DS.Colors.surface2.opacity(0.72))
        )
    }
}

extension View {
    /// The rounded, hairline-bordered well every settings text field sits in.
    func aiSettingsFieldChrome() -> some View {
        self
            .textFieldStyle(.plain)
            .font(DS.Fonts.caption)
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(DS.Colors.surface2.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
    }
}

/// A small refresh glyph that turns into a spinner while its work runs.
private struct AISettingsRefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void

    var body: some View {
        if isRefreshing {
            ProgressView()
                .controlSize(.small)
        } else {
            Button(action: action) {
                Image(systemName: "arrow.clockwise")
                    .font(DS.Fonts.micro)
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Colors.textSecondary)
            .pointerCursor()
        }
    }
}

// MARK: - Brain picker

extension AgentBrain {
    var settingsSymbolName: String {
        switch self {
        case .codex: return "sparkles"
        case .claudeCode: return "brain.head.profile"
        case .openCode: return "terminal"
        case .customAPI: return "point.3.connected.trianglepath.dotted"
        case .onDevice: return "apple.intelligence"
        }
    }
}

/// Tile grid of brains. The notch shows all five; desktop Advanced shows only
/// the two that are not a plan someone already pays for.
struct BrainChoiceGrid: View {
    @ObservedObject var companionManager: CompanionManager
    var brains: [AgentBrain] = AgentBrain.allCases

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120), spacing: 7)],
            spacing: 7
        ) {
            ForEach(brains, id: \.self) { brain in
                brainChoiceButton(brain)
            }
        }
    }

    private func brainChoiceButton(_ brain: AgentBrain) -> some View {
        let isSelected = companionManager.selectedBrain == brain
        return Button {
            companionManager.setSelectedBrain(brain)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: brain.settingsSymbolName)
                    .font(DS.Fonts.headline)
                Text(brain.displayName)
                    .font(DS.Fonts.body)
                    .lineLimit(1)
            }
            .foregroundColor(isSelected ? DS.Colors.textOnAccent : DS.Colors.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isSelected ? companionManager.themeColor : DS.Colors.surface2.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(
                        isSelected ? companionManager.themeColor.opacity(0.85) : DS.Colors.borderSubtle,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(brain.subtitle)
        .accessibilityLabel("Use \(brain.displayName) as HeyMate brain")
    }
}

// MARK: - Keep the AI apps updated

struct CLIUpdateSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                AISettingsLabel("Keep AI apps up to date")
                Spacer()
                Toggle("", isOn: $companionManager.keepsSubscriptionCLIsUpdated)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel("Keep Claude, Codex, and OpenCode updated")
            }
            AISettingsFootnote("On by default. Once a day, when HeyMate opens, it updates the Claude, Codex, and OpenCode helper apps on this Mac so new models show up in the picker.")
            Button {
                Task { await companionManager.updateSubscriptionCLIsNow() }
            } label: {
                HStack(spacing: 6) {
                    if companionManager.isSubscriptionCLIUpdateInFlight {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(DS.Fonts.micro)
                    }
                    Text("Update now")
                        .font(DS.Fonts.body)
                }
                .foregroundColor(DS.Colors.accentText)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(companionManager.isSubscriptionCLIUpdateInFlight)
            if let status = companionManager.subscriptionCLIUpdateStatusText {
                Text(status)
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Model and effort

/// Which half of a model card to show. The notch shows both; desktop puts
/// the model under Accounts and effort under Advanced.
enum BrainModelSettingsParts {
    case modelAndEffort
    case modelOnly
    case effortOnly

    var showsModel: Bool { self != .effortOnly }
    var showsEffort: Bool { self != .modelOnly }
}

/// Same shape as `CodexModelSettingsContent` — Model menu, then Effort menu —
/// so switching engines never changes where a control lives.
struct ClaudeModelSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager
    var parts: BrainModelSettingsParts = .modelAndEffort

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if parts.showsModel {
                HStack {
                    AISettingsLabel("Model")
                    Spacer()
                    AISettingsRefreshButton(isRefreshing: companionManager.isClaudeModelRefreshInFlight) {
                        Task { await companionManager.refreshClaudeModelCatalog() }
                    }
                }

                Menu {
                    ForEach(companionManager.claudeModels) { option in
                        Button {
                            companionManager.setSelectedClaudeModel(option)
                        } label: {
                            if option.id == companionManager.selectedClaudeModelID {
                                Label(option.displayName, systemImage: "checkmark")
                            } else {
                                Text(option.displayName)
                            }
                        }
                    }
                } label: {
                    AISettingsMenuLabel(title: companionManager.selectedClaudeModelLabel)
                }
                .menuStyle(.borderlessButton)
                .pointerCursor()
            }

            if parts.showsEffort {
                if !companionManager.claudeEfforts.isEmpty {
                    AISettingsLabel("Effort")
                    Menu {
                        Button {
                            companionManager.setSelectedClaudeEffort("")
                        } label: {
                            if companionManager.selectedClaudeEffortIfSupported == nil {
                                Label("Auto", systemImage: "checkmark")
                            } else {
                                Text("Auto")
                            }
                        }
                        ForEach(companionManager.claudeEfforts) { option in
                            Button {
                                companionManager.setSelectedClaudeEffort(option.effort)
                            } label: {
                                if option.effort == companionManager.selectedClaudeEffortIfSupported {
                                    Label(option.displayName, systemImage: "checkmark")
                                } else {
                                    Text(option.displayName)
                                }
                            }
                        }
                    } label: {
                        AISettingsMenuLabel(
                            title: companionManager.claudeEfforts
                                .first { $0.effort == companionManager.selectedClaudeEffortIfSupported }?
                                .displayName ?? "Auto"
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .pointerCursor()
                } else if parts == .effortOnly {
                    Text("The selected Claude model has no effort setting.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            if let errorText = companionManager.claudeModelCatalogErrorText {
                Text(errorText)
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AISettingsFootnote(footnote)
        }
    }

    private var footnote: String {
        switch parts {
        case .modelAndEffort:
            return "Models come from the Claude app on this Mac. Talk and agent jobs use the model and effort you pick; Auto lets Claude choose the effort."
        case .modelOnly:
            return "Models come from the Claude app on this Mac. Talk and agent jobs use the one you pick."
        case .effortOnly:
            return "Higher effort thinks longer before answering. Auto lets Claude choose."
        }
    }
}

struct CodexModelSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager
    var parts: BrainModelSettingsParts = .modelAndEffort

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if parts.showsModel {
                HStack {
                    AISettingsLabel("Model")
                    Spacer()
                    AISettingsRefreshButton(isRefreshing: companionManager.isCodexModelRefreshInFlight) {
                        Task { await companionManager.refreshCodexModelCatalog() }
                    }
                }

                if companionManager.codexModels.isEmpty {
                    Text(companionManager.isCodexModelRefreshInFlight ? "Loading ChatGPT models…" : "No ChatGPT models yet. Sign in to ChatGPT first.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                } else {
                    Menu {
                        ForEach(companionManager.codexModels) { option in
                            Button {
                                companionManager.setSelectedCodexModel(option)
                            } label: {
                                if option.model == companionManager.selectedCodexModelID {
                                    Label(option.displayName, systemImage: "checkmark")
                                } else {
                                    Text(option.displayName)
                                }
                            }
                        }
                    } label: {
                        AISettingsMenuLabel(
                            title: companionManager.selectedCodexModel?.displayName ?? "Choose model"
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .pointerCursor()
                }
            }

            if parts.showsEffort {
                if let selectedModel = companionManager.selectedCodexModel,
                   !selectedModel.supportedReasoningEfforts.isEmpty {
                    AISettingsLabel("Effort")
                    Menu {
                        ForEach(selectedModel.supportedReasoningEfforts) { option in
                            Button {
                                companionManager.setSelectedCodexReasoningEffort(option.reasoningEffort)
                            } label: {
                                if option.reasoningEffort == companionManager.selectedCodexReasoningEffort {
                                    Label(option.displayName, systemImage: "checkmark")
                                } else {
                                    Text(option.displayName)
                                }
                            }
                        }
                    } label: {
                        AISettingsMenuLabel(
                            title: companionManager.selectedCodexReasoningEffort.capitalized
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .pointerCursor()
                } else if parts == .effortOnly {
                    Text("The selected ChatGPT model has no effort setting.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            if let errorText = companionManager.codexModelCatalogErrorText {
                Text(errorText)
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AISettingsFootnote(footnote)
        }
    }

    private var footnote: String {
        switch parts {
        case .modelAndEffort:
            return "Models come from your ChatGPT sign-in. Quick typed questions use a fast model; screen questions and agent jobs use the model and effort you pick."
        case .modelOnly:
            return "Models come from your ChatGPT sign-in. Quick typed questions use a fast model; screen questions and agent jobs use the one you pick."
        case .effortOnly:
            return "Higher effort thinks longer before answering."
        }
    }
}

// MARK: - Voice chat

struct VoiceChatSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AISettingsLabel("Voice chat")
            AISettingsFootnote("Listens, your ChatGPT or Claude plan answers, and this Mac speaks the reply. It is the plan you already pay for, not a separate voice service.")
            VoiceChatToggleButton(companionManager: companionManager)
        }
    }
}

struct VoiceChatToggleButton: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        Button {
            companionManager.toggleSubscriptionVoiceChat()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: companionManager.isSubscriptionVoiceChatActive ? "waveform" : "mic.fill")
                    .font(DS.Fonts.micro)
                Text(companionManager.isSubscriptionVoiceChatActive ? "Stop voice chat" : "Start voice chat")
                    .font(DS.Fonts.body)
            }
            .foregroundColor(DS.Colors.accentText)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Listens, your ChatGPT or Claude plan answers, and this Mac speaks the reply.")
    }
}

// MARK: - On this Mac

struct OnDeviceBrainSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AISettingsLabel("Apple Intelligence")
            AISettingsFootnote(OnDeviceLanguageAvailability.statusLine)
            if companionManager.selectedBrain.offersSubscriptionVoiceChat {
                VoiceChatToggleButton(companionManager: companionManager)
            }
            AISettingsFootnote("Say image playground and a description to open Apple's image playground. Say start meeting notes to keep the words of a call. Audio is not saved.")
        }
    }
}

// MARK: - Custom API

/// The endpoint that answers screen questions.
///
/// Shown for the CLI brains too, and labelled as such: a CLI cannot answer
/// a screen question at conversational speed — a measured `claude -p` turn
/// with a screenshot took thirteen seconds — so Talk needs its own fast
/// endpoint no matter which CLI is doing the work.
struct CustomAPISettingsContent: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var customAPIBaseURL = CustomAPIConfiguration.baseURL
    @State private var customAPIModel = CustomAPIConfiguration.model
    /// Never pre-filled from the Keychain — a saved key is reported, not shown.
    @State private var customAPIKeyDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AISettingsLabel(
                companionManager.selectedBrain.talkNeedsSeparateVisionEndpoint
                    ? "Screen questions"
                    : "Your API server"
            )

            if companionManager.selectedBrain.talkNeedsSeparateVisionEndpoint {
                AISettingsFootnote("\(companionManager.selectedBrain.displayName) runs your agent jobs. Answering “what’s on my screen” needs a fast vision server, which \(companionManager.selectedBrain.displayName) cannot be — set one here or screen questions stay unanswered.")
            }

            committingTextField("Server address (https://…)", text: $customAPIBaseURL) {
                CustomAPIConfiguration.baseURL = customAPIBaseURL
            }
            committingTextField("Model name", text: $customAPIModel) {
                CustomAPIConfiguration.model = customAPIModel
            }

            HStack(spacing: 8) {
                SecureField(
                    CustomAPIConfiguration.hasAPIKey ? "Key saved — type to replace" : "API key",
                    text: $customAPIKeyDraft
                )
                .aiSettingsFieldChrome()

                Button(customAPIKeyDraft.isEmpty ? "Clear" : "Save") {
                    CustomAPIConfiguration.setAPIKey(customAPIKeyDraft)
                    customAPIKeyDraft = ""
                }
                .font(DS.Fonts.caption)
                .buttonStyle(.plain)
                .foregroundColor(DS.Colors.accentText)
                .pointerCursor()
            }

            AISettingsFootnote("Works with any Anthropic-compatible server. You pay that provider per use. The key is stored in your Keychain, never in preferences; leave it empty if the server holds its own key.")
        }
    }

    private func committingTextField(
        _ placeholder: String,
        text: Binding<String>,
        onCommit: @escaping () -> Void
    ) -> some View {
        TextField(placeholder, text: text)
            .aiSettingsFieldChrome()
            .onSubmit(onCommit)
            .onChange(of: text.wrappedValue) { _, _ in onCommit() }
    }
}

// MARK: - OpenCode

/// The OpenCode model list: searchable, grouped by provider, or an explanation
/// of why it is empty.
struct OpenCodeModelsSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var openCodeSearchText = ""

    var body: some View {
        if companionManager.openCodeModels.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(companionManager.isOpenCodeServerReachable == false
                         ? "OpenCode isn't running on this Mac"
                         : "No models yet — start OpenCode with `opencode serve` in Terminal")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                    Spacer()
                    refreshOpenCodeButton
                }
                connectionStatusView
            }
        } else {
            let groups = companionManager.openCodeProviderGroups(matching: openCodeSearchText)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                    TextField(
                        "Search \(companionManager.openCodeModels.count) models",
                        text: $openCodeSearchText
                    )
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textPrimary)
                    refreshOpenCodeButton
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .fill(DS.Colors.surface2.opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )

                connectionStatusView

                ForEach(groups, id: \.providerID) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        DSSectionLabel(title: group.providerName, accessory: "\(group.models.count)")
                            .padding(.top, 4)

                        ForEach(group.models) { option in
                            openCodeRow(option)
                        }
                    }
                }
            }
        }
    }

    private func openCodeRow(_ option: OpenCodeModelOption) -> some View {
        let isSelected = option.modelID == companionManager.openCodeModelID
            && option.providerID == companionManager.openCodeProviderID
        return Button(action: { companionManager.selectOpenCodeModel(option) }) {
            HStack {
                Text(option.shortLabel)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                if OpenCodeTrainingPolicy.dataUse(
                    providerID: option.providerID,
                    modelID: option.modelID,
                    modelName: option.modelName
                ) != .notFlagged {
                    Text("Trains")
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.warningText)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.accentText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(isSelected ? DS.Colors.surface3 : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var refreshOpenCodeButton: some View {
        Button(action: {
            Task { await companionManager.refreshOpenCodeServerStatus() }
        }) {
            Group {
                if companionManager.isOpenCodeRefreshInFlight {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(DS.Glyph.regular)
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(companionManager.isOpenCodeRefreshInFlight)
        .help("Check OpenCode again")
        .accessibilityLabel("Refresh OpenCode status")
    }

    @ViewBuilder
    private var connectionStatusView: some View {
        switch companionManager.isOpenCodeServerReachable {
        case .some(true):
            HStack(spacing: 5) {
                Circle().fill(DS.Colors.success).frame(width: 6, height: 6)
                Text("Connected · v\(companionManager.openCodeServerVersion ?? "?") · \(companionManager.openCodeModels.count) models")
                    .font(DS.Fonts.statusWord)
                    .foregroundColor(DS.Colors.success)
            }
        case .some(false):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle().fill(DS.Colors.warning).frame(width: 6, height: 6)
                    Text("Can't reach OpenCode")
                        .font(DS.Fonts.statusWord)
                        .foregroundColor(DS.Colors.warningText)
                }
                if let errorText = companionManager.openCodeConnectionErrorText {
                    Text(errorText)
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        case .none:
            EmptyView()
        }
    }
}

struct OpenCodeServerSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AISettingsLabel("OpenCode address")
            TextField("http://127.0.0.1:4096", text: $companionManager.openCodeServerURLString)
                .aiSettingsFieldChrome()
            AISettingsFootnote("To use a ChatGPT plan through OpenCode: run `opencode auth login`, pick OpenAI → ChatGPT Plus/Pro, then run `opencode serve`.")
        }
    }
}

// MARK: - Agent jobs sign-in

/// Sign-in state for whichever app runs agent jobs, plus where their
/// project folders live.
struct AgentSignInSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var executorPendingSignOut: HeadlessExecutor?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AISettingsLabel("Sign in")
            AISettingsFootnote("Opens Terminal with the AI app's own sign-in. HeyMate never sees your password.")

            if let executor = companionManager.selectedBrain.executor {
                executorReadinessRow(executor)
            } else {
                Text(companionManager.selectedBrain == .onDevice
                    ? "On this Mac answers chat. Coding jobs still need Claude, Codex, or OpenCode."
                    : "Pick Claude, Codex, or OpenCode to run agent jobs.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
            }

            HStack {
                Text(companionManager.sandboxParentPathForDisplay())
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                NotchLinkButton(title: "Reveal") {
                    companionManager.revealSandboxParentInFinder()
                }
            }
        }
    }

    /// One line per executor: is it there, is it signed in, and on what.
    /// The remedy is shown inline because a status row that only says "no" is
    /// the reason a job used to fail with nothing to act on.
    private func executorReadinessRow(_ executor: HeadlessExecutor) -> some View {
        let readiness = companionManager.readiness(for: executor)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Self.readinessDotColor(readiness.state))
                    .frame(width: 6, height: 6)
                Text(executor.displayName)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(readiness.detail)
                    .font(DS.Fonts.statusWord)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 6)

                // A red dot with no button next to it is a complaint. Signing
                // in is the one thing the user can actually do about it.
                if readiness.state != .notInstalled,
                   HeadlessExecutorSignIn.command(for: executor) != nil {
                    HStack(spacing: 10) {
                        NotchLinkButton(title: readiness.state == .ready ? "Switch account" : "Sign in") {
                            companionManager.beginExecutorSignIn(executor)
                        }
                        .help(HeadlessExecutorSignIn.signInDescription(for: executor))

                        if canSignOut(executor, state: readiness.state) {
                            NotchLinkButton(title: "Sign out", color: DS.Colors.destructiveText) {
                                executorPendingSignOut = executor
                            }
                                .help(HeadlessExecutorSignIn.signOutDescription(for: executor))
                        }
                    }
                }
            }
            if !readiness.remedy.isEmpty {
                Text(readiness.remedy)
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 11)
            }
        }
        .confirmationDialog(
            "Sign out of \(executorPendingSignOut?.displayName ?? executor.displayName) in Terminal?",
            isPresented: Binding(
                get: { executorPendingSignOut != nil },
                set: { if !$0 { executorPendingSignOut = nil } }
            )
        ) {
            Button("Sign out", role: .destructive) {
                guard let pending = executorPendingSignOut else { return }
                executorPendingSignOut = nil
                startExecutorSignOut(pending)
            }
            Button("Cancel", role: .cancel) { executorPendingSignOut = nil }
        }
    }

    private func canSignOut(_ executor: HeadlessExecutor, state: HeadlessExecutorReadiness.State) -> Bool {
        guard HeadlessExecutorSignIn.logoutCommand(for: executor) != nil else { return false }
        switch state {
        case .ready, .usingAPIKey, .indeterminate:
            return true
        case .notInstalled, .notSignedIn:
            return false
        }
    }

    /// Opens Terminal on the CLI logout, then re-probes readiness the way
    /// sign-in does: spaced checks until the account is gone, or a few minutes pass.
    private func startExecutorSignOut(_ executor: HeadlessExecutor) {
        guard HeadlessExecutorSignIn.beginSignOut(for: executor) else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            for _ in 0..<15 {
                companionManager.refreshHeadlessExecutorReadiness()
                try? await Task.sleep(nanoseconds: 12 * 1_000_000_000)
                let state = companionManager.readiness(for: executor).state
                if state == .notSignedIn || state == .notInstalled { return }
            }
        }
    }

    static func readinessDotColor(_ state: HeadlessExecutorReadiness.State) -> Color {
        switch state {
        case .ready:
            return DS.Colors.success
        case .usingAPIKey:
            return DS.Colors.warning
        case .notInstalled, .notSignedIn:
            return DS.Colors.warning
        case .indeterminate:
            return DS.Colors.textTertiary
        }
    }
}

// MARK: - Listen and speak

extension VoiceListenProvider {
    /// One plain-language line under the Listen picker. "Worker" is the
    /// developer's name for HeyMate's own cloud service; users see that name.
    var settingsHint: String {
        switch self {
        case .apple:
            return "Private, on this Mac. Needs Speech Recognition permission."
        case .assemblyAI:
            return "HeyMate cloud voice. Fast, accurate transcription; needs an internet connection."
        case .openAI:
            #if DEBUG
            return pickerHint
            #else
            return "Cloud transcription from OpenAI."
            #endif
        }
    }

    /// Listen choices worth showing. A Release build hides OpenAI unless it
    /// is configured, because the only way to configure it is a developer
    /// secrets file no customer has. Debug builds keep it visible (locked)
    /// so a developer can see why. The current choice always stays visible.
    static func settingsVisibleCases(selected: VoiceListenProvider) -> [VoiceListenProvider] {
        #if DEBUG
        return allCases
        #else
        return allCases.filter { $0.isSelectable || $0 == selected }
        #endif
    }
}

extension VoiceSpeakProvider {
    var settingsHint: String {
        switch self {
        case .macOS:
            return "This Mac's own voice. Works offline."
        case .elevenLabs:
            return "HeyMate cloud voice. More natural; needs an internet connection."
        }
    }
}

/// Listen and Speak provider pickers. Switching is locked while a turn is in
/// flight so a reply cannot change voice halfway through.
struct VoiceProviderSettingsContent: View {
    @ObservedObject var companionManager: CompanionManager
    /// The notch has no other home for the interaction-sound toggle, so it
    /// rides along here; desktop shows it under General instead.
    var showsInteractionSoundsToggle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            providerPicker(
                label: "Listen",
                selectedValue: companionManager.selectedListenProvider.displayName,
                hint: companionManager.selectedListenProvider.settingsHint,
                content: {
                    ForEach(
                        VoiceListenProvider.settingsVisibleCases(selected: companionManager.selectedListenProvider),
                        id: \.self
                    ) { provider in
                        SettingsSegmentButton(
                            label: provider.displayName,
                            isSelected: companionManager.selectedListenProvider == provider,
                            isEnabled: provider.isSelectable && companionManager.voiceState == .idle,
                            disabledReason: listenProviderDisabledReason(provider),
                            action: { companionManager.setSelectedListenProvider(provider) }
                        )
                    }
                }
            )

            #if DEBUG
            if !VoiceListenProvider.openAI.isSelectable {
                Text("OpenAI locked — set OPENAI_API_KEY in your local HeyMate secrets file to enable it.")
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #endif

            providerPicker(
                label: "Speak",
                selectedValue: companionManager.selectedSpeakProvider.displayName,
                hint: companionManager.selectedSpeakProvider.settingsHint,
                content: {
                    ForEach(VoiceSpeakProvider.allCases, id: \.self) { provider in
                        SettingsSegmentButton(
                            label: provider.displayName,
                            isSelected: companionManager.selectedSpeakProvider == provider,
                            isEnabled: companionManager.voiceState == .idle,
                            disabledReason: audioProviderBusyMessage,
                            action: { companionManager.setSelectedSpeakProvider(provider) }
                        )
                    }
                }
            )

            if let audioProviderBusyMessage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(DS.Fonts.micro)
                    Text(audioProviderBusyMessage)
                        .font(DS.Fonts.micro)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(DS.Colors.warningText)
                .accessibilityElement(children: .combine)
            }

            if showsInteractionSoundsToggle {
                HStack {
                    AISettingsLabel("Clicks")
                    Spacer()
                    Toggle("", isOn: $companionManager.isUISoundEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                AISettingsFootnote("Small sounds when listening starts and a reply is ready.")
            }
        }
    }

    private func providerPicker<Content: View>(
        label: String,
        selectedValue: String,
        hint: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AISettingsLabel(label)
            HStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(DS.Colors.surface2.opacity(0.72))
            )
            Text("Selected: \(selectedValue)")
                .font(DS.Fonts.micro)
                .foregroundColor(DS.Colors.accentText)
            Text(hint)
                .font(DS.Fonts.micro)
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var audioProviderBusyMessage: String? {
        switch companionManager.voiceState {
        case .idle:
            return nil
        case .listening:
            return "Finish listening before switching voice options."
        case .processing:
            return "Wait for the current request to finish before switching voice options."
        case .responding:
            return "Let the current reply finish before switching voice options."
        }
    }

    private func listenProviderDisabledReason(_ provider: VoiceListenProvider) -> String? {
        if !provider.isSelectable {
            #if DEBUG
            return "OpenAI unavailable. Set OPENAI_API_KEY in your local HeyMate secrets file."
            #else
            return "OpenAI transcription is not available in this version of HeyMate."
            #endif
        }
        return audioProviderBusyMessage
    }
}

/// Which ElevenLabs voice the HeyMate cloud voice uses. Only matters once
/// Speak is switched to ElevenLabs.
struct ElevenLabsVoiceSettingsContent: View {
    /// What the picker is showing: "" for HeyMate's own default, a premade
    /// voice id, or the custom tag when the stored id is one the user typed
    /// (a cloned or library voice).
    @State private var elevenLabsVoiceSelection = SpeechVoiceCatalog
        .elevenLabsPickerSelection(forStoredVoiceID: SpeechVoiceCatalog.selectedElevenLabsVoiceID)
    @State private var elevenLabsCustomVoiceID = SpeechVoiceCatalog.selectedElevenLabsVoiceID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("ElevenLabs voice")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("Used when Speak is set to ElevenLabs. Every voice listed works on a free ElevenLabs plan.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Picker("", selection: $elevenLabsVoiceSelection) {
                    Text("HeyMate default").tag("")
                    ForEach(SpeechVoiceCatalog.elevenLabsPremadeVoices) { voice in
                        Text(voice.displayName).tag(voice.id)
                    }
                    Text("Custom voice ID…")
                        .tag(SpeechVoiceCatalog.customElevenLabsVoiceSelectionTag)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
            }

            // Cloned and library voices have per-account ids, so the
            // typed field stays for anyone on a paid plan.
            if elevenLabsVoiceSelection == SpeechVoiceCatalog.customElevenLabsVoiceSelectionTag {
                TextField("Voice ID from your ElevenLabs dashboard", text: $elevenLabsCustomVoiceID)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                if !elevenLabsCustomVoiceID.isEmpty,
                   !SpeechVoiceCatalog.isValidElevenLabsVoiceID(elevenLabsCustomVoiceID) {
                    Text("Voice IDs are letters and numbers only. This one will be ignored.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.warningText)
                } else {
                    Text("Library and cloned voices need a paid ElevenLabs plan. On a free plan HeyMate stays silent instead.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: elevenLabsVoiceSelection) { _, newSelection in
            // The custom tag is a picker state, not a voice — while it is
            // selected the typed field is the source of truth.
            if newSelection == SpeechVoiceCatalog.customElevenLabsVoiceSelectionTag {
                SpeechVoiceCatalog.selectedElevenLabsVoiceID = elevenLabsCustomVoiceID
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                SpeechVoiceCatalog.selectedElevenLabsVoiceID = newSelection
            }
        }
        .onChange(of: elevenLabsCustomVoiceID) { _, newValue in
            guard elevenLabsVoiceSelection == SpeechVoiceCatalog.customElevenLabsVoiceSelectionTag else { return }
            SpeechVoiceCatalog.selectedElevenLabsVoiceID = newValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

// MARK: - Google

/// Whether the local Google command-line tool is installed and signed in.
/// Refreshes itself, because it is the only status here no other control
/// depends on.
struct GoogleCLISettingsContent: View {
    @State private var gogCLIStatus = HeyMateGogCLIStatus.unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AISettingsLabel(gogCLIStatus.readinessTitle)
            Text(gogCLIStatus.readinessDetail)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            AISettingsFootnote("Agents reach Gmail, Calendar, and Drive through gogcli, a free tool you install on this Mac (`brew install gogcli`). HeyMate never handles your Google sign-in.")
        }
        .task {
            gogCLIStatus = await HeyMateGogCLIStatusResolver.refresh()
        }
    }
}

// MARK: - Segment button

private struct SettingsSegmentButton: View {
    let label: String
    let isSelected: Bool
    let isEnabled: Bool
    let disabledReason: String?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(isSelected ? "✓ \(label)" : label)
                    .font(DS.Fonts.body)
                    .foregroundColor(foregroundColor)
                    .lineLimit(1)

                if !isEnabled {
                    Text("Locked")
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .stroke(borderColor, lineWidth: isSelected ? 1.25 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.58)
        .pointerCursor()
        .onHover { hovering in
            isHovered = isEnabled && hovering
        }
        .help(disabledReason ?? (isSelected ? "Selected: \(label)" : "Select \(label)"))
        .accessibilityLabel(label)
        .accessibilityValue(isSelected ? "Selected" : (isEnabled ? "Not selected" : "Unavailable"))
        .accessibilityHint(disabledReason ?? "Select provider")
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.16), value: isSelected)
    }

    private var foregroundColor: Color {
        if isSelected { return DS.Colors.textPrimary }
        if isEnabled { return isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary }
        return DS.Colors.textTertiary
    }

    private var backgroundColor: Color {
        if isSelected { return DS.Colors.accent.opacity(0.34) }
        if isHovered { return DS.Colors.surface3 }
        return Color.clear
    }

    private var borderColor: Color {
        if isSelected { return DS.Colors.accentText }
        if isHovered { return DS.Colors.borderStrong }
        return Color.clear
    }
}
