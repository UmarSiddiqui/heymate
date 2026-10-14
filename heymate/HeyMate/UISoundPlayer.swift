//
//  UISoundPlayer.swift
//  HeyMate
//
//  Interaction sounds imported from the selected HeyMate sound set and
//  bundled as Apple Lossless asset-catalog data sets. Playback is
//  intentionally minimal: short AVAudioPlayer instances, pruned after each
//  play, gated by the user's sounds preference.
//

import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class UISoundPlayer {

    static let shared = UISoundPlayer()

    enum Sound: String, CaseIterable {
        /// Soft rising pluck when push-to-talk opens the mic.
        case listenStart = "ListenStart"
        /// Warm fifth when the spoken response starts playing.
        case responseReady = "ResponseReady"
        /// Low thump with a lifting pluck when the notch is opened on purpose.
        case panelOpen = "PanelOpen"
        /// One soft tap echoing away when a deliberately opened notch closes.
        case panelClose = "PanelClose"
        /// Upward whoosh-pluck when a typed message goes out.
        case messageSent = "MessageSent"
        /// Two bright notes with a little echo when a typed reply lands.
        case messageReceived = "MessageReceived"
        /// A leap up a fifth — "hm?" — when HeyMate asks you something back.
        case question = "Question"
        /// Held hum when a job asks permission for a single tool call.
        case permissionAsk = "PermissionAsk"
        /// Quick dip then pop when something goes wrong.
        case surprised = "Surprised"
        /// A note and its octave when you approve something.
        case thumbsUp = "ThumbsUp"
        /// Rising sweep over a low thump when a job begins.
        case jobStarted = "JobStarted"
        /// Low two-tone call with a high glint when a job waits on you.
        case jobNeedsYou = "JobNeedsYou"
        /// Rising fourth that rings out when a job finishes.
        case jobDone = "JobDone"
        /// One deep long tone when a job is put away.
        case jobClosed = "JobClosed"
        /// Chirp landing on a low thump when something is added.
        case levelUp = "LevelUp"
        /// Long falling slide when something is removed.
        case levelDown = "LevelDown"
        /// Low pulses stepping up, for startup.
        case boot = "Boot"
        /// Airy rising arpeggio with sparkles when home first appears.
        case homeReveal = "HomeReveal"
        /// Rumble, cracks, then a chime when a new mate is born.
        case hatching = "Hatching"
    }

    /// Both mean "your answer is here". A typed reply that is also spoken
    /// should make one sound, not two, so whichever plays first wins.
    private static let answerCues: Set<Sound> = [.responseReady, .messageReceived]
    private static let answerCueWindow: TimeInterval = 3
    private var lastAnswerCueAt: Date?

    /// The sound a job event makes, or nil for the chatter in between.
    nonisolated static func sound(for event: AgentEvent) -> Sound? {
        switch event {
        case .started: return .jobStarted
        case .planReady: return .jobNeedsYou
        case .approvalRequested: return .permissionAsk
        case .failed: return .surprised
        case .finished: return .jobDone
        case .sessionIdentified, .tool, .text: return nil
        }
    }

    /// Decoded asset bytes, read once. Loading the data set from the asset
    /// catalog on the first press is what made the first blip late.
    private var soundData: [Sound: Data] = [:]

    /// Strong references so players aren't deallocated mid-playback; finished
    /// entries are pruned on every call. Keyed by sound so a burst (say, three
    /// mates created at once) plays one cue instead of a pile-up.
    private var activePlayers: [(sound: Sound, player: AVAudioPlayer)] = []

    /// Volume for expand/collapse of rows, popovers, panes and hover-peeks:
    /// the same open/close gesture, softer than a deliberate notch open.
    static let disclosureVolume: Float = 0.28

    /// Open or close sound for anything that expands or collapses.
    func playDisclosure(isOpen: Bool) {
        play(isOpen ? .panelOpen : .panelClose, volume: Self.disclosureVolume)
    }

    func play(_ sound: Sound, volume: Float = 0.5) {
        guard isSoundEnabled else { return }

        if Self.answerCues.contains(sound) {
            if let last = lastAnswerCueAt, Date().timeIntervalSince(last) < Self.answerCueWindow { return }
            lastAnswerCueAt = Date()
        }

        activePlayers.removeAll { !$0.player.isPlaying }
        guard !activePlayers.contains(where: { $0.sound == sound }) else { return }

        guard let data = data(for: sound),
              let player = try? AVAudioPlayer(data: data) else {
            HeyMateLog.log("🔇 UISoundPlayer: missing or unplayable sound asset \(sound.rawValue)")
            return
        }
        player.volume = volume
        activePlayers.append((sound, player))
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
        guard !QuietPolicy.shouldSilenceAnnouncements() else { return false }
        return UserDefaults.standard.object(forKey: CompanionManager.uiSoundPreferenceKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: CompanionManager.uiSoundPreferenceKey)
    }
}

extension View {
    /// Plays the open or close sound whenever `isOpen` flips: disclosure
    /// rows, popovers, side panes.
    func disclosureSound(_ isOpen: Bool) -> some View {
        onChange(of: isOpen) { _, open in
            UISoundPlayer.shared.playDisclosure(isOpen: open)
        }
    }
}

extension Binding where Value == Bool {
    /// The same binding, playing the open or close sound when a control
    /// (say, a `DisclosureGroup` chevron) flips it.
    func withDisclosureSound() -> Binding<Bool> {
        Binding(
            get: { wrappedValue },
            set: { newValue in
                if newValue != wrappedValue {
                    UISoundPlayer.shared.playDisclosure(isOpen: newValue)
                }
                wrappedValue = newValue
            }
        )
    }
}
