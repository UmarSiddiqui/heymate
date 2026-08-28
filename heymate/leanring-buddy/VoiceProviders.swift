//
//  VoiceProviders.swift
//  leanring-buddy
//
//  Listen (speech-to-text) and Speak (text-to-speech) choices for the
//  Models settings page. Independent of the brain (Claude / OpenCode).
//

import Foundation

enum VoiceListenProvider: String, CaseIterable, Hashable {
    case apple
    case assemblyAI = "assemblyai"
    case openAI = "openai"

    var displayName: String {
        switch self {
        case .apple: return "Mac"
        case .assemblyAI: return "AssemblyAI"
        case .openAI: return "OpenAI"
        }
    }

    var pickerHint: String {
        switch self {
        case .apple:
            return "On this Mac. Needs Speech Recognition permission."
        case .assemblyAI:
            return "Streaming listen via your Worker."
        case .openAI:
            return "Cloud transcription. Needs OpenAIAPIKey in Info.plist."
        }
    }

    var isSelectable: Bool {
        switch self {
        case .apple, .assemblyAI:
            return true
        case .openAI:
            return OpenAIAudioTranscriptionProvider().isConfigured
        }
    }

    static func resolved(
        storedRawValue: String?,
        bundleRawValue: String?
    ) -> VoiceListenProvider {
        if let storedRawValue,
           let stored = VoiceListenProvider(rawValue: storedRawValue.lowercased()) {
            return stored
        }
        if let bundleRawValue,
           let bundle = VoiceListenProvider(rawValue: bundleRawValue.lowercased()) {
            return bundle
        }
        return .apple
    }

    static func fromUserDefaults() -> VoiceListenProvider {
        resolved(
            storedRawValue: UserDefaults.standard.string(
                forKey: CompanionManager.listenPreferenceKey
            ),
            bundleRawValue: AppBundleConfiguration.stringValue(
                forKey: "VoiceTranscriptionProvider"
            )
        )
    }
}

enum VoiceSpeakProvider: String, CaseIterable, Hashable {
    case macOS = "macos"
    case elevenLabs = "elevenlabs"

    var displayName: String {
        switch self {
        case .macOS: return "Mac"
        case .elevenLabs: return "ElevenLabs"
        }
    }

    var pickerHint: String {
        switch self {
        case .macOS:
            return "System voice. Works offline."
        case .elevenLabs:
            return "Via your Worker. The Worker must be running."
        }
    }

    static func resolved(
        storedRawValue: String?,
        bundleRawValue: String?
    ) -> VoiceSpeakProvider {
        if let storedRawValue,
           let stored = VoiceSpeakProvider(rawValue: storedRawValue.lowercased()) {
            return stored
        }
        if let bundleRawValue,
           let bundle = VoiceSpeakProvider(rawValue: bundleRawValue.lowercased()) {
            return bundle
        }
        return .macOS
    }

    static func fromUserDefaults() -> VoiceSpeakProvider {
        resolved(
            storedRawValue: UserDefaults.standard.string(
                forKey: CompanionManager.speakPreferenceKey
            ),
            bundleRawValue: AppBundleConfiguration.stringValue(
                forKey: "VoiceSpeakProvider"
            )
        )
    }
}
