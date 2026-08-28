//
//  AISettingsView.swift
//  leanring-buddy
//
//  Shared Brain/provider settings. The notch presentation owns its scroll
//  view and Look controls; the desktop presentation joins the parent page
//  without duplicating controls or nesting another scroller.
//

import SwiftUI

struct AISettingsView: View {
    enum Presentation {
        case notch
        case desktop
    }

    @ObservedObject var companionManager: CompanionManager
    var presentation: Presentation = .notch
    @State private var openCodeSearchText = ""
    @State private var gogCLIStatus = HeyMateGogCLIStatus.unknown
    @State private var customAPIBaseURL = CustomAPIConfiguration.baseURL
    @State private var customAPIModel = CustomAPIConfiguration.model
    /// Never pre-filled from the Keychain — a saved key is reported, not shown.
    @State private var customAPIKeyDraft = ""

    var body: some View {
        Group {
            if presentation == .notch {
                ScrollView(.vertical, showsIndicators: true) {
                    settingsSections
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                }
                .scrollIndicators(.visible)
            } else {
                settingsSections
            }
        }
        .task {
            await companionManager.refreshCodexModelCatalog()
            await companionManager.refreshOpenCodeServerStatus()
            companionManager.refreshHeadlessCLIStatus()
            gogCLIStatus = await HeyMateGogCLIStatusResolver.refresh()
        }
    }

    @ViewBuilder
    private var settingsSections: some View {
        VStack(alignment: .leading, spacing: 18) {
            if presentation == .notch {
                lookSection
            }
            brainSection
            audioSection
            googleSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Look

    private var lookSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotchSettingsSectionHeader(title: "Look")
            settingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    settingLabel("Color")
                    ThemeColorPicker(companionManager: companionManager)
                    HStack {
                        settingLabel("Notch outline")
                        Spacer()
                        Toggle("", isOn: $companionManager.isNotchOutlineEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                            .tint(DS.Colors.accent)
                    }
                    settingFootnote("A small chasing rim on the camera housing. Same color as the cursor.")
                }
            }
        }
    }

    // MARK: - Brain

    private var brainSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotchSettingsSectionHeader(title: "Brain")

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4),
                spacing: 7
            ) {
                ForEach(AgentBrain.allCases, id: \.self) { brain in
                    brainChoiceButton(brain)
                }
            }

            Text(companionManager.selectedBrain.subtitle)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let reason = companionManager.selectedBrain.unavailableReason {
                Text(reason)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            brainDetail

            agentsSettingsCard
        }
    }

    private func brainChoiceButton(_ brain: AgentBrain) -> some View {
        let isSelected = companionManager.selectedBrain == brain
        return Button {
            companionManager.setSelectedBrain(brain)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: brainSymbolName(brain))
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

    private func brainSymbolName(_ brain: AgentBrain) -> String {
        switch brain {
        case .codex: return "sparkles"
        case .claudeCode: return "brain.head.profile"
        case .openCode: return "terminal"
        case .customAPI: return "point.3.connected.trianglepath.dotted"
        }
    }

    @ViewBuilder
    private var brainDetail: some View {
        switch companionManager.selectedBrain {
        case .openCode:
            openCodeBrainDetail
        case .claudeCode:
            claudeModelCard
        case .codex:
            codexModelCard
        case .customAPI:
            customAPICard
        }
    }

    private var claudeModelCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 10) {
                settingLabel("Model")
                HStack(spacing: 0) {
                    ForEach(ClaudeModelChoice.allCases, id: \.self) { choice in
                        settingsSegmentButton(
                            label: choice.displayName,
                            isSelected: companionManager.selectedClaudeModel == choice,
                            action: { companionManager.setSelectedClaudeModel(choice) }
                        )
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(DS.Colors.surface2.opacity(0.72))
                )
                settingFootnote("Talk and agent jobs both use this, through your Claude sign-in. A screen question can take several seconds — that is the CLI, not a missing model.")
            }
        }
    }

    private var codexModelCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    settingLabel("Model")
                    Spacer()
                    if companionManager.isCodexModelRefreshInFlight {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button {
                            Task { await companionManager.refreshCodexModelCatalog() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(DS.Fonts.micro)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(DS.Colors.textSecondary)
                        .pointerCursor()
                    }
                }

                if companionManager.codexModels.isEmpty {
                    Text(companionManager.isCodexModelRefreshInFlight ? "Loading Codex models…" : "No Codex models available")
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
                        codexPickerLabel(
                            companionManager.selectedCodexModel?.displayName ?? "Choose model"
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .pointerCursor()
                }

                if let selectedModel = companionManager.selectedCodexModel,
                   !selectedModel.supportedReasoningEfforts.isEmpty {
                    settingLabel("Effort")
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
                        codexPickerLabel(
                            companionManager.selectedCodexReasoningEffort.capitalized
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .pointerCursor()
                }

                if let errorText = companionManager.codexModelCatalogErrorText {
                    Text(errorText)
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                settingFootnote("Loaded live from your signed-in Codex CLI. Text-only Talk uses GPT-5.3-Codex-Spark by default; screen questions and agent jobs use selected model and effort.")
            }
        }
    }

    private func codexPickerLabel(_ title: String) -> some View {
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

    /// The endpoint that answers screen questions.
    ///
    /// Shown for the CLI brains too, and labelled as such: a CLI cannot answer
    /// a screen question at conversational speed — a measured `claude -p` turn
    /// with a screenshot took thirteen seconds — so Talk needs its own fast
    /// endpoint no matter which CLI is doing the work.
    private var customAPICard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 10) {
                settingLabel(
                    companionManager.selectedBrain.talkNeedsSeparateVisionEndpoint
                        ? "Screen questions"
                        : "Endpoint"
                )

                if companionManager.selectedBrain.talkNeedsSeparateVisionEndpoint {
                    settingFootnote("\(companionManager.selectedBrain.displayName) runs your agent jobs. Answering “what’s on my screen” needs a fast vision endpoint, which a CLI cannot be — set one here or screen questions stay unanswered.")
                }

                settingsTextField("Endpoint URL", text: $customAPIBaseURL) {
                    CustomAPIConfiguration.baseURL = customAPIBaseURL
                }
                settingsTextField("Model", text: $customAPIModel) {
                    CustomAPIConfiguration.model = customAPIModel
                }

                HStack(spacing: 8) {
                    SecureField(
                        CustomAPIConfiguration.hasAPIKey ? "Key saved — type to replace" : "API key",
                        text: $customAPIKeyDraft
                    )
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

                    Button(customAPIKeyDraft.isEmpty ? "Clear" : "Save") {
                        CustomAPIConfiguration.setAPIKey(customAPIKeyDraft)
                        customAPIKeyDraft = ""
                    }
                    .font(DS.Fonts.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Colors.accentText)
                    .pointerCursor()
                }

                settingFootnote("Stored in your Keychain, never in preferences. Leave the key empty if the endpoint is a proxy that holds it.")
            }
        }
    }

    private func settingsTextField(
        _ placeholder: String,
        text: Binding<String>,
        onCommit: @escaping () -> Void
    ) -> some View {
        TextField(placeholder, text: text)
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
            .onSubmit(onCommit)
            .onChange(of: text.wrappedValue) { _, _ in onCommit() }
    }

    private var openCodeBrainDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            if companionManager.openCodeModels.isEmpty {
                settingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(companionManager.isOpenCodeServerReachable == false
                                 ? "OpenCode server is offline"
                                 : "No models yet — start `opencode serve`")
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.textTertiary)
                            Spacer()
                            refreshOpenCodeButton
                        }
                        connectionStatusView
                    }
                }
            } else {
                let groups = companionManager.openCodeProviderGroups(matching: openCodeSearchText)
                settingsCard {
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

            settingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    settingLabel("OpenCode server")
                    notchTextField(
                        placeholder: "http://127.0.0.1:4096",
                        text: $companionManager.openCodeServerURLString
                    )
                    settingFootnote("Codex: `opencode auth login` → OpenAI → ChatGPT Plus/Pro, then `opencode serve`.")
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
            if companionManager.isOpenCodeRefreshInFlight {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(companionManager.isOpenCodeRefreshInFlight)
    }

    private var agentsSettingsCard: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 10) {
                settingLabel("Sign in")
                settingFootnote("Opens Terminal running the CLI's own login. HeyMate never sees the password.")

                if let executor = companionManager.selectedBrain.executor {
                    executorReadinessRow(executor)
                } else {
                    Text("Pick Claude, Codex, or OpenCode to run agent jobs.")
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
                    Button("Reveal") {
                        companionManager.revealSandboxParentInFinder()
                    }
                    .font(DS.Fonts.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Colors.accentText)
                    .pointerCursor()
                }
            }
        }
    }

    /// One line per executor: is the CLI there, is it signed in, and on what.
    /// The remedy is shown inline because a status row that only says "no" is
    /// the reason a job used to fail with nothing to act on.
    private func executorReadinessRow(_ executor: HeadlessExecutor) -> some View {
        let readiness = companionManager.readiness(for: executor)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle()
                    .fill(readinessDotColor(readiness.state))
                    .frame(width: 6, height: 6)
                Text(executor.executableName)
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
                    Button(readiness.state == .ready ? "Switch account" : "Sign in") {
                        companionManager.beginExecutorSignIn(executor)
                    }
                    .font(DS.Fonts.micro)
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Colors.accentText)
                    .pointerCursor()
                    .help(HeadlessExecutorSignIn.signInDescription(for: executor))
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
    }

    private func readinessDotColor(_ state: HeadlessExecutorReadiness.State) -> Color {
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

    // MARK: - Audio

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotchSettingsSectionHeader(title: "Audio")

            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    audioPicker(
                        label: "Listen",
                        selectedValue: companionManager.selectedListenProvider.displayName,
                        hint: companionManager.selectedListenProvider.pickerHint,
                        content: {
                            ForEach(VoiceListenProvider.allCases, id: \.self) { provider in
                                settingsSegmentButton(
                                    label: provider.displayName,
                                    isSelected: companionManager.selectedListenProvider == provider,
                                    isEnabled: provider.isSelectable && companionManager.voiceState == .idle,
                                    disabledReason: listenProviderDisabledReason(provider),
                                    action: { companionManager.setSelectedListenProvider(provider) }
                                )
                            }
                        }
                    )

                    if !VoiceListenProvider.openAI.isSelectable {
                        Text("OpenAI locked — add OpenAIAPIKey to Info.plist to enable it.")
                            .font(DS.Fonts.micro)
                            .foregroundColor(DS.Colors.warningText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    audioPicker(
                        label: "Speak",
                        selectedValue: companionManager.selectedSpeakProvider.displayName,
                        hint: companionManager.selectedSpeakProvider.pickerHint,
                        content: {
                            ForEach(VoiceSpeakProvider.allCases, id: \.self) { provider in
                                settingsSegmentButton(
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

                    if presentation == .notch {
                        HStack {
                            settingLabel("Clicks")
                            Spacer()
                            Toggle("", isOn: $companionManager.isUISoundEnabled)
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .labelsHidden()
                        }
                        settingFootnote("Small sounds when listening starts and a reply is ready.")
                    }
                }
            }
        }
    }

    // MARK: - Google

    private var googleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotchSettingsSectionHeader(title: "Google")
            settingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    settingLabel(gogCLIStatus.readinessTitle)
                    Text(gogCLIStatus.readinessDetail)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    settingFootnote("Local gogcli (`brew install gogcli`). Agents use it when present. HeyMate does not host Google login.")
                }
            }
        }
    }

    private func audioPicker<Content: View>(
        label: String,
        selectedValue: String,
        hint: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            settingLabel(label)
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
            return "Finish listening before switching audio providers."
        case .processing:
            return "Wait for current request to finish before switching audio providers."
        case .responding:
            return "Finish current reply before switching audio providers."
        }
    }

    private func listenProviderDisabledReason(_ provider: VoiceListenProvider) -> String? {
        if !provider.isSelectable {
            return "OpenAI unavailable. Add OpenAIAPIKey to Info.plist."
        }
        return audioProviderBusyMessage
    }

    @ViewBuilder
    private var connectionStatusView: some View {
        switch companionManager.isOpenCodeServerReachable {
        case .some(true):
            HStack(spacing: 5) {
                Circle().fill(DS.Colors.success).frame(width: 6, height: 6)
                Text("connected · v\(companionManager.openCodeServerVersion ?? "?") · \(companionManager.openCodeModels.count) models")
                    .font(DS.Fonts.statusWord)
                    .foregroundColor(DS.Colors.success)
            }
        case .some(false):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Circle().fill(DS.Colors.warning).frame(width: 6, height: 6)
                    Text("not reachable")
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

    // MARK: - Shared Building Blocks

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard()
    }

    private func settingLabel(_ text: String) -> some View {
        Text(text)
            .font(DS.Fonts.body)
            .foregroundColor(DS.Colors.textSecondary)
    }

    private func settingFootnote(_ text: String) -> some View {
        Text(text)
            .font(DS.Fonts.micro)
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func notchTextField(placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
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

    private func settingsSegmentButton(
        label: String,
        isSelected: Bool,
        isEnabled: Bool = true,
        disabledReason: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        SettingsSegmentButton(
            label: label,
            isSelected: isSelected,
            isEnabled: isEnabled,
            disabledReason: disabledReason,
            action: action
        )
    }
}

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

private struct NotchSettingsSectionHeader: View {
    let title: String

    var body: some View {
        DSSectionLabel(title: title)
    }
}
