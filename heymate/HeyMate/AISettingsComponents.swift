//
//  AISettingsComponents.swift
//  HeyMate
//
//  The engine, agent, and voice controls that need their own draft state —
//  OpenCode's model search, the custom API fields, a pending sign-out, the
//  on-device voice download — built from the settings kit so they drop into
//  any Settings section as rows.
//
//  The notch used to have its own one-column copy of these controls
//  (AISettingsView). Nothing showed it any more, so it is gone; Settings is
//  the one place to change them. `OnDeviceVoiceDownloadRow` is still shared
//  with onboarding.
//

import AppKit
import SwiftUI

// MARK: - Refresh

enum AISettingsRefresh {
    /// Everything the AI and Agents pages read from a CLI or a probe. Run
    /// once when Settings appears; the Google row refreshes its own status.
    static func refreshCatalogsAndReadiness(_ companionManager: CompanionManager) async {
        await companionManager.refreshClaudeModelCatalog()
        await companionManager.refreshCodexModelCatalog()
        await companionManager.refreshOpenCodeServerStatus()
        companionManager.refreshHeadlessCLIStatus()
    }
}

// MARK: - Engine icons

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

// MARK: - Custom API

/// The Anthropic-compatible server HeyMate talks to when "Custom API" is
/// the engine. The address and model save as you type; the key is never
/// shown again after saving.
struct CustomAPISettingsRows: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var baseURL = CustomAPIConfiguration.baseURL
    @State private var model = CustomAPIConfiguration.model
    @State private var hasAPIKey = CustomAPIConfiguration.hasAPIKey

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if companionManager.selectedBrain.talkNeedsSeparateVisionEndpoint {
                SettingsInlineHelp("\(companionManager.selectedBrain.displayName) runs your agent jobs. Answering “what's on my screen” needs a fast vision server, which \(companionManager.selectedBrain.displayName) can't be — set one here or screen questions stay unanswered.")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsRowInsets()
            }

            SettingsRow("Server address") {
                TextField("https://…", text: $baseURL)
                    .settingsFieldChrome(isMonospaced: true)
                    .frame(width: DS.SettingsLayout.fieldMinWidth)
                    .accessibilityLabel("Custom API server address")
            }
            SettingsDivider()
            SettingsRow("Model name") {
                TextField("Model name", text: $model)
                    .settingsFieldChrome(isMonospaced: true)
                    .frame(width: DS.SettingsLayout.fieldMinWidth)
                    .accessibilityLabel("Custom API model name")
            }
            SettingsDivider()
            SettingsSecretKeyRow(
                title: "API key",
                subtitle: "Optional. Leave it empty if the server holds its own key.",
                placeholder: "API key",
                isStored: hasAPIKey,
                removalTitle: "Remove the custom API key?",
                removalMessage: "HeyMate deletes the key from this Mac. Requests go to the server without one.",
                onSave: { key in
                    CustomAPIConfiguration.setAPIKey(key)
                    hasAPIKey = CustomAPIConfiguration.hasAPIKey
                },
                onRemove: {
                    CustomAPIConfiguration.setAPIKey("")
                    hasAPIKey = CustomAPIConfiguration.hasAPIKey
                }
            )
            SettingsInlineHelp("Works with any Anthropic-compatible server; you pay that provider per use. The key is kept in a private file only your Mac account can read, never in preferences.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsRowContentInsets()
        }
        .onChange(of: baseURL) { _, newValue in CustomAPIConfiguration.baseURL = newValue }
        .onChange(of: model) { _, newValue in CustomAPIConfiguration.model = newValue }
    }
}

// MARK: - OpenCode

/// OpenCode's address and connection, then its models: searchable and
/// grouped by provider, or an explanation of why the list is empty.
struct OpenCodeSettingsRows: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow("OpenCode address", subtitle: connectionSubtitle) {
                HStack(spacing: DS.Spacing.xs) {
                    SettingsRefreshButton(
                        isRefreshing: companionManager.isOpenCodeRefreshInFlight,
                        accessibilityTitle: "Check OpenCode again"
                    ) {
                        Task { await companionManager.refreshOpenCodeServerStatus() }
                    }
                    TextField("http://127.0.0.1:4096", text: $companionManager.openCodeServerURLString)
                        .settingsFieldChrome(isMonospaced: true)
                        .frame(width: DS.SettingsLayout.pickerWidth)
                        .accessibilityLabel("OpenCode address")
                }
            }

            connectionStatus
                .settingsRowContentInsets()

            SettingsDivider()

            if companionManager.openCodeModels.isEmpty {
                SettingsEmptyRow(
                    text: companionManager.isOpenCodeServerReachable == false
                        ? "OpenCode isn't running on this Mac. Start it with `opencode serve` in Terminal, then refresh."
                        : "No models yet. Start OpenCode with `opencode serve` in Terminal.",
                    systemImage: "terminal"
                )
            } else {
                modelList
            }

            SettingsInlineHelp("To use a ChatGPT plan through OpenCode: run `opencode auth login`, pick OpenAI › ChatGPT Plus/Pro, then run `opencode serve`.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsRowInsets()
        }
    }

    private var connectionSubtitle: String? {
        guard companionManager.isOpenCodeServerReachable == true else { return nil }
        return "Version \(companionManager.openCodeServerVersion ?? "unknown") · \(companionManager.openCodeModels.count) models"
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch companionManager.isOpenCodeServerReachable {
        case .some(true):
            SettingsStatusBadge(text: "Connected", tone: .positive)
        case .some(false):
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                SettingsStatusBadge(text: "Can't reach OpenCode", tone: .attention)
                if let errorText = companionManager.openCodeConnectionErrorText {
                    Text(errorText)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        case .none:
            SettingsStatusBadge(text: "Checking…", tone: .progress)
        }
    }

    private var modelList: some View {
        let groups = companionManager.openCodeProviderGroups(matching: searchText)
        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(DS.Glyph.small)
                    .foregroundColor(DS.Colors.textTertiary)
                    .accessibilityHidden(true)
                TextField("Search \(companionManager.openCodeModels.count) models", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .accessibilityLabel("Search OpenCode models")
            }
            .padding(.horizontal, 10)
            .frame(minHeight: DS.ControlSize.regular)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )

            if groups.isEmpty {
                Text("No models match “\(searchText)”.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.vertical, DS.Spacing.sm)
            }

            ForEach(groups, id: \.providerID) { group in
                DSSectionLabel(title: group.providerName, accessory: "\(group.models.count)")
                    .padding(.top, DS.Spacing.sm)
                    .accessibilityAddTraits(.isHeader)
                ForEach(group.models) { option in
                    modelRow(option)
                }
            }
        }
        .padding(.horizontal, DS.SettingsLayout.rowHorizontalPadding)
        .padding(.vertical, DS.SettingsLayout.rowVerticalPadding)
    }

    private func modelRow(_ option: OpenCodeModelOption) -> some View {
        let isSelected = option.modelID == companionManager.openCodeModelID
            && option.providerID == companionManager.openCodeProviderID
        let trainsOnData = OpenCodeTrainingPolicy.dataUse(
            providerID: option.providerID,
            modelID: option.modelID,
            modelName: option.modelName
        ) != .notFlagged

        return Button {
            companionManager.selectOpenCodeModel(option)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Text(option.shortLabel)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                if trainsOnData {
                    SettingsStatusBadge(text: "May train on your data", tone: .attention)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(DS.Glyph.small)
                        .foregroundColor(DS.Colors.textPrimary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, DS.Spacing.sm)
            .frame(minHeight: DS.ControlSize.regular)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(isSelected ? DS.Colors.selectionFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(option.shortLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Agent jobs sign-in

/// Which app runs agent jobs, whether it is signed in, the one action that
/// fixes it, and where job folders live.
struct AgentSignInRows: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var executorPendingSignOut: HeadlessExecutor?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let executor = companionManager.selectedBrain.executor {
                executorRow(executor)
            } else {
                SettingsRow(
                    SettingsItem.agentSignIn.title,
                    subtitle: companionManager.selectedBrain == .onDevice
                        ? "On this Mac answers chat. Coding jobs still need Claude, ChatGPT, or OpenCode — pick one under AI & Accounts."
                        : "Pick Claude, ChatGPT, or OpenCode under AI & Accounts to run agent jobs.",
                    systemImage: "person.badge.key",
                    item: .agentSignIn
                )
            }

            SettingsDivider()

            SettingsRow(
                SettingsItem.projectFolder.title,
                subtitle: companionManager.sandboxParentPathForDisplay(),
                systemImage: "folder",
                item: .projectFolder
            ) {
                Button("Show in Finder") {
                    companionManager.revealSandboxParentInFinder()
                }
                .dsCapsuleButtonStyle(.quiet)
            }
        }
        .confirmationDialog(
            "Sign out of \(executorPendingSignOut?.displayName ?? "this account")?",
            isPresented: Binding(
                get: { executorPendingSignOut != nil },
                set: { if !$0 { executorPendingSignOut = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Sign out", role: .destructive) {
                guard let pending = executorPendingSignOut else { return }
                executorPendingSignOut = nil
                startExecutorSignOut(pending)
            }
            Button("Cancel", role: .cancel) { executorPendingSignOut = nil }
        } message: {
            Text("Terminal opens and signs this Mac out of the account. Agent jobs stop working until you sign in again.")
        }
    }

    /// The remedy stays inline because a status that only says "no" is the
    /// reason a job used to fail with nothing to act on.
    private func executorRow(_ executor: HeadlessExecutor) -> some View {
        let readiness = companionManager.readiness(for: executor)
        let canSignIn = readiness.state != .notInstalled
            && HeadlessExecutorSignIn.command(for: executor) != nil

        return VStack(alignment: .leading, spacing: 0) {
            SettingsRow(
                executor.displayName,
                subtitle: readiness.detail,
                systemImage: "person.badge.key",
                item: .agentSignIn
            ) {
                HStack(spacing: DS.Spacing.sm) {
                    SettingsStatusBadge(
                        text: Self.statusWord(readiness.state),
                        tone: Self.statusTone(readiness.state)
                    )
                    if canSignIn {
                        Button(readiness.state == .ready ? "Switch account" : "Sign in") {
                            companionManager.beginExecutorSignIn(executor)
                        }
                        .dsCapsuleButtonStyle(readiness.state == .ready ? .quiet : .secondary)
                        .help(HeadlessExecutorSignIn.signInDescription(for: executor))
                    }
                    if canSignIn, canSignOut(executor, state: readiness.state) {
                        Button("Sign out") { executorPendingSignOut = executor }
                            .dsCapsuleButtonStyle(.destructive)
                            .help(HeadlessExecutorSignIn.signOutDescription(for: executor))
                    }
                }
            }
            .brandMark(AgentBrain.allCases.first { $0.executor == executor })
            if !readiness.remedy.isEmpty, readiness.state != .ready {
                SettingsInlineHelp(readiness.remedy, tone: .attention)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsRowContentInsets()
            }
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

    static func statusWord(_ state: HeadlessExecutorReadiness.State) -> String {
        switch state {
        case .ready: return "Signed in"
        case .usingAPIKey: return "API key"
        case .notInstalled: return "Not installed"
        case .notSignedIn: return "Signed out"
        case .indeterminate: return "Unknown"
        }
    }

    static func statusTone(_ state: HeadlessExecutorReadiness.State) -> SettingsStatusTone {
        switch state {
        case .ready: return .positive
        case .usingAPIKey, .notInstalled, .notSignedIn: return .attention
        case .indeterminate: return .neutral
        }
    }
}

// MARK: - Listen and speak copy

extension VoiceListenProvider {
    /// One plain-language line under the Listen with row.
    var settingsHint: String {
        switch self {
        case .elevenLabs:
            return "Your ElevenLabs account. The most accurate; needs an internet connection."
        case .onDevice:
            return "Parakeet, running on this Mac. Private, free, and works offline."
        case .apple:
            return "Apple's built-in dictation. Needs Speech Recognition permission."
        }
    }

    var lockedReason: String {
        switch self {
        case .elevenLabs:
            return "Add your ElevenLabs API key under Voices to use ElevenLabs."
        case .onDevice:
            return ParakeetEngine.unsupportedReason ?? "Download the on-device voice under Voices to use it."
        case .apple:
            return ""
        }
    }
}

extension VoiceSpeakProvider {
    var settingsHint: String {
        switch self {
        case .elevenLabs:
            return "Your ElevenLabs account. The most natural voice; needs an internet connection."
        case .onDevice:
            return "Kokoro, running on this Mac. Natural, private, and works offline."
        case .macOS:
            return "The Mac voice chosen under Voices. Always works."
        }
    }

    var lockedReason: String {
        switch self {
        case .elevenLabs:
            return "Add your ElevenLabs API key under Voices to use ElevenLabs."
        case .onDevice:
            return KokoroEngine.unsupportedReason ?? "Download the on-device voice under Voices to use it."
        case .macOS:
            return ""
        }
    }
}

// MARK: - On-device voice

/// One row that explains the on-device voice and downloads it. Shared by
/// onboarding and Settings, so the copy and states stay identical. Draws no
/// card or padding of its own; each host adds its own insets.
struct OnDeviceVoiceDownloadRow: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var store = OnDeviceVoiceModelStore.shared
    /// Onboarding shows a shorter, friendlier version.
    var isCompact = false

    @State private var isConfirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(alignment: .center, spacing: DS.SettingsLayout.rowAccessorySpacing) {
                SettingsRowLabel(
                    title: title,
                    subtitle: subtitle,
                    systemImage: store.isEverythingInstalled ? "checkmark.circle.fill" : "cpu"
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                actionButton
            }

            if store.isDownloading {
                Group {
                    if let progress = store.combinedProgress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                .tint(DS.Colors.textPrimary)
                .accessibilityLabel("Downloading the on-device voice")
            }

            if let failure = store.lastFailureMessage, !store.isDownloading {
                SettingsInlineHelp(failure, tone: .attention)
            }
        }
        .confirmationDialog(
            "Remove the on-device voice?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { removeModels() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("HeyMate switches back to the Mac voice. You can download it again any time.")
        }
    }

    private var title: String {
        if !store.isSupportedOnThisMac { return "On-device voice" }
        if store.isEverythingInstalled { return "On-device voice is ready" }
        if store.isDownloading { return "Downloading on-device voice…" }
        return isCompact ? "Want a private, natural voice?" : "On-device voice"
    }

    private var subtitle: String {
        if !store.isSupportedOnThisMac {
            if case .unsupported(let reason) = store.listenState { return reason }
            return "Not available on this Mac."
        }
        if store.isEverythingInstalled {
            return "Listening and speaking run on this Mac. Nothing leaves it."
        }
        if store.isDownloading {
            return "One-time download. You can keep using HeyMate meanwhile."
        }
        if case .unsupported(let reason) = store.speakState {
            return "Listens on this Mac, offline. \(reason) Download once, \(OnDeviceVoiceModelStore.approximateDownloadSizeDescription)."
        }
        return "Listens and talks on this Mac, offline and free. One-time download, \(OnDeviceVoiceModelStore.approximateDownloadSizeDescription)."
    }

    @ViewBuilder
    private var actionButton: some View {
        if !store.isSupportedOnThisMac || store.isDownloading {
            EmptyView()
        } else if store.isEverythingInstalled {
            if !isCompact {
                Button("Remove") { isConfirmingRemoval = true }
                    .dsCapsuleButtonStyle(.destructive, height: isCompact ? DS.ControlSize.small : DS.ControlSize.regular)
            }
        } else {
            Button(store.lastFailureMessage == nil ? "Download" : "Try again") {
                Task { await store.downloadAll() }
            }
            .dsCapsuleButtonStyle(.primary, height: isCompact ? DS.ControlSize.small : DS.ControlSize.regular)
        }
    }

    private func removeModels() {
        if companionManager.selectedListenProvider == .onDevice {
            companionManager.setSelectedListenProvider(.apple)
        }
        if companionManager.selectedSpeakProvider == .onDevice {
            companionManager.setSelectedSpeakProvider(.macOS)
        }
        Task { await store.removeAll() }
    }
}

// MARK: - Google

/// Whether the local Google command-line tool is installed and signed in.
/// Refreshes itself, because no other control depends on it.
struct GoogleCLISettingsRow: View {
    @State private var gogCLIStatus = GoogleWorkspaceCLIStatus.unknown
    @State private var hasChecked = false
    @State private var isRefreshing = false

    private var isConnected: Bool {
        gogCLIStatus.isReadyForUserAccount
    }

    var body: some View {
        SettingsRow(
            SettingsItem.google.title,
            subtitle: hasChecked ? gogCLIStatus.readinessDetail : "Checking for gogcli on this Mac…",
            systemImage: "envelope",
            item: .google
        ) {
            HStack(spacing: DS.Spacing.sm) {
                if hasChecked {
                    SettingsStatusBadge(
                        text: gogCLIStatus.readinessTitle,
                        tone: isConnected ? .positive : .attention
                    )
                }
                SettingsRefreshButton(
                    isRefreshing: isRefreshing,
                    accessibilityTitle: "Check Google again",
                    action: { Task { await refresh() } }
                )
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        isRefreshing = true
        gogCLIStatus = await GoogleWorkspaceCLIInspector.refresh()
        hasChecked = true
        isRefreshing = false
    }
}
