//
//  SpeechVoiceCatalog.swift
//  leanring-buddy
//
//  Which voice speaks the replies. Two independent selections, because the two
//  TTS backends do not share a voice namespace:
//
//  - the macOS system synthesizer (the wired-up default) picks from the voices
//    installed on the machine, identified by AVSpeechSynthesisVoice identifier
//  - ElevenLabs picks by voice id. Those are global for the premade voices
//    every account gets, so they can be listed by name in the picker; a
//    cloned or library voice is still enterable by id
//
//  Before this, the macOS path always used the current-locale default voice and
//  the ElevenLabs path was fixed server-side by a Worker variable, so there was
//  no way to change the voice from inside the app at all.
//

import AVFoundation
import Foundation

nonisolated struct SpeechVoiceOption: Identifiable, Hashable {
    /// `AVSpeechSynthesisVoice.identifier`.
    let id: String
    let name: String
    let languageCode: String
    /// Siri / Premium / Enhanced voices sound markedly better and are worth
    /// surfacing first.
    let isHighQuality: Bool

    var displayName: String {
        let localizedLanguage = Locale.current.localizedString(forIdentifier: languageCode) ?? languageCode
        return isHighQuality ? "\(name) — \(localizedLanguage) (enhanced)" : "\(name) — \(localizedLanguage)"
    }
}

/// One ElevenLabs voice offered in Settings by name rather than by id.
nonisolated struct ElevenLabsVoiceOption: Identifiable, Hashable {
    /// The ElevenLabs voice id, sent to the Worker as `voice_id`.
    let id: String
    let name: String
    let accent: String

    var displayName: String { "\(name) — \(accent.capitalized)" }
}

nonisolated enum SpeechVoiceCatalog {

    /// Stored value meaning "whatever matches the system language", which is
    /// the behavior the app had before a picker existed.
    static let systemDefaultVoiceID = "system-default"

    static let systemVoicePreferenceKey = "selectedSystemSpeechVoiceIdentifier"
    static let elevenLabsVoicePreferenceKey = "selectedElevenLabsVoiceID"

    /// Same shape the Worker validates against, checked here too so a typo is
    /// caught in Settings instead of failing as an opaque upstream 400.
    static let elevenLabsVoiceIDPattern = "^[A-Za-z0-9]{1,64}$"

    // MARK: macOS system voices

    /// Installed voices, best-sounding first, then alphabetically. Voices for
    /// the user's own language float to the top — a picker that opens on
    /// Albanian is useless on an English machine.
    static func availableSystemVoices() -> [SpeechVoiceOption] {
        let preferredLanguagePrefix = String(Locale.current.identifier.prefix(2))

        return AVSpeechSynthesisVoice.speechVoices()
            .map { voice in
                SpeechVoiceOption(
                    id: voice.identifier,
                    name: voice.name,
                    languageCode: voice.language,
                    isHighQuality: voice.quality != .default
                )
            }
            .sorted { first, second in
                let firstMatchesLanguage = first.languageCode.hasPrefix(preferredLanguagePrefix)
                let secondMatchesLanguage = second.languageCode.hasPrefix(preferredLanguagePrefix)
                if firstMatchesLanguage != secondMatchesLanguage { return firstMatchesLanguage }
                if first.isHighQuality != second.isHighQuality { return first.isHighQuality }
                return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
            }
    }

    static var selectedSystemVoiceID: String {
        get { UserDefaults.standard.string(forKey: systemVoicePreferenceKey) ?? systemDefaultVoiceID }
        set { UserDefaults.standard.set(newValue, forKey: systemVoicePreferenceKey) }
    }

    /// The voice to speak with, or nil to let AVSpeechSynthesizer choose.
    /// A stored identifier for a voice that has since been uninstalled
    /// resolves to nil rather than failing to speak.
    static func resolvedSystemVoice() -> AVSpeechSynthesisVoice? {
        let identifier = selectedSystemVoiceID
        guard identifier != systemDefaultVoiceID else { return nil }
        return AVSpeechSynthesisVoice(identifier: identifier)
    }

    // MARK: ElevenLabs

    /// Empty means "use whatever voice the Worker is configured with".
    static var selectedElevenLabsVoiceID: String {
        get { UserDefaults.standard.string(forKey: elevenLabsVoicePreferenceKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: elevenLabsVoicePreferenceKey) }
    }

    /// Picker tag meaning "I will type an id myself". Not a voice id, and
    /// deliberately not matchable as one — it contains a character the
    /// Worker's `^[A-Za-z0-9]{1,64}$` pattern rejects.
    static let customElevenLabsVoiceSelectionTag = "custom-voice-id"

    /// The voices every ElevenLabs account can use, including free ones.
    ///
    /// Premade voice ids are global rather than per-account, which is what
    /// makes a static list correct here. Library and cloned voices are not
    /// listed: their ids differ per account, and a free plan cannot use them
    /// at all — the API answers `paid_plan_required`, which arrives as an
    /// opaque failure to speak. Anyone on a paid plan can still paste an id.
    ///
    /// Ordered so the non-American accents are easy to find, then by name.
    static let elevenLabsPremadeVoices: [ElevenLabsVoiceOption] = [
        ElevenLabsVoiceOption(id: "IKne3meq5aSn9XLyUdCD", name: "Charlie", accent: "australian"),
        ElevenLabsVoiceOption(id: "Xb7hH8MSUJpSbSDYk0k2", name: "Alice", accent: "british"),
        ElevenLabsVoiceOption(id: "onwK4e9ZLuTAKqWW03F9", name: "Daniel", accent: "british"),
        ElevenLabsVoiceOption(id: "JBFqnCBsd6RMkjVDRZzb", name: "George", accent: "british"),
        ElevenLabsVoiceOption(id: "pFZP5JQG7iQjIQuC4Bku", name: "Lily", accent: "british"),
        ElevenLabsVoiceOption(id: "pNInz6obpgDQGcFmaJgB", name: "Adam", accent: "american"),
        ElevenLabsVoiceOption(id: "hpp4J3VqNfWAUOO0d1Us", name: "Bella", accent: "american"),
        ElevenLabsVoiceOption(id: "pqHfZKP75CvOlQylNhV4", name: "Bill", accent: "american"),
        ElevenLabsVoiceOption(id: "nPczCjzI2devNBz1zQrb", name: "Brian", accent: "american"),
        ElevenLabsVoiceOption(id: "N2lVS1w4EtoT3dr4eOWO", name: "Callum", accent: "american"),
        ElevenLabsVoiceOption(id: "iP95p4xoKVk53GoZ742B", name: "Chris", accent: "american"),
        ElevenLabsVoiceOption(id: "cjVigY5qzO86Huf0OWal", name: "Eric", accent: "american"),
        ElevenLabsVoiceOption(id: "SOYHLrjzK2X1ezoPC6cr", name: "Harry", accent: "american"),
        ElevenLabsVoiceOption(id: "cgSgspJ2msm6clMCkdW9", name: "Jessica", accent: "american"),
        ElevenLabsVoiceOption(id: "FGY2WhTYpPnrIDTdsKH5", name: "Laura", accent: "american"),
        ElevenLabsVoiceOption(id: "TX3LPaxmHKxFdv7VOQHJ", name: "Liam", accent: "american"),
        ElevenLabsVoiceOption(id: "XrExE9yKIg1WjnnlVkGX", name: "Matilda", accent: "american"),
        ElevenLabsVoiceOption(id: "SAz9YHcvj6GT2YYXdXww", name: "River", accent: "american"),
        ElevenLabsVoiceOption(id: "CwhRBWXzGAHq8TQ4Fs17", name: "Roger", accent: "american"),
        ElevenLabsVoiceOption(id: "EXAVITQu4vr4xnSDxMaL", name: "Sarah", accent: "american"),
        ElevenLabsVoiceOption(id: "bIHbv24MWmeRgasZH58o", name: "Will", accent: "american")
    ]

    static func premadeVoice(withID voiceID: String) -> ElevenLabsVoiceOption? {
        elevenLabsPremadeVoices.first { $0.id == voiceID }
    }

    /// What the picker should be showing for the currently stored id: the
    /// empty Worker-default tag, a named voice, or the custom-id tag for an
    /// id typed in by hand (a cloned or library voice).
    static func elevenLabsPickerSelection(forStoredVoiceID storedVoiceID: String) -> String {
        let trimmedVoiceID = storedVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedVoiceID.isEmpty { return "" }
        if premadeVoice(withID: trimmedVoiceID) != nil { return trimmedVoiceID }
        return customElevenLabsVoiceSelectionTag
    }

    static func isValidElevenLabsVoiceID(_ candidate: String) -> Bool {
        candidate.range(of: elevenLabsVoiceIDPattern, options: .regularExpression) != nil
    }

    /// The id to send with a TTS request, or nil to send none.
    static func resolvedElevenLabsVoiceID() -> String? {
        let candidate = selectedElevenLabsVoiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, isValidElevenLabsVoiceID(candidate) else { return nil }
        return candidate
    }
}
