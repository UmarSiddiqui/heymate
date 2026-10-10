//
//  SettingsVoicePane.swift
//  leanring-buddy
//
//  Settings › Talk & Voice: how talking behaves, which microphone, and who
//  listens and speaks. These used to be spread over three places — the Mac
//  voice and microphone under General, the Listen/Speak providers and the
//  ElevenLabs voice under Advanced — so every voice question now has one
//  answer page.
//

import SwiftUI

struct SettingsVoicePane: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var navigation: SettingsNavigationModel

    // Device and voice lists are read when the page appears and on demand.
    // Enumerating CoreAudio on every body evaluation would be wasteful and
    // makes an open menu flicker.
    @State private var availableAudioInputDevices: [AudioInputDevice] = []
    @State private var selectedAudioInputDeviceUID = AudioInputDeviceCatalog.selectedDeviceUID
    @State private var availableSystemVoices: [SpeechVoiceOption] = []
    @State private var selectedSystemVoiceID = SpeechVoiceCatalog.selectedSystemVoiceID

    /// Bumped after the ElevenLabs key changes so locked providers re-read.
    @State private var credentialsRevision = 0
    @State private var hasElevenLabsKey = ElevenLabsCredentials.hasUserAPIKey
    @State private var elevenLabsKeyMessage: String?

    var body: some View {
        SettingsPage(tab: .voice, navigation: navigation) {
            talkingSection
            microphoneSection
            listenAndSpeakSection
                .id(credentialsRevision)
            voicesSection
        }
        .onAppear {
            refreshAudioInputDevices()
            availableSystemVoices = SpeechVoiceCatalog.availableSystemVoices()
        }
        .onChange(of: selectedAudioInputDeviceUID) { _, newValue in
            AudioInputDeviceCatalog.selectedDeviceUID = newValue
        }
        .onChange(of: selectedSystemVoiceID) { _, newValue in
            SpeechVoiceCatalog.selectedSystemVoiceID = newValue
        }
    }

    // MARK: Talking

    private var talkingSection: some View {
        SettingsSection("Talking") {
            SettingsToggleRow(
                SettingsItem.silentMode.title,
                subtitle: "For work or in public. Your Talk shortcut (\(companionManager.talkShortcutOption.displayText)) opens a box to type in instead of the mic, Dictate is off, and replies appear on screen without being spoken. Type /silent anywhere to switch.",
                item: .silentMode,
                isOn: $companionManager.isSilentModeEnabled
            )
            SettingsDivider()
            SettingsRow(
                SettingsItem.dictationMode.title,
                subtitle: "Smart drafts from what's on screen into the field you're in. Literal types exactly what you said. Smart stays quiet while HeyMate itself is in front.",
                item: .dictationMode
            ) {
                DSSegmentedControl(
                    accessibilityTitle: SettingsItem.dictationMode.title,
                    selection: $companionManager.dictationUsesSmartMode,
                    segments: [
                        DSSegment(value: false, title: "Literal"),
                        DSSegment(value: true, title: "Smart")
                    ],
                    width: DS.SettingsLayout.segmentedWidth * 0.75
                )
            }
            SettingsDivider()
            SettingsToggleRow(
                SettingsItem.focusedWindow.title,
                subtitle: "Talk looks only at the app in front of you instead of every screen, for sharper, faster answers. Uses every screen when no window is in front.",
                item: .focusedWindow,
                isOn: $companionManager.talkUsesFocusedWindowContext
            )
            SettingsDivider()
            SettingsToggleRow(
                SettingsItem.interactionSounds.title,
                subtitle: "A blip when the mic opens and a chime when the answer is ready.",
                item: .interactionSounds,
                isOn: $companionManager.isUISoundEnabled
            )
        }
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
            footer: "Applies to the next thing you say. If the device is unplugged, HeyMate uses the system default."
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
            footer: "On-device and Mac options keep your voice on this computer. ElevenLabs uses your own ElevenLabs account. If a choice can't run, HeyMate falls back to the Mac so you're never left without a voice."
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
                    segments: VoiceListenProvider.allCases.map { provider in
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
                    segments: VoiceSpeakProvider.allCases.map { provider in
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

    private var systemVoiceOptions: [DSMenuOption<String>] {
        [DSMenuOption(value: SpeechVoiceCatalog.systemDefaultVoiceID, title: "Automatic (best voice)")]
            + availableSystemVoices.enumerated().map { index, voice in
                DSMenuOption(value: voice.id, title: voice.displayName, startsGroup: index == 0)
            }
    }

    private var voicesSection: some View {
        SettingsSection("Voices") {
            SettingsPickerRow(
                SettingsItem.macVoice.title,
                subtitle: "Used when Speak with is set to Mac, and whenever another voice can't speak. Premium voices sound far better — download them free in System Settings › Accessibility › Spoken Content.",
                item: .macVoice,
                selection: $selectedSystemVoiceID,
                options: systemVoiceOptions,
                placeholder: "Automatic (best voice)"
            )

            SettingsDivider()

            OnDeviceVoiceDownloadRow(companionManager: companionManager)
                .settingsRowInsets()
                .settingsAnchor(.onDeviceVoice)

            SettingsDivider()

            SettingsSecretKeyRow(
                title: SettingsItem.elevenLabsKey.title,
                subtitle: hasElevenLabsKey
                    ? "Pick ElevenLabs under Listen & speak to use it."
                    : "Optional. Paste a key from elevenlabs.io to use their voices — the free plan works.",
                item: .elevenLabsKey,
                placeholder: "ElevenLabs API key",
                isStored: hasElevenLabsKey,
                removalTitle: "Remove the ElevenLabs key?",
                removalMessage: "HeyMate deletes it from this Mac. Anything set to ElevenLabs falls back to the on-device or Mac voice.",
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
