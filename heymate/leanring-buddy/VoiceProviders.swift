//
//  VoiceProviders.swift
//  leanring-buddy
//
//  Listen (speech-to-text) and Speak (text-to-speech) choices for the
//  Models settings page. Independent of the brain (Claude / OpenCode).
//
//  Three tiers each way:
//  - ElevenLabs: best quality, needs the user's own ElevenLabs key
//  - On-device: Parakeet / Kokoro, an optional one-time download
//  - Mac: Apple Speech / the best installed Mac voice, always there, the fallback
//

import Foundation

enum VoiceListenProvider: String, CaseIterable, Hashable {
    case elevenLabs = "elevenlabs"
    case onDevice = "parakeet"
    case apple

    var displayName: String {
        switch self {
        case .elevenLabs: return "ElevenLabs"
        case .onDevice: return "On-device"
        case .apple: return "Mac"
        }
    }

    var isSelectable: Bool {
        switch self {
        case .elevenLabs:
            return ElevenLabsCredentials.isAvailable
        case .onDevice:
            return ParakeetEngine.modelsAreInstalled()
        case .apple:
            return true
        }
    }

    /// Stored values from builds that offered AssemblyAI or OpenAI. Both
    /// were cloud picks, so they land on the cloud option; the factory falls
    /// back further if no ElevenLabs key is set.
    private static let retiredRawValues: Set<String> = ["assemblyai", "openai"]

    static func resolved(
        storedRawValue: String?,
        bundleRawValue: String?
    ) -> VoiceListenProvider {
        for candidateRawValue in [storedRawValue, bundleRawValue] {
            guard let normalizedRawValue = candidateRawValue?.lowercased() else { continue }
            if let provider = VoiceListenProvider(rawValue: normalizedRawValue) {
                return provider
            }
            if retiredRawValues.contains(normalizedRawValue) {
                return .elevenLabs
            }
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
    case elevenLabs = "elevenlabs"
    case onDevice = "kokoro"
    /// Raw value kept from earlier builds, so stored choices
    /// carry over. It picks the best installed voice automatically.
    case macOS = "macos"

    var displayName: String {
        switch self {
        case .elevenLabs: return "ElevenLabs"
        case .onDevice: return "On-device"
        case .macOS: return "Mac voice"
        }
    }

    var isSelectable: Bool {
        switch self {
        case .elevenLabs:
            return ElevenLabsCredentials.isAvailable
        case .onDevice:
            return KokoroEngine.modelsAreInstalled()
        case .macOS:
            return true
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
