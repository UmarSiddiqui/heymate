//
//  UISoundPlayer.swift
//  leanring-buddy
//
//  Subtle interaction sounds (HeyClicky ships a similar set of UI blips;
//  these are clean-room synthesized tones bundled as asset-catalog data
//  sets — see scripts/generate_ui_sounds.py). Playback is intentionally
//  minimal: short AVAudioPlayer instances, pruned after each play, gated by
//  the user's sounds preference.
//

import AppKit
import AVFoundation

@MainActor
final class UISoundPlayer {

    static let shared = UISoundPlayer()

    enum Sound: String {
        /// Soft rising blip when push-to-talk opens the mic.
        case listenStart = "ListenStart"
        /// Gentle two-note chime when the spoken response starts playing.
        case responseReady = "ResponseReady"
    }

    /// Strong references so players aren't deallocated mid-playback; finished
    /// entries are pruned on every call.
    private var activePlayers: [AVAudioPlayer] = []

    func play(_ sound: Sound) {
        guard isSoundEnabled else { return }

        activePlayers.removeAll { !$0.isPlaying }

        guard let asset = NSDataAsset(name: sound.rawValue),
              let player = try? AVAudioPlayer(data: asset.data) else {
            print("🔇 UISoundPlayer: missing or unplayable sound asset \(sound.rawValue)")
            return
        }
        player.volume = 0.5
        activePlayers.append(player)
        player.play()
    }

    private var isSoundEnabled: Bool {
        UserDefaults.standard.object(forKey: CompanionManager.uiSoundPreferenceKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: CompanionManager.uiSoundPreferenceKey)
    }
}
