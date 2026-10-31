//
//  SettingsVoicePane.swift
//  HeyMate
//
//  Voice cards and speed first; providers, credentials, microphone and
//  interaction controls live under Advanced.
//

import SwiftUI

struct SettingsVoicePane: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var navigation: SettingsNavigationModel
    @ObservedObject private var dictationVocabulary = DictationVocabulary.shared

    // Device and voice lists are read when the page appears and on demand.
    // Enumerating CoreAudio on every body evaluation would be wasteful and
    // makes an open menu flicker.
    @State private var availableAudioInputDevices: [AudioInputDevice] = []
    @State private var selectedAudioInputDeviceUID = AudioInputDeviceCatalog.selectedDeviceUID
    @State private var showsAdvanced = false

    /// Bumped after the ElevenLabs key changes so locked providers re-read.
    @State private var credentialsRevision = 0
    @State private var hasElevenLabsKey = ElevenLabsCredentials.hasUserAPIKey
    @State private var elevenLabsKeyMessage: String?
    @AppStorage(CompanionCursorView.bottomCaptionsPreferenceKey) private var showsBottomCaptions = false

    var body: some View {
        SettingsPage(tab: .voice, navigation: navigation) {
            SpeechSpeedRow()
                .settingsAnchor(.speechSpeed)
            OnDeviceVoiceGrid()
                .settingsAnchor(.onDeviceVoiceStyle)
            OnDeviceVoiceDownloadRow(companionManager: companionManager, isCompact: true)
                .settingsAnchor(.onDeviceVoice)
            SettingsToggleRow(
                SettingsItem.captions.title,
                subtitle: "HeyMate's words appear in the notch. With the notch off, show them at the bottom of the screen instead of beside the cursor.",
                item: .captions,
                isOn: $showsBottomCaptions
            )
            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: DS.SettingsLayout.sectionSpacing) {
                    listenAndSpeakSection.id(credentialsRevision)
                    elevenLabsSection
                    microphoneSection
                    talkingSection
                }
                .padding(.top, DS.Spacing.md)
            }
            .foregroundStyle(DS.Colors.textSecondary)
        }
        .onAppear {
            refreshAudioInputDevices()
            revealAdvancedIfNeeded()
        }
        .onChange(of: navigation.revealRequest) { _, _ in revealAdvancedIfNeeded() }
        .onChange(of: selectedAudioInputDeviceUID) { _, newValue in
            AudioInputDeviceCatalog.selectedDeviceUID = newValue
        }
    }

    private func revealAdvancedIfNeeded() {
        guard let item = navigation.revealRequest?.item, item.tab == .voice else { return }
        if ![SettingsItem.speechSpeed, .onDeviceVoiceStyle, .onDeviceVoice, .captions].contains(item) {
            showsAdvanced = true
        }
    }

    // MARK: Talking

    private var talkingSection: some View {
        SettingsSection("Talking") {
            SettingsToggleRow(
                SettingsItem.silentMode.title,
                subtitle: "Type instead of talking, and read replies instead of hearing them. Type /silent anywhere to switch.",
                item: .silentMode,
                isOn: $companionManager.isSilentModeEnabled
            )
            SettingsDivider()
            SettingsRow(
                SettingsItem.dictationMode.title,
                subtitle: "Literal dictation types your original words. Smart rewriting is currently unavailable.",
                item: .dictationMode
            ) {
                DSSegmentedControl(
                    accessibilityTitle: SettingsItem.dictationMode.title,
                    selection: Binding(get: { companionManager.effectiveDictationUsesSmartMode },
                                       set: { companionManager.dictationUsesSmartMode = $0 }),
                    segments: [
                        DSSegment(value: false, title: "Literal"),
                        DSSegment(value: true, title: "Smart")
                    ],
                    width: DS.SettingsLayout.segmentedWidth * 0.75
                )
                .disabled(true)
            }
            SettingsDivider()
            SettingsRow(
                SettingsItem.learnedWords.title,
                subtitle: learnedWordsSubtitle,
                item: .learnedWords
            ) {
                if !dictationVocabulary.words.isEmpty {
                    Button("Clear") { dictationVocabulary.removeAll() }
                }
            }
            SettingsDivider()
            SettingsToggleRow(
                SettingsItem.focusedWindow.title,
                subtitle: "Sharper, faster answers from the app in front of you.",
                item: .focusedWindow,
                isOn: $companionManager.talkUsesFocusedWindowContext
            )
            SettingsDivider()
            SettingsToggleRow(
                SettingsItem.interactionSounds.title,
                subtitle: "A soft blip and chime as HeyMate listens and answers.",
                item: .interactionSounds,
                isOn: $companionManager.isUISoundEnabled
            )
        }
    }

    private var learnedWordsSubtitle: String {
        let words = dictationVocabulary.keyterms
        guard !words.isEmpty else {
            return "Fix a word HeyMate typed for you and it hears that word right next time."
        }
        return words.prefix(12).joined(separator: ", ") + (words.count > 12 ? ", and \(words.count - 12) more" : "")
    }

    // MARK: Microphone

    private var microphoneOptions: [DSMenuOption<String>] {
        [DSMenuOption(value: AudioInputDeviceCatalog.systemDefaultDeviceID, title: "System default")]
            + availableAudioInputDevices.enumerated().map { index, device in
                DSMenuOption(value: device.id, title: device.name, startsGroup: index == 0)
            }
    }

    private var microphoneSection: some View {
        SettingsSection(
            "Microphone",
            footer: "Falls back to the system default if this device is unplugged."
        ) {
            SettingsRow(
                SettingsItem.microphone.title,
                subtitle: "Now using \(AudioInputDeviceCatalog.selectedDeviceDisplayName()).",
                item: .microphone
            ) {
                HStack(spacing: DS.Spacing.xs) {
                    SettingsRefreshButton(
                        isRefreshing: false,
                        accessibilityTitle: "Look for microphones again",
                        action: refreshAudioInputDevices
                    )
                    DSMenuPicker(
                        accessibilityTitle: SettingsItem.microphone.title,
                        selection: $selectedAudioInputDeviceUID,
                        options: microphoneOptions,
                        placeholder: "System default"
                    )
                }
            }
        }
    }

    private func refreshAudioInputDevices() {
        availableAudioInputDevices = AudioInputDeviceCatalog.availableInputDevices()
    }

    // MARK: Listen & speak

    /// Why a provider can't be switched right now, while a turn is running.
    private var audioProviderBusyMessage: String? {
        switch companionManager.voiceState {
        case .idle:
            return nil
        case .listening:
            return "Finish talking before switching voice options."
        case .processing:
            return "Wait for the current answer before switching voice options."
        case .responding:
            return "Let the current reply finish before switching voice options."
        }
    }

    private func nonEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }

    private var listenAndSpeakSection: some View {
        let isIdle = companionManager.voiceState == .idle
        return SettingsSection(
            "Listen & speak",
            footer: "Local voice is free and private. ElevenLabs uses your API key; if unavailable, HeyMate uses local voice."
        ) {
            SettingsRow(
                SettingsItem.listenProvider.title,
                subtitle: companionManager.selectedListenProvider.settingsHint,
                item: .listenProvider
            ) {
                DSSegmentedControl(
                    accessibilityTitle: SettingsItem.listenProvider.title,
                    selection: Binding(
                        get: { companionManager.selectedListenProvider },
                        set: { companionManager.setSelectedListenProvider($0) }
                    ),
                    segments: [VoiceListenProvider.onDevice, .elevenLabs].map { provider in
                        DSSegment(
                            value: provider,
                            title: provider.displayName,
                            isEnabled: provider.isSelectable && isIdle,
                            help: provider.isSelectable ? audioProviderBusyMessage : nonEmpty(provider.lockedReason)
                        )
                    },
                    width: DS.SettingsLayout.pickerWidth + 40
                )
            }
            SettingsDivider()
            SettingsRow(
                SettingsItem.speakProvider.title,
                subtitle: companionManager.selectedSpeakProvider.settingsHint,
                item: .speakProvider
            ) {
                DSSegmentedControl(
                    accessibilityTitle: SettingsItem.speakProvider.title,
                    selection: Binding(
                        get: { companionManager.selectedSpeakProvider },
                        set: { companionManager.setSelectedSpeakProvider($0) }
                    ),
                    segments: [VoiceSpeakProvider.onDevice, .elevenLabs].map { provider in
                        DSSegment(
                            value: provider,
                            title: provider.displayName,
                            isEnabled: provider.isSelectable && isIdle,
                            help: provider.isSelectable ? audioProviderBusyMessage : nonEmpty(provider.lockedReason)
                        )
                    },
                    width: DS.SettingsLayout.pickerWidth + 40
                )
            }
            if let audioProviderBusyMessage {
                SettingsNotice(text: audioProviderBusyMessage, tone: .progress)
                    .settingsRowContentInsets()
            }
        }
    }

    // MARK: Voices

    private var elevenLabsSection: some View {
        SettingsSection("ElevenLabs") {
            SettingsSecretKeyRow(
                title: SettingsItem.elevenLabsKey.title,
                subtitle: hasElevenLabsKey
                    ? "Pick ElevenLabs under Listen & speak to use it."
                    : "Optional. A free elevenlabs.io key works.",
                item: .elevenLabsKey,
                placeholder: "ElevenLabs API key",
                isStored: hasElevenLabsKey,
                removalTitle: "Remove the ElevenLabs key?",
                removalMessage: "HeyMate deletes it from this Mac. Anything set to ElevenLabs falls back to local voice.",
                onSave: saveElevenLabsKey,
                onRemove: removeElevenLabsKey
            )
            if let elevenLabsKeyMessage {
                SettingsInlineHelp(elevenLabsKeyMessage, tone: .attention)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsRowContentInsets()
            }

            SettingsDivider()

            ElevenLabsVoiceRows()
        }
    }

    private func saveElevenLabsKey(_ key: String) {
        guard ElevenLabsCredentials.saveUserAPIKey(key) else {
            elevenLabsKeyMessage = "Couldn't save the key. Check that HeyMate can write to its data folder, then try again."
            return
        }
        hasElevenLabsKey = true
        elevenLabsKeyMessage = nil
        credentialsRevision += 1
    }

    private func removeElevenLabsKey() {
        ElevenLabsCredentials.removeUserAPIKey()
        hasElevenLabsKey = ElevenLabsCredentials.hasUserAPIKey
        elevenLabsKeyMessage = hasElevenLabsKey
            ? "Removed. A key in your developer secrets file is still in use."
            : nil
        credentialsRevision += 1
    }
}

/// Which ElevenLabs voice HeyMate speaks with. Only matters once Speak with
/// is ElevenLabs.
private struct ElevenLabsVoiceRows: View {
    /// What the menu shows: "" for HeyMate's default, a premade voice id,
    /// or the custom tag when the stored id is one the user typed (a cloned
    /// or library voice).
    @State private var voiceSelection = SpeechVoiceCatalog
        .elevenLabsPickerSelection(forStoredVoiceID: SpeechVoiceCatalog.selectedElevenLabsVoiceID)
    @State private var customVoiceID = SpeechVoiceCatalog.selectedElevenLabsVoiceID

    private var isCustom: Bool {
        voiceSelection == SpeechVoiceCatalog.customElevenLabsVoiceSelectionTag
    }

    private var options: [DSMenuOption<String>] {
        [DSMenuOption(value: "", title: "Default")]
            + SpeechVoiceCatalog.elevenLabsPremadeVoices.enumerated().map { index, voice in
                DSMenuOption(value: voice.id, title: voice.displayName, startsGroup: index == 0)
            }
            + [DSMenuOption(
                value: SpeechVoiceCatalog.customElevenLabsVoiceSelectionTag,
                title: "Custom voice ID…",
                startsGroup: true
            )]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsPickerRow(
                SettingsItem.elevenLabsVoice.title,
                subtitle: "Every voice listed works on a free ElevenLabs plan.",
                item: .elevenLabsVoice,
                selection: $voiceSelection,
                options: options,
                placeholder: "Default"
            )

            // Cloned and library voices have per-account ids, so the typed
            // field stays for anyone on a paid plan.
            if isCustom {
                VStack(alignment: .leading, spacing: DS.Spacing.xs + 2) {
                    TextField("Voice ID from your ElevenLabs dashboard", text: $customVoiceID)
                        .settingsFieldChrome(isMonospaced: true)
                        .accessibilityLabel("Custom ElevenLabs voice ID")
                    if !customVoiceID.isEmpty,
                       !SpeechVoiceCatalog.isValidElevenLabsVoiceID(customVoiceID) {
                        SettingsInlineHelp("Voice IDs are letters and numbers only. This one will be ignored.", tone: .attention)
                    } else {
                        SettingsInlineHelp("Library and cloned voices need a paid ElevenLabs plan. On a free plan HeyMate stays silent instead.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsRowContentInsets()
            }
        }
        .onChange(of: voiceSelection) { _, newSelection in
            // The custom tag is a menu state, not a voice — while it is
            // selected the typed field is the source of truth.
            if newSelection == SpeechVoiceCatalog.customElevenLabsVoiceSelectionTag {
                SpeechVoiceCatalog.selectedElevenLabsVoiceID = customVoiceID
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                SpeechVoiceCatalog.selectedElevenLabsVoiceID = newSelection
            }
        }
        .onChange(of: customVoiceID) { _, newValue in
            guard isCustom else { return }
            SpeechVoiceCatalog.selectedElevenLabsVoiceID = newValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

// MARK: - Speech speed

/// One tap per speed, like a playback-speed control.
struct SpeechSpeedRow: View {
    @State private var speed = SpeechStylePreferences.speed

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRowLabel(
                title: SettingsItem.speechSpeed.title,
                subtitle: "Takes effect on the next spoken reply."
            )
            HStack(spacing: 6) {
                ForEach(SpeechStylePreferences.speedChoices, id: \.self) { choice in
                    let isSelected = abs(choice - speed) < 0.01
                    Button {
                        speed = choice
                        SpeechStylePreferences.speed = choice
                    } label: {
                        Text(SpeechStylePreferences.speedLabel(choice))
                            .font(DS.Fonts.control)
                            .foregroundColor(isSelected ? DS.Colors.textOnAccent : DS.Colors.textSecondary)
                            .frame(minWidth: 52)
                            .frame(height: 28)
                            .background(Capsule().fill(isSelected ? DS.Colors.accent : DS.Colors.surface2))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .accessibilityLabel("\(SpeechStylePreferences.speedLabel(choice)) speed")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - On-device voice grid

/// The on-device voices as cards. Tapping one picks it and plays a short
/// sample, so choosing a voice is listening, not reading names.
struct OnDeviceVoiceGrid: View {
    @ObservedObject private var store = OnDeviceVoiceModelStore.shared
    @State private var selectedID = SpeechStylePreferences.onDeviceVoice
    @State private var previewingID: String?
    @State private var previewClient: KokoroTTSClient?

    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 12)]

    private var isAvailable: Bool { KokoroEngine.modelsAreInstalled() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsRowLabel(
                title: SettingsItem.onDeviceVoiceStyle.title,
                subtitle: isAvailable
                    ? "Tap a voice to hear it. Your pick applies to future local replies."
                    : "Voices become available when the automatic download finishes."
            )
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(OnDeviceVoiceOption.all) { option in
                    card(option)
                }
            }
            .disabled(!isAvailable)
            .opacity(isAvailable ? 1 : 0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { previewClient?.stopPlayback() }
    }

    private func voiceColor(_ option: OnDeviceVoiceOption) -> Color {
        switch option.id {
        case "af_heart": return .pink
        case "af_bella": return .orange
        case "af_nicole": return .purple
        case "af_sky": return .cyan
        case "af_nova": return .yellow
        case "am_michael": return .green
        case "am_adam": return .indigo
        case "am_puck": return .mint
        case "bf_emma": return .blue
        default: return .teal
        }
    }

    private func card(_ option: OnDeviceVoiceOption) -> some View {
        let isSelected = option.id == selectedID
        return Button {
            select(option)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: previewingID == option.id ? "waveform" : option.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(voiceColor(option))
                    .frame(height: 26)
                Text(option.name)
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(option.character)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(DS.Colors.surface2.opacity(isSelected ? 1 : 0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .strokeBorder(isSelected ? DS.Colors.accent : DS.Colors.borderSubtle, lineWidth: isSelected ? 2 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.Colors.textOnAccent, DS.Colors.accent)
                        .padding(6)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("\(option.name), \(option.character)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func select(_ option: OnDeviceVoiceOption) {
        selectedID = option.id
        SpeechStylePreferences.onDeviceVoice = option.id
        previewClient?.stopPlayback()
        // On an OS where Kokoro crashes, picking a voice saves it but never loads the model.
        guard KokoroEngine.unsupportedReason == nil else { return }
        let client = previewClient ?? KokoroTTSClient()
        previewClient = client
        previewingID = option.id
        Task {
            try? await client.speakText("Hi, I'm \(option.name). This is how I'll sound.")
            try? await Task.sleep(for: .seconds(2))
            if previewingID == option.id { previewingID = nil }
        }
    }
}
