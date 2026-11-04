//
//  OnboardingAudio.swift
//  HeyMate
//
//  Sound for the welcome tour: the scripted lines pre-rendered in the
//  default on-device voice, and a quiet ambient bed under the whole tour.
//
//  The clips mean the very first words a new person hears are HeyMate's
//  own voice, instantly, while the speaking model is still being prepared
//  and the listening model downloads. A line's clip is found by the hash of
//  its exact text, so editing a line just falls back to live speech until
//  `scripts/render-onboarding-audio.py` renders it again.
//

import AppKit
import AVFoundation
import Combine
import CryptoKit

@MainActor
final class OnboardingVoiceClips {
    /// The on-device voice the clips were rendered in.
    static let voice = "Zoey"

    private var player: AVAudioPlayer?

    /// Asset name for `line`. Must match the render script.
    nonisolated static func assetName(for line: String) -> String {
        let digest = SHA256.hash(data: Data(line.utf8))
        return "OnboardingVoice-" + digest.prefix(5).map { String(format: "%02x", $0) }.joined()
    }

    /// Clips stand in for the on-device voice only: someone who picked the
    /// Mac voice or ElevenLabs hears that instead. Once the model is ready,
    /// a different on-device voice speaks live too.
    static func isPreferred(for provider: VoiceSpeakProvider) -> Bool {
        guard provider == .onDevice else { return false }
        return SpeechStylePreferences.onDeviceVoice == voice
            || !OnDeviceVoiceModelStore.shared.speakState.isInstalled
    }

    /// Starts `line`'s clip. False when there is none.
    @discardableResult
    func start(_ line: String) -> Bool {
        stop()
        guard let asset = NSDataAsset(name: Self.assetName(for: line)),
              let player = try? AVAudioPlayer(data: asset.data) else { return false }
        player.enableRate = true
        player.rate = Float(SpeechStylePreferences.speed)
        player.prepareToPlay()
        guard player.play() else { return false }
        self.player = player
        return true
    }

    /// Plays `line`'s clip to the end. False when there is none.
    func play(_ line: String) async -> Bool {
        guard start(line), let player else { return false }
        while player.isPlaying {
            if Task.isCancelled {
                player.stop()
                break
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        return true
    }

    var isPlaying: Bool { player?.isPlaying == true }

    func stop() {
        player?.stop()
        player = nil
    }
}

/// A soft, slow pad that loops under the tour. It ducks while HeyMate
/// talks and steps aside entirely while the tour is listening, so it
/// never ends up in a transcript or trips the mic check.
@MainActor
final class OnboardingMusic: ObservableObject {
    static let mutedKey = "heymate.onboarding.musicMuted"
    private static let restingVolume: Float = 0.22
    private static let duckedVolume: Float = 0.08

    @Published private(set) var isMuted = UserDefaults.standard.bool(forKey: OnboardingMusic.mutedKey)

    private var player: AVAudioPlayer?
    private var isListening = false
    private var isDucked = false
    private var pauseTask: Task<Void, Never>?

    func start() {
        guard player == nil, let asset = NSDataAsset(name: "OnboardingMusic"),
              let player = try? AVAudioPlayer(data: asset.data) else { return }
        player.numberOfLoops = -1
        player.volume = 0
        player.prepareToPlay()
        self.player = player
        apply(fade: 3)
    }

    /// Listening steps get silence; everything else gets the music back.
    func setListening(_ listening: Bool) {
        guard listening != isListening else { return }
        isListening = listening
        apply(fade: listening ? 0.8 : 2.5)
    }

    func setDucked(_ ducked: Bool) {
        guard ducked != isDucked else { return }
        isDucked = ducked
        apply(fade: ducked ? 0.4 : 1.6)
    }

    func toggleMuted() {
        isMuted.toggle()
        UserDefaults.standard.set(isMuted, forKey: Self.mutedKey)
        apply(fade: 0.8)
    }

    func stop(fade: TimeInterval = 1.5) {
        guard let player else { return }
        pauseTask?.cancel()
        player.setVolume(0, fadeDuration: fade)
        self.player = nil
        Task {
            try? await Task.sleep(for: .seconds(fade + 0.1))
            player.stop()
        }
    }

    private var targetVolume: Float {
        if isMuted || isListening { return 0 }
        return isDucked ? Self.duckedVolume : Self.restingVolume
    }

    private func apply(fade: TimeInterval) {
        guard let player else { return }
        pauseTask?.cancel()
        let target = targetVolume
        if target > 0 {
            if !player.isPlaying { player.play() }
            player.setVolume(target, fadeDuration: fade)
        } else {
            player.setVolume(0, fadeDuration: fade)
            // Paused once silent so a listening step has a truly quiet room.
            pauseTask = Task { [weak player] in
                try? await Task.sleep(for: .seconds(fade + 0.1))
                guard !Task.isCancelled else { return }
                player?.pause()
            }
        }
    }
}
