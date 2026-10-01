//
//  DesktopSettingsView.swift
//  leanring-buddy
//
//  Settings in the window, as five tabs.
//
//  This page used to be one long scroll of a dozen cards with the whole
//  brain/provider column embedded in the middle, so someone looking for the
//  microphone had to read past "CLIs", "Worker", and "Endpoint URL" first.
//  The tabs split it by who it is for:
//
//    • General  — everyday preferences: keys, mic, voice, look, presence.
//    • Accounts — the one AI question: which plan do you already pay for.
//    • Notch    — the notch micro-apps page, unchanged.
//    • Privacy  — the privacy page, plus erasing local data.
//    • Advanced — everything a power user tunes: other engines, effort,
//                 cloud voice providers, keys, computer control.
//
//  Every control from the old single page still exists in exactly one tab
//  and behaves the same; only placement and copy changed. The selected tab
//  is stored under `desktopSettingsSelectedTab`, so other code can deep-link
//  into a tab by writing that key before opening Settings.
//

import AppKit
import Combine
import SwiftUI

/// The Settings tabs. Raw values are persisted and written by deep links —
/// do not rename them.
enum DesktopSettingsTab: String, CaseIterable, Identifiable {
    case general
    case accounts
    case notch
    case privacy
    case advanced

    /// UserDefaults key holding the selected tab's raw value.
    static let storageKey = "desktopSettingsSelectedTab"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .accounts: return "Accounts"
        case .notch: return "Notch"
        case .privacy: return "Privacy"
        case .advanced: return "Advanced"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .accounts: return "person.crop.circle"
        case .notch: return "rectangle.topthird.inset.filled"
        case .privacy: return "hand.raised"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

struct DesktopSettingsView: View {
    @ObservedObject var companionManager: CompanionManager

    /// Observed directly so toggling computer control re-renders the
    /// permission warning underneath it without waiting for some other
    /// change on the manager.
    @ObservedObject private var computerUseCoordinator: ComputerUseCoordinator

    @ObservedObject private var presencePreferences = AppPresencePreferences.shared
    @ObservedObject private var updateController = AppUpdateController.shared

    /// Raw `DesktopSettingsTab` value. AppStorage, not State, so a deep link
    /// that writes the key while this view is on screen switches the tab.
    @AppStorage(DesktopSettingsTab.storageKey) private var selectedTabRawValue = DesktopSettingsTab.general.rawValue

    // Double-tap shortcut state. Held in @State and written back on change
    // rather than bound straight to UserDefaults, because the pickers need a
    // Binding and the preference accessors are plain statics.
    @State private var isTextDoubleTapEnabled = ModifierDoubleTapPreferences.isTextShortcutEnabled
    @State private var textDoubleTapShortcut = ModifierDoubleTapPreferences.textShortcut
    @State private var isHandsFreeDoubleTapEnabled = ModifierDoubleTapPreferences.isHandsFreeShortcutEnabled
    @State private var handsFreeDoubleTapShortcut = ModifierDoubleTapPreferences.handsFreeShortcut

    // Device and voice lists are read once when the view appears and refreshed
    // on demand — enumerating CoreAudio on every SwiftUI body evaluation would
    // be wasteful and makes the picker flicker while it is open.
    @State private var availableAudioInputDevices: [AudioInputDevice] = []
    @State private var selectedAudioInputDeviceUID = AudioInputDeviceCatalog.selectedDeviceUID
    @State private var availableSystemVoices: [SpeechVoiceOption] = []
    @State private var selectedSystemVoiceID = SpeechVoiceCatalog.selectedSystemVoiceID
    @State private var composioAPIKeyDraft = ""
    @State private var composioStatusMessage: String?
    @State private var isSavingComposioAPIKey = false
    @State private var isConfirmingComposioKeyRemoval = false
    @State private var showsBehaviorContractEditor = false
    @State private var persistErrorMessage: String?
    @State private var isConfirmingLocalDataErase = false
    @State private var localDataEraseNote: String?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self.computerUseCoordinator = companionManager.computerUseCoordinator
    }

    private var selectedTab: DesktopSettingsTab {
        DesktopSettingsTab(rawValue: selectedTabRawValue) ?? .general
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(height: 1)

            selectedTabPage
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task {
            // Model catalogs and sign-in status feed both Accounts and
            // Advanced, so they load once for the page, not per tab.
            await AISettingsRefresh.refreshCatalogsAndReadiness(companionManager)
        }
        .onAppear {
            availableAudioInputDevices = AudioInputDeviceCatalog.availableInputDevices()
            availableSystemVoices = SpeechVoiceCatalog.availableSystemVoices()
        }
        .onChange(of: isTextDoubleTapEnabled) { _, newValue in
            ModifierDoubleTapPreferences.isTextShortcutEnabled = newValue
        }
        .onChange(of: textDoubleTapShortcut) { _, newValue in
            ModifierDoubleTapPreferences.textShortcut = newValue
        }
        .onChange(of: isHandsFreeDoubleTapEnabled) { _, newValue in
            ModifierDoubleTapPreferences.isHandsFreeShortcutEnabled = newValue
        }
        .onChange(of: handsFreeDoubleTapShortcut) { _, newValue in
            ModifierDoubleTapPreferences.handsFreeShortcut = newValue
        }
        .onChange(of: selectedAudioInputDeviceUID) { _, newValue in
            AudioInputDeviceCatalog.selectedDeviceUID = newValue
        }
        .onChange(of: selectedSystemVoiceID) { _, newValue in
            SpeechVoiceCatalog.selectedSystemVoiceID = newValue
        }
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(DesktopSettingsTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(3)
        .background(
            Capsule(style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(DS.Colors.surface1.opacity(0.6))
    }

    private func tabButton(_ tab: DesktopSettingsTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTabRawValue = tab.rawValue
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.symbolName)
                    .font(DS.Glyph.small)
                Text(tab.title)
                    .font(DS.Fonts.control)
                    .lineLimit(1)
            }
            .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            .padding(.horizontal, 14)
            .frame(minHeight: DS.ControlSize.regular)
            .background(
                Capsule(style: .continuous)
                    .fill(isSelected ? DS.Colors.surface4 : Color.clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.easeOut(duration: DS.Animation.fast), value: isSelected)
    }

    @ViewBuilder
    private var selectedTabPage: some View {
        switch selectedTab {
        case .general:
            generalTab
        case .accounts:
            DesktopSettingsAccountsTab(
                companionManager: companionManager,
                onShowAdvanced: { selectedTabRawValue = DesktopSettingsTab.advanced.rawValue }
            )
        case .notch:
            DesktopNotchView(activityCenter: companionManager.notchActivityCenter)
        case .privacy:
            DesktopPrivacyView(
                companionManager: companionManager,
                trailingContent: AnyView(localDataCard)
            )
        case .advanced:
            advancedTab
        }
    }

    // MARK: General

    private var generalTab: some View {
        DesktopPage(
            title: "General",
            subtitle: "How you talk to HeyMate, and how it looks and sounds."
        ) {
            pushToTalkCard
            shortcutsCard
            behaviorCard
            microphoneCard
            voiceCard
            appearanceCard
            systemPresenceCard
            updatesAndSupportCard
        }
    }

    // MARK: Advanced

    private var advancedTab: some View {
        DesktopPage(
            title: "Advanced",
            subtitle: "For power users. HeyMate works fine without changing anything here."
        ) {
            otherEnginesCard
            selectedEngineTuningCards

            DesktopCard(title: "Agent jobs") {
                AgentSignInSettingsContent(companionManager: companionManager)
            }

            DesktopCard(title: "AI app updates") {
                CLIUpdateSettingsContent(companionManager: companionManager)
            }

            DesktopCard(
                title: "Listen & speak",
                footnote: "Mac keeps your voice on this computer. HeyMate cloud voice uses an online service for better accuracy and more natural speech."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    VoiceProviderSettingsContent(companionManager: companionManager)
                    Divider().opacity(0.25)
                    ElevenLabsVoiceSettingsContent()
                }
            }

            composioCard

            DesktopCard(title: "Google") {
                GoogleCLISettingsContent()
            }

            computerControlCard
            behaviorContractCard
        }
    }

    /// OpenCode and a custom API: real choices, but not plans most people
    /// already pay for, so they live here instead of under Accounts.
    private var otherEnginesCard: some View {
        DesktopCard(
            title: "Other AI engines",
            footnote: "To go back to Claude, ChatGPT, or On this Mac, pick one under Accounts."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Run HeyMate on OpenCode or on your own API server instead of a subscription.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                BrainChoiceGrid(
                    companionManager: companionManager,
                    brains: [.openCode, .customAPI]
                )

                if [AgentBrain.openCode, .customAPI].contains(companionManager.selectedBrain) {
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
                }
            }
        }
    }

    /// The knobs for whichever engine is selected: effort and voice chat for
    /// Claude or ChatGPT, models and address for OpenCode, the server for a
    /// custom API.
    @ViewBuilder
    private var selectedEngineTuningCards: some View {
        switch companionManager.selectedBrain {
        case .claudeCode:
            DesktopCard(title: "Claude effort") {
                ClaudeModelSettingsContent(companionManager: companionManager, parts: .effortOnly)
            }
            DesktopCard(title: "Voice chat") {
                VoiceChatSettingsContent(companionManager: companionManager)
            }
        case .codex:
            DesktopCard(title: "ChatGPT effort") {
                CodexModelSettingsContent(companionManager: companionManager, parts: .effortOnly)
            }
            DesktopCard(title: "Voice chat") {
                VoiceChatSettingsContent(companionManager: companionManager)
            }
        case .openCode:
            DesktopCard(title: "OpenCode models") {
                OpenCodeModelsSettingsContent(companionManager: companionManager)
            }
            DesktopCard(title: "OpenCode") {
                OpenCodeServerSettingsContent(companionManager: companionManager)
            }
        case .customAPI:
            DesktopCard(title: "Custom API") {
                CustomAPISettingsContent(companionManager: companionManager)
            }
        case .onDevice:
            EmptyView()
        }
    }

    private var composioCard: some View {
        DesktopCard(
            title: "Your own Composio key",
            footnote: "Stored in macOS Keychain. HeyMate never receives tokens for Gmail, Slack, or other connected apps."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Optional. Composio is the service that signs HeyMate in to apps like Gmail and Slack. Paste your own Composio key to use your account; its free tier is enough to get started.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    SecureField(
                        companionManager.composioConnections.isConfigured ? "API key saved" : "Composio API key",
                        text: $composioAPIKeyDraft
                    )
                    .textFieldStyle(.roundedBorder)

                    if companionManager.composioConnections.isConfigured {
                        Button("Remove key") {
                            isConfirmingComposioKeyRemoval = true
                        }
                        .buttonStyle(DSSecondaryButtonStyle())
                        .disabled(isSavingComposioAPIKey)
                    }

                    Button(companionManager.composioConnections.isConfigured ? "Replace key" : "Save key") {
                        saveComposioAPIKey()
                    }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .disabled(
                        isSavingComposioAPIKey
                            || composioAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }

                if isSavingComposioAPIKey {
                    ProgressView("Preparing tools…")
                        .controlSize(.small)
                } else if let composioStatusMessage {
                    Text(composioStatusMessage)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                } else if companionManager.composioConnections.isConfigured {
                    Label("Configured", systemImage: "checkmark.circle.fill")
                        .font(DS.Fonts.statusWord)
                        .foregroundColor(DS.Colors.success)
                }
            }
        }
        .confirmationDialog(
            "Remove the Composio API key?",
            isPresented: $isConfirmingComposioKeyRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove key", role: .destructive) {
                removeComposioAPIKey()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("HeyMate will delete it from the Keychain and sign out of Composio on this Mac.")
        }
    }

    private func saveComposioAPIKey() {
        let trimmedKey = composioAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty,
              let composioConnector = ConnectorCatalog.connector(withID: ComposioSessionStore.connectorID) else { return }

        ConnectorSecretStore.setSecret(trimmedKey, forConnectorID: ComposioSessionStore.connectorID)
        ComposioSessionStore.clear()
        companionManager.connectorStore.setCustomLaunchCommand(nil, for: ComposioSessionStore.connectorID)
        composioAPIKeyDraft = ""
        composioStatusMessage = nil
        isSavingComposioAPIKey = true

        Task {
            await companionManager.connectorRuntime.connect(composioConnector)
            let state = companionManager.connectorStore.connectionState(for: ComposioSessionStore.connectorID)
            switch state {
            case .connected:
                composioStatusMessage = "Ready. Supported apps can now connect from Tools."
                await companionManager.composioToolkitDirectory.loadDefaultPage(
                    apiKey: companionManager.composioConnections.apiKey
                )
            case .needsAttention(let reason):
                composioStatusMessage = reason
            default:
                composioStatusMessage = "Key saved."
            }
            isSavingComposioAPIKey = false
        }
    }

    /// Deletes the Keychain item and tears down the Tool Router session the
    /// same way disconnecting the Composio connector does. The key is never
    /// read back or logged.
    private func removeComposioAPIKey() {
        composioAPIKeyDraft = ""
        composioStatusMessage = nil
        guard let composioConnector = ConnectorCatalog.connector(withID: ComposioSessionStore.connectorID) else {
            ConnectorSecretStore.deleteSecret(forConnectorID: ComposioSessionStore.connectorID)
            ComposioSessionStore.clear()
            companionManager.connectorStore.setCustomLaunchCommand(nil, for: ComposioSessionStore.connectorID)
            composioStatusMessage = "Key removed."
            return
        }
        Task {
            await companionManager.connectorRuntime.disconnect(composioConnector)
            composioStatusMessage = "Key removed."
        }
    }

    private var behaviorCard: some View {
        DesktopCard(title: "Behavior") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Dictation mode")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Smart drafts from the screen into the field you are in. Literal types what you said. Smart stays quiet while HeyMate itself is in front.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    Spacer(minLength: 12)
                    Picker("", selection: $companionManager.dictationUsesSmartMode) {
                        Text("Literal").tag(false)
                        Text("Smart").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }

                Divider().opacity(0.25)

                Toggle(isOn: $companionManager.isSilentModeEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Silent mode")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("For work or in public. Your Talk shortcut (\(companionManager.talkShortcutOption.displayText)) opens a box to type in instead of the mic, Dictate is off, and replies show on screen without being spoken. Toggle from anywhere with /silent.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                Divider().opacity(0.25)

                Toggle(isOn: $companionManager.isUISoundEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Interaction sounds")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("A blip when the mic opens, a chime when the answer is ready.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
                .toggleStyle(.switch)

                Divider().opacity(0.25)

                Toggle(isOn: $companionManager.talkUsesFocusedWindowContext) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Focused window context")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Talk looks only at the app in front of you instead of every screen, for sharper and faster answers. Uses all screens when no window is in front.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                Divider().opacity(0.25)

                Toggle(isOn: Binding(
                    get: { companionManager.isClickyCursorEnabled },
                    set: { companionManager.setClickyCursorEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Cursor companion")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Keep HeyMate beside your pointer. Off: it comes out only while you use it, then goes back to the notch.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
                .toggleStyle(.switch)

                Divider().opacity(0.25)

                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Onboarding")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Watch the introduction again.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    Spacer(minLength: 12)
                    Button("Replay") { companionManager.replayOnboarding() }
                        .buttonStyle(DSSecondaryButtonStyle())
                }
            }
        }
    }

    /// Lived at the bottom of Behavior. It is a text file of rules, which is
    /// a power-user tool, so it moved to Advanced on its own.
    private var behaviorContractCard: some View {
        DesktopCard(title: "Honesty and safety rules") {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Behavior contract")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("The honesty and safety rules HeyMate follows in every reply, kept as a plain text file you can edit.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Edit") { showsBehaviorContractEditor = true }
                    .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
                Button("Reveal") { companionManager.revealBehaviorContractFile() }
                    .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
            }
            .sheet(isPresented: $showsBehaviorContractEditor) {
                BehaviorContractEditorSheet()
            }
        }
    }

    private var computerControlCard: some View {
        DesktopCard(
            title: "Computer control",
            footnote: "Anything that clicks, types, or sends opens an approval card first — there is no setting that removes that step."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { computerUseCoordinator.isEnabled },
                    set: { computerUseCoordinator.isEnabled = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Let HeyMate use this Mac")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Presses buttons by their on-screen name, types into the field you are in, and switches apps. Needs Accessibility permission.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                if computerUseCoordinator.isEnabled,
                   !AccessibilityElementFinder.isAccessibilityTrusted {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(DS.Colors.warning)
                        Text("Accessibility permission is off, so only reading the screen will work.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.warningText)
                        Spacer(minLength: 0)
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(
                                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                            )!)
                        }
                        .buttonStyle(DSSecondaryButtonStyle())
                    }
                }

                Divider().opacity(0.25)

                VStack(alignment: .leading, spacing: 4) {
                    ruleLine("Passwords, API keys and tokens are refused outright — not asked about, refused.")
                    ruleLine("Shortcuts that quit, close, or delete are treated as destructive and always ask.")
                    ruleLine("Buttons are pressed by name when possible, so your pointer never moves.")
                    ruleLine("When a real click is unavoidable, the companion cursor flies there first so you see it.")
                }
            }
        }
    }

    private func ruleLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark")
                .font(DS.Glyph.micro)
                .foregroundColor(DS.Colors.success)
            Text(text)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var appearanceCard: some View {
        DesktopCard(
            title: "Appearance",
            footnote: "The accent tints the cursor companion and action buttons. The notch stays pitch black."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(AppTheme.swatches) { swatch in
                        Button {
                            companionManager.setThemeColorHex(swatch.hex)
                        } label: {
                            Circle()
                                .fill(swatch.color)
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle().stroke(
                                        Color.white.opacity(
                                            companionManager.themeColorHex.caseInsensitiveCompare(swatch.hex) == .orderedSame ? 0.9 : 0
                                        ),
                                        lineWidth: 2
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .help(swatch.name)
                    }
                    Spacer(minLength: 0)
                }

            }
        }
    }

    // MARK: Double-tap shortcuts

    private var pushToTalkCard: some View {
        DesktopCard(
            title: "Push-to-talk shortcuts",
            footnote: "Hold-to-talk keys work from anywhere on the Mac. The notch card shows the active ones."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                pushToTalkPickerRow(
                    title: "Talk",
                    subtitle: "Hold and ask about anything on your screen.",
                    selection: $companionManager.talkShortcutOption
                )

                Divider().opacity(0.25)

                pushToTalkPickerRow(
                    title: "Chat",
                    subtitle: "Drop the compact notch chat, ready for typing.",
                    selection: $companionManager.chatShortcutOption
                )

                Divider().opacity(0.25)

                pushToTalkPickerRow(
                    title: "Dictate",
                    subtitle: "Type what you say into the focused field.",
                    selection: $companionManager.dictateShortcutOption
                )

                Divider().opacity(0.25)

                pushToTalkPickerRow(
                    title: "Region select",
                    subtitle: "Circle part of the screen and ask about just that.",
                    selection: $companionManager.spatialSelectShortcutOption
                )
            }
        }
    }

    private func pushToTalkPickerRow(
        title: String,
        subtitle: String,
        selection: Binding<BuddyPushToTalkShortcut.ShortcutOption>
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(subtitle)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer(minLength: 12)

            Picker("", selection: selection) {
                ForEach(BuddyPushToTalkShortcut.ShortcutOption.allOptions, id: \.self) { option in
                    Text(option.displayText).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 200, alignment: .trailing)
        }
    }

    private var shortcutsCard: some View {
        DesktopCard(
            title: "Double-tap shortcuts",
            footnote: "A tap means pressed and released quickly with no other key. Holding the same keys still does what it always did."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                doubleTapRow(
                    title: "Text",
                    subtitle: "Summon the typed ask box from anywhere.",
                    isEnabled: $isTextDoubleTapEnabled,
                    shortcut: $textDoubleTapShortcut
                )

                Divider().opacity(0.25)

                doubleTapRow(
                    title: "Hands-free",
                    subtitle: "Start a turn that ends when you stop talking instead of when you let go. Tap again to end it early.",
                    isEnabled: $isHandsFreeDoubleTapEnabled,
                    shortcut: $handsFreeDoubleTapShortcut
                )
            }
        }
    }

    private func doubleTapRow(
        title: String,
        subtitle: String,
        isEnabled: Binding<Bool>,
        shortcut: Binding<ModifierDoubleTapShortcut>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: isEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(subtitle)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
            .toggleStyle(.switch)

            Picker("", selection: shortcut) {
                ForEach(ModifierDoubleTapShortcut.allCases, id: \.self) { option in
                    Text(option.displayText).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 220, alignment: .leading)
            .disabled(!isEnabled.wrappedValue)
        }
    }

    // MARK: Microphone

    private var microphoneCard: some View {
        DesktopCard(
            title: "Microphone",
            footnote: "Applies to the next thing you say. An unplugged device falls back to the system default."
        ) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Input device")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(AudioInputDeviceCatalog.selectedDeviceDisplayName())
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                Spacer(minLength: 12)
                Picker("", selection: $selectedAudioInputDeviceUID) {
                    Text("System default").tag(AudioInputDeviceCatalog.systemDefaultDeviceID)
                    ForEach(availableAudioInputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
            }
        }
    }

    // MARK: Voice

    private var voiceCard: some View {
        DesktopCard(
            title: "Voice",
            footnote: "Spoken replies use this Mac's voice unless HeyMate cloud voice is turned on under Advanced › Listen & speak."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Spoken voice")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Enhanced voices download from System Settings › Accessibility › Spoken Content.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    Spacer(minLength: 12)
                    Picker("", selection: $selectedSystemVoiceID) {
                        Text("System default").tag(SpeechVoiceCatalog.systemDefaultVoiceID)
                        ForEach(availableSystemVoices) { voice in
                            Text(voice.displayName).tag(voice.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260)
                }
            }
        }
    }

    // MARK: System presence

    private var systemPresenceCard: some View {
        DesktopCard(
            title: "System presence",
            footnote: "HeyMate normally has no Dock icon — the notch is its home."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $presencePreferences.showsInDock) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show in Dock")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Keeps a Dock icon and a menu bar for the whole session, not only while this window is open.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
                .toggleStyle(.switch)

                Divider().opacity(0.25)

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Without a notch")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("On a Mac or display with no notch, draw a fake one at the top of the screen, or keep HeyMate in the menu bar.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    Spacer(minLength: 12)
                    Picker("", selection: $presencePreferences.noNotchPlacement) {
                        ForEach(NoNotchPlacement.allCases) { placement in
                            Text(placement.title).tag(placement)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }

                Divider().opacity(0.25)

                Toggle(isOn: $presencePreferences.launchesAtLogin) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Launch at login")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Starts HeyMate when you log in.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
                .toggleStyle(.switch)

                Divider().opacity(0.25)

                Toggle(isOn: $presencePreferences.appearsInScreenRecordings) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Show in screen recordings")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Off hides the notch tab, the card, and the cursor companion from screenshots, recordings, and shared screens.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    // MARK: Updates & support

    private var updatesAndSupportCard: some View {
        DesktopCard(
            title: "Updates & support",
            footnote: "Version \(updateController.displayedVersion)."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Updates")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text(lastUpdateCheckDescription)
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    Spacer(minLength: 12)
                    Button("Check now") { updateController.checkForUpdates() }
                        .buttonStyle(DSSecondaryButtonStyle())
                        .disabled(!updateController.canCheckForUpdates)
                        .pointerCursor()
                }

                if updateController.isReady {
                    Toggle(isOn: $updateController.automaticallyChecksForUpdates) {
                        Text("Check automatically")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                    }
                    .toggleStyle(.switch)
                } else {
                    Text(updateAvailabilityDescription)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Divider().opacity(0.25)

                ForEach(SupportLinks.destinations) { destination in
                    HStack {
                        Image(systemName: destination.symbolName)
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textSecondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(destination.title)
                                .font(DS.Fonts.body)
                                .foregroundColor(DS.Colors.textPrimary)
                            Text(destination.subtitle)
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                        Spacer(minLength: 12)
                        Button("Open") { SupportLinks.open(destination) }
                            .buttonStyle(DSSecondaryButtonStyle())
                            .pointerCursor()
                    }
                }
            }
        }
    }

    private var lastUpdateCheckDescription: String {
        switch updateController.availability {
        case .sourceBuild:
            return "Updates unavailable in this source build."
        case .notStarted, .starting:
            return "Update service is starting."
        case .failed:
            return "Update service failed to start."
        case .ready:
            break
        }
        guard let lastUpdateCheckDate = updateController.lastUpdateCheckDate else {
            return "Not checked yet."
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: lastUpdateCheckDate, relativeTo: Date()))."
    }

    private var updateAvailabilityDescription: String {
        switch updateController.availability {
        case .sourceBuild:
            return "Automatic updates activate in signed release builds."
        case .notStarted, .starting:
            return "Automatic updates are starting."
        case .failed:
            return "Automatic updates are unavailable because the update service could not start. Restart HeyMate or download the next release manually."
        case .ready:
            return "Automatic updates are ready."
        }
    }

    // MARK: Data on this Mac

    private var localDataCard: some View {
        DesktopCard(
            title: "Data on this Mac",
            footnote: "Project folders under ~/Projects are not deleted."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Erases HeyMate data stored on this Mac. You will be asked to confirm first.")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let persistErrorMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(persistErrorMessage)
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.destructiveText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Dismiss", action: dismissPersistedError)
                            .buttonStyle(DSTertiaryButtonStyle())
                    }
                }

                if let localDataEraseNote {
                    Text(localDataEraseNote)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Erase HeyMate data") {
                    isConfirmingLocalDataErase = true
                }
                .buttonStyle(DSDestructiveButtonStyle())
            }
        }
        .onAppear(perform: refreshPersistedError)
        .onReceive(NotificationCenter.default.publisher(for: LocalDataErase.persistFailedNotification)) { _ in
            refreshPersistedError()
        }
        .confirmationDialog(
            "Erase HeyMate data?",
            isPresented: $isConfirmingLocalDataErase,
            titleVisibility: .visible
        ) {
            Button("Erase HeyMate data", role: .destructive) {
                localDataEraseNote = LocalDataErase.erase(companionManager: companionManager)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(LocalDataErase.confirmationMessage)
        }
    }

    private func refreshPersistedError() {
        let stored = UserDefaults.standard.string(forKey: LocalDataErase.persistErrorDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        persistErrorMessage = (stored?.isEmpty == false) ? stored : nil
    }

    private func dismissPersistedError() {
        UserDefaults.standard.removeObject(forKey: LocalDataErase.persistErrorDefaultsKey)
        persistErrorMessage = nil
    }
}

/// Edits `behavior-contract.md`. Save writes the draft. Reset rewrites the
/// file from the shipped rules and does not change those rules.
private struct BehaviorContractEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var showsResetConfirmation = false
    @State private var saveError: String?

    init() {
        let existing = (try? String(contentsOf: BehaviorContract.fileURL(), encoding: .utf8))
            ?? BehaviorContract.resetContractText()
        _draft = State(initialValue: existing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Behavior contract")
                .font(DS.Fonts.title)
                .foregroundColor(DS.Colors.textPrimary)
            Text("Honesty and safety rules bound to every reply.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)

            TextEditor(text: $draft)
                .font(.custom("Avenir Next", size: 14))
                .foregroundColor(DS.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    DS.Colors.surface2,
                    in: RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )

            HStack(spacing: 8) {
                Button("Reset to shipped text") { showsResetConfirmation = true }
                    .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
                Spacer(minLength: 8)
                Button("Cancel") { dismiss() }
                    .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
                Button("Save") { saveDraft() }
                    .buttonStyle(DSPrimaryButtonStyle(isFullWidth: false))
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .background(DS.Colors.surface1)
        .presentationBackground(DS.Colors.surface1)
        .confirmationDialog(
            "Reset to the shipped honesty and safety rules?",
            isPresented: $showsResetConfirmation
        ) {
            Button("Reset to shipped text", role: .destructive) { resetToShippedText() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replaces this file with the rules that shipped with HeyMate.")
        }
        .alert("Could not update the behavior contract", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "Unknown error")
        }
    }

    private func saveDraft() {
        do {
            try BehaviorContract.writeContractText(draft, to: BehaviorContract.fileURL())
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func resetToShippedText() {
        let shipped = BehaviorContract.resetContractText()
        do {
            try BehaviorContract.writeContractText(shipped, to: BehaviorContract.fileURL())
            draft = shipped
        } catch {
            saveError = error.localizedDescription
        }
    }
}
