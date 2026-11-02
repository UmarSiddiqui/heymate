//
//  SpeechStylePreferences.swift
//  HeyMate
//
//  How fast HeyMate talks, and which on-device voice it uses. Speed applies
//  to local voice and ElevenLabs; the voice choice applies to
//  the on-device model, whose voices ship with it for free.
//

import Foundation

nonisolated enum SpeechStylePreferences {
    static let speedKey = "speechSpeedMultiplier"
    static let onDeviceVoiceKey = "onDeviceVoiceName"

    static let speedChoices: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5]

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

    /// The selected Phonon voice, or the model's default.
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

/// Curated Phonon voices. IDs match the pinned model's voice catalog.
nonisolated struct OnDeviceVoiceOption: Identifiable, Equatable {
    let id: String
    let name: String
    let character: String
    let symbol: String
    static let defaultID = "Zoey"
    static let all: [OnDeviceVoiceOption] = [
        .init(id: "Zoey", name: "Zoey", character: "Default", symbol: "heart.fill"),
        .init(id: "Freya", name: "Freya", character: "English", symbol: "sun.max.fill"),
        .init(id: "Hadley", name: "Hadley", character: "English", symbol: "moon.fill"),
        .init(id: "Harper", name: "Harper", character: "English", symbol: "cloud.fill"),
        .init(id: "Imogen", name: "Imogen", character: "English", symbol: "sparkle"),
        .init(id: "Easton", name: "Easton", character: "English", symbol: "leaf.fill"),
        .init(id: "Hugh", name: "Hugh", character: "English", symbol: "mountain.2.fill"),
        .init(id: "Miles", name: "Miles", character: "English", symbol: "music.note"),
        .init(id: "Bryony", name: "Bryony", character: "English", symbol: "drop.fill"),
        .init(id: "Preston", name: "Preston", character: "English", symbol: "wind")
    ]
}
