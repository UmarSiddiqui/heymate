//
//  UISoundPlayer.swift
//  HeyMate
//
//  Subtle interaction sounds (synthesized tones bundled as asset-catalog data
//  sets — see scripts/generate_ui_sounds.py). Playback is intentionally
//  minimal: short AVAudioPlayer instances, pruned after each play, gated by
//  the user's sounds preference.
//

import AppKit
import AVFoundation

@MainActor
final class UISoundPlayer {

    static let shared = UISoundPlayer()

    enum Sound: String, CaseIterable {
        /// Soft rising blip when push-to-talk opens the mic.
        case listenStart = "ListenStart"
        /// Gentle two-note chime when the spoken response starts playing.
        case responseReady = "ResponseReady"
        /// Two quick rising steps when a job begins.
        case jobStarted = "JobStarted"
        /// A small rising arpeggio when a job finishes.
        case jobDone = "JobDone"
        /// Two soft falling notes, twice, when a job waits on you.
        case jobNeedsYou = "JobNeedsYou"
        /// A short falling blip when a typed message goes out.
        case messageSent = "MessageSent"
    }

    /// The sound a job event makes, or nil for the chatter in between.
    nonisolated static func sound(for event: AgentEvent) -> Sound? {
        switch event {
        case .started: return .jobStarted
        case .planReady, .approvalRequested, .failed: return .jobNeedsYou
        case .finished: return .jobDone
        case .sessionIdentified, .tool, .text: return nil
        }
    }

    /// Decoded asset bytes, read once. Loading the data set from the asset
    /// catalog on the first press is what made the first blip late.
    private var soundData: [Sound: Data] = [:]

    /// Strong references so players aren't deallocated mid-playback; finished
    /// entries are pruned on every call.
    private var activePlayers: [AVAudioPlayer] = []

    func play(_ sound: Sound) {
        guard isSoundEnabled else { return }

        activePlayers.removeAll { !$0.isPlaying }

        guard let data = data(for: sound),
              let player = try? AVAudioPlayer(data: data) else {
            HeyMateLog.log("🔇 UISoundPlayer: missing or unplayable sound asset \(sound.rawValue)")
            return
        }
        player.volume = 0.5
        activePlayers.append(player)
        player.play()
    }

    /// Loads every sound and primes the audio output so the first blip of
    /// a session plays on time instead of after the device wakes.
    func warmUp() {
        for sound in Sound.allCases {
            guard let data = data(for: sound), let player = try? AVAudioPlayer(data: data) else { continue }
            player.prepareToPlay()
        }
    }

    private func data(for sound: Sound) -> Data? {
        if let cached = soundData[sound] { return cached }
        guard let asset = NSDataAsset(name: sound.rawValue) else { return nil }
        soundData[sound] = asset.data
        return asset.data
    }

    private var isSoundEnabled: Bool {
        guard !SilentModePreferences.isEnabled else { return false }
        return UserDefaults.standard.object(forKey: CompanionManager.uiSoundPreferenceKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: CompanionManager.uiSoundPreferenceKey)
    }
}
