//
//  HeyMateCue.swift
//  HeyMate
//
//  One cue, one call. A cue is an interaction sound and the motion that
//  rides on it: `HeyMateCue.shared.fire(.jobDone, subject: run.id)` plays
//  the sound and publishes the cue, and views tagged with `.cueMotion(...)`
//  sample `CueChoreography` from the moment it fired. Sound and motion are
//  never triggered separately, so they can't drift apart.
//
//  The sound still goes through UISoundPlayer, which owns the sounds
//  preference, silent mode and quiet hours. The motion does not: with
//  sounds off, the motion still plays.
//

import Combine
import Foundation

/// One fired cue.
struct HeyMateCueEvent: Equatable, Identifiable {
    let id: UUID
    let sound: UISoundPlayer.Sound
    /// What the cue is about — a message, run, mate or permission id — so
    /// only that row reacts. Nil means "whatever shows this cue".
    let subject: String?
    let firedAt: Date
    /// A reply that arrived whole (not streamed in) reveals its words one
    /// by one on the pop; a streamed reply has already been read as it came.
    var revealsText: Bool = false

    /// True when a view tagged for `sound` and `subject` should play this.
    /// An untagged view (subject nil) reacts to every cue of its sound. A
    /// view for something created at `bornAt` (a chat message) only reacts
    /// to a cue fired with it, so the bubble that was just sent pops and
    /// the one above it doesn't.
    func matches(_ sounds: [UISoundPlayer.Sound], subject viewSubject: String?, bornAt: Date? = nil) -> Bool {
        guard sounds.contains(sound) else { return false }
        if let bornAt, abs(firedAt.timeIntervalSince(bornAt)) > Self.birthWindow { return false }
        guard let viewSubject else { return true }
        return subject == viewSubject
    }

    /// How close a cue and the thing it announces have to be created.
    static let birthWindow: TimeInterval = 1

    func elapsed(at date: Date) -> TimeInterval {
        date.timeIntervalSince(firedAt)
    }

    var duration: TimeInterval { CueChoreography.duration(for: sound) }
}

@MainActor
final class HeyMateCue: ObservableObject {

    static let shared = HeyMateCue()

    /// Cues still playing, newest last. Kept as a short list rather than a
    /// single latest value because a view often appears a beat after its
    /// cue fired (the reply bubble is inserted after `cue(.messageReceived)`),
    /// and two cues can fire in one tick (a send and a job start). A view
    /// that appears mid-cue joins it at the right elapsed time, so it stays
    /// on the sound's beat.
    @Published private(set) var recentCues: [HeyMateCueEvent] = []

    /// The newest cue, for observers that only care about the latest one.
    var lastCue: HeyMateCueEvent? { recentCues.last }

    private let now: () -> Date
    private let playSound: @MainActor (UISoundPlayer.Sound) -> Void

    init(
        now: @escaping () -> Date = Date.init,
        playSound: @escaping @MainActor (UISoundPlayer.Sound) -> Void = { @MainActor sound in UISoundPlayer.shared.play(sound) }
    ) {
        self.now = now
        self.playSound = playSound
    }

    /// Plays the sound and publishes its motion. `subject` names what the
    /// cue is about so only that element reacts (pass the message, run or
    /// mate id where several could be on screen).
    @discardableResult
    func fire(_ sound: UISoundPlayer.Sound, subject: String? = nil, revealsText: Bool = false) -> HeyMateCueEvent {
        let event = HeyMateCueEvent(
            id: UUID(), sound: sound, subject: subject, firedAt: now(), revealsText: revealsText
        )
        playSound(sound)
        let firedAt = event.firedAt
        var cues = recentCues.filter { $0.elapsed(at: firedAt) < Self.retention }
        cues.append(event)
        if cues.count > Self.maximumRecentCues {
            cues.removeFirst(cues.count - Self.maximumRecentCues)
        }
        recentCues = cues
        return event
    }

    /// Bursts (ten jobs finishing at once) don't need more than this many
    /// in flight; UISoundPlayer plays one sound for them anyway.
    static let maximumRecentCues = 12

    /// How long a cue stays joinable. Longer than any choreography (the
    /// hatching is 3.5 s; a long reply reveals for up to ~1.6 s), so a view
    /// can still find its cue; past its own duration a view ignores it.
    static let retention: TimeInterval = 4

    /// A finished reply that ends by asking something back.
    nonisolated static func asksBack(_ reply: String) -> Bool {
        reply.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
    }

    /// The newest still-playing cue a view should join.
    func activeCue(
        for sounds: [UISoundPlayer.Sound],
        subject: String?,
        bornAt: Date? = nil,
        at date: Date,
        duration: ((HeyMateCueEvent) -> TimeInterval)? = nil
    ) -> HeyMateCueEvent? {
        recentCues.last { cue in
            let length = duration?(cue) ?? cue.duration
            return cue.matches(sounds, subject: subject, bornAt: bornAt) && cue.elapsed(at: date) < length
        }
    }
}

extension CompanionManager {
    /// `cue(.jobDone, subject: runID.uuidString)` — the one call a moment
    /// makes to get its sound and its motion.
    @discardableResult
    func cue(_ sound: UISoundPlayer.Sound, subject: String? = nil, revealsText: Bool = false) -> HeyMateCueEvent {
        HeyMateCue.shared.fire(sound, subject: subject, revealsText: revealsText)
    }
}
