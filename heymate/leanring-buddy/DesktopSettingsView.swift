//
//  DesktopSettingsView.swift
//  leanring-buddy
//
//  Settings in the window.
//
//  Four controls used to live inline in the notch card — dictation mode,
//  interaction sounds, the cursor companion, and replaying onboarding.
//  They are preferences, not live state, so they moved here when the notch
//  card was cut back to only what is currently happening. This view puts
//  them above the existing engine/model/voice settings so nothing was lost
//  in that move.
//

import AppKit
import SwiftUI

struct DesktopSettingsView: View {
    @ObservedObject var companionManager: CompanionManager

    /// Observed directly so toggling computer control re-renders the
    /// permission warning underneath it without waiting for some other
    /// change on the manager.
    @ObservedObject private var computerUseCoordinator: ComputerUseCoordinator

    @ObservedObject private var presencePreferences = AppPresencePreferences.shared
    @ObservedObject private var updateController = AppUpdateController.shared

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
    /// What the ElevenLabs picker is showing: "" for the Worker's own
    /// default, a premade voice id, or the custom tag when the stored id is
    /// one the user typed (a cloned or library voice).
    @State private var elevenLabsVoiceSelection = SpeechVoiceCatalog
        .elevenLabsPickerSelection(forStoredVoiceID: SpeechVoiceCatalog.selectedElevenLabsVoiceID)
    @State private var elevenLabsCustomVoiceID = SpeechVoiceCatalog.selectedElevenLabsVoiceID
    @State private var composioAPIKeyDraft = ""
    @State private var composioStatusMessage: String?
    @State private var isSavingComposioAPIKey = false

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self.computerUseCoordinator = companionManager.computerUseCoordinator
    }

    var body: some View {
        DesktopPage(
            title: "Settings",
            subtitle: "How HeyMate behaves, which engine answers, and how it sounds."
        ) {
            behaviorCard
            pushToTalkCard
            shortcutsCard
            microphoneCard
            voiceCard
            computerControlCard
            composioCard
            appearanceCard
            systemPresenceCard
            updatesAndSupportCard

            // Desktop presentation removes the notch-only appearance controls
            // and its inner scroller, so this remains one continuous settings
            // page with each preference shown once.
            DesktopCard(title: "Brain, providers & tools") {
                AISettingsView(
                    companionManager: companionManager,
                    presentation: .desktop
                )
            }
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

    private var composioCard: some View {
        DesktopCard(
            title: "Composio",
            footnote: "Stored in macOS Keychain. HeyMate never receives tokens for Gmail, Slack, or other connected apps."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("One Composio API key powers browser sign-in and tools for supported integrations. Composio's free tier is enough to get started.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    SecureField(
                        companionManager.composioConnections.isConfigured ? "API key saved" : "Composio API key",
                        text: $composioAPIKeyDraft
                    )
                    .textFieldStyle(.roundedBorder)

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
                    ProgressView("Preparing integrations…")
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
                composioStatusMessage = "Ready. Supported apps can now connect from Integrations."
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

    private var behaviorCard: some View {
        DesktopCard(title: "Behavior") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Dictation mode")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Smart cleans up filler and punctuation. Literal types exactly what you said.")
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
                        Text("Talk captures only the app in front of you instead of every screen — sharper answers, cheaper vision calls. Falls back to all screens when there's no window.")
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
                        Text("Cursor launcher")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Keep the buddy deployed beside your pointer. Off: it launches only for an interaction, then returns to the notch.")
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

                Divider().opacity(0.25)

                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Behavior contract")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("The honesty and safety rules bound to every reply, as a plain text file you can edit without a rebuild.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button("Reveal") { companionManager.revealBehaviorContractFile() }
                        .buttonStyle(DSSecondaryButtonStyle())
                }
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
                        Text("Clicks buttons by their real name via the accessibility tree, types into the focused field, and switches apps. Needs Accessibility permission.")
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
                    ruleLine("Quitting, closing, and deleting chords are treated as destructive and always ask.")
                    ruleLine("Buttons are pressed through the accessibility tree when possible, so the pointer never moves.")
                    ruleLine("When a real click is unavoidable, the companion cursor flies there first so you see it.")
                }
            }
        }
    }

    private func ruleLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
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
            footnote: "The accent tints the notch rim, the cursor companion, and the buttons in both surfaces."
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

                Divider().opacity(0.25)

                Toggle(isOn: Binding(
                    get: { companionManager.isNotchOutlineEnabled },
                    set: { companionManager.setNotchOutlineEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Notch rim")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("A thin accent line around the camera housing.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }
                .toggleStyle(.switch)
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
            footnote: "Spoken replies use the macOS synthesizer unless Speak is switched to ElevenLabs in Brain, providers & tools — the ElevenLabs voice only applies once it is."
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

                Divider().opacity(0.25)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("ElevenLabs voice")
                                .font(DS.Fonts.body)
                                .foregroundColor(DS.Colors.textPrimary)
                            Text("Every voice listed works on a free ElevenLabs plan.")
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                        Spacer(minLength: 12)
                        Picker("", selection: $elevenLabsVoiceSelection) {
                            Text("Server default").tag("")
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
                            Text("Library and cloned voices need a paid ElevenLabs plan; a free account gets paid_plan_required and stays silent.")
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
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

                Toggle(isOn: $updateController.automaticallyChecksForUpdates) {
                    Text("Check automatically")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textPrimary)
                }
                .toggleStyle(.switch)

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
        guard let lastUpdateCheckDate = updateController.lastUpdateCheckDate else {
            return "Not checked yet."
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: lastUpdateCheckDate, relativeTo: Date()))."
    }
}
