//
//  SpeechStylePreferences.swift
//  HeyMate
//
//  How fast HeyMate talks, and which on-device voice it uses. Speed applies
//  to every voice (on-device, ElevenLabs, Mac); the voice choice applies to
//  the on-device model, whose voices ship with it for free.
//

import Foundation

nonisolated enum SpeechStylePreferences {
    static let speedKey = "speechSpeedMultiplier"
    static let onDeviceVoiceKey = "onDeviceVoiceName"

    static let speedChoices: [Double] = [0.75, 1.0, 1.25, 1.5]

    static var speed: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: speedKey)
            return stored > 0 ? clampedSpeed(stored) : 1.0
        }
        set { UserDefaults.standard.set(clampedSpeed(newValue), forKey: speedKey) }
    }

    static func clampedSpeed(_ value: Double) -> Double {
        min(max(value, 0.5), 2.0)
    }

    static func speedLabel(_ value: Double) -> String {
        let text = value == value.rounded() ? String(format: "%.0f", value) : String(format: "%g", value)
        return text + "×"
    }

    /// The selected Kokoro voice, or the model's default.
    static var onDeviceVoice: String {
        get {
            let stored = UserDefaults.standard.string(forKey: onDeviceVoiceKey) ?? ""
            return OnDeviceVoiceOption.all.contains { $0.id == stored } ? stored : OnDeviceVoiceOption.defaultID
        }
        set { UserDefaults.standard.set(newValue, forKey: onDeviceVoiceKey) }
    }

    /// AVSpeechUtterance rate for a speed multiplier. Apple's scale is not
    /// linear in perceived speed, so the default rate is scaled and kept
    /// inside the range the synthesizer accepts.
    static func macRate(defaultRate: Float, minimum: Float, maximum: Float, speed: Double = speed) -> Float {
        min(max(defaultRate * Float(speed), minimum), maximum)
    }

    /// ElevenLabs accepts 0.7–1.2.
    static func elevenLabsSpeed(_ speed: Double = speed) -> Double {
        min(max(speed, 0.7), 1.2)
    }
}

/// A curated handful of Kokoro's built-in voices, described the way people
/// pick voices: by how they sound.
nonisolated struct OnDeviceVoiceOption: Identifiable, Equatable {
    let id: String
    let name: String
    let character: String
    let symbol: String

    static let defaultID = "af_heart"

    static let all: [OnDeviceVoiceOption] = [
        .init(id: "af_heart", name: "Heart", character: "Warm default", symbol: "heart.fill"),
        .init(id: "af_bella", name: "Bella", character: "Bright", symbol: "sun.max.fill"),
        .init(id: "af_nicole", name: "Nicole", character: "Soft & close", symbol: "moon.fill"),
        .init(id: "af_sky", name: "Sky", character: "Light & airy", symbol: "cloud.fill"),
        .init(id: "af_nova", name: "Nova", character: "Crisp", symbol: "sparkle"),
        .init(id: "am_michael", name: "Michael", character: "Steady", symbol: "leaf.fill"),
        .init(id: "am_adam", name: "Adam", character: "Deep", symbol: "mountain.2.fill"),
        .init(id: "am_puck", name: "Puck", character: "Lively", symbol: "music.note"),
        .init(id: "bf_emma", name: "Emma", character: "British, clear", symbol: "drop.fill"),
        .init(id: "bm_george", name: "George", character: "British, calm", symbol: "wind")
    ]
}
