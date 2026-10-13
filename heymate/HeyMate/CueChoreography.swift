//
//  CueChoreography.swift
//  HeyMate
//
//  The motion half of every interaction sound, as pure timing math. Each
//  sound gets a small choreography — which parts of the UI move, and how —
//  timed against the rendered sound file: motion starts at t = 0 with the
//  sound, and its biggest moment (overshoot, pop, flash) lands on the
//  sound's peak. No SwiftUI here, so the timing is unit-testable; the views
//  in CueMotionViews.swift just sample these curves while a cue plays.
//
//  Matte and small on purpose: 4–12 pt of travel, 0.92–1.08 scale, mostly
//  under 600 ms. Hatching is the one showpiece.
//

import CoreGraphics
import Foundation

/// Which piece of a cue's choreography a view is. A sound pairs with a
/// main element (the bubble, the buddy, the job row) and sometimes a prop
/// that springs out of it (a paper plane, a "?", a tapback badge) or a
/// staggered row of items (waveform bars, home tiles, hatching cracks).
nonisolated enum CuePart: Hashable, Sendable {
    /// The element the cue is about.
    case subject
    /// A small symbolic object that springs out of the subject.
    case prop
    /// One of a staggered set (bars, tiles, cracks), counted from 0.
    case item(Int)
    /// One of a few tiny white sparkles, counted from 0.
    case sparkle(Int)
}

/// One sampled moment of a part's motion. Identity is "at rest".
nonisolated struct CueFrame: Equatable, Sendable {
    var scale: CGFloat = 1
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    /// Degrees.
    var rotation: Double = 0
    var opacity: Double = 1
    /// 0–1 extra brightness for glows and pulses.
    var glow: Double = 0
    /// 0–1 drawing progress for stroked glyphs (the done checkmark) and
    /// sweeps (the job-start shimmer).
    var progress: Double = 1
    /// False at rest. Props and sparkles draw only while their cue plays.
    var isPlaying = false

    static let identity = CueFrame()
}

/// Sound timing measured from the rendered files.
nonisolated struct CueSoundTiming: Equatable, Sendable {
    /// The loudest moment, in seconds from the start.
    let peak: TimeInterval
    /// When the sound drops below about −30 dB.
    let audible: TimeInterval
    /// Other beats the motion is allowed to sync to (a second note, a
    /// crack in the hatching rumble). The peak always counts as a beat.
    let beats: [TimeInterval]

    init(peak: TimeInterval, audible: TimeInterval, beats: [TimeInterval] = []) {
        self.peak = peak
        self.audible = audible
        self.beats = beats
    }
}

/// A keyframed curve. Between keys it eases in and out (smoothstep), so a
/// key is always a held moment — an overshoot key is literally the
/// overshoot. Before the first key it holds the first value; after the
/// last, the last.
nonisolated struct CueTrack: Sendable {
    let keys: [(time: TimeInterval, value: Double)]

    init(_ keys: [(TimeInterval, Double)]) {
        self.keys = keys.map { (time: $0.0, value: $0.1) }
    }

    func value(at time: TimeInterval) -> Double {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        for index in 1..<keys.count where time <= keys[index].time {
            let from = keys[index - 1]
            let to = keys[index]
            let span = to.time - from.time
            guard span > 0 else { return to.value }
            let linear = (time - from.time) / span
            let eased = linear * linear * (3 - 2 * linear)
            return from.value + (to.value - from.value) * eased
        }
        return last.value
    }

    var endTime: TimeInterval { keys.last?.time ?? 0 }
}

/// Every track a part can animate. Missing tracks stay at rest.
nonisolated struct CueMotion: Sendable {
    var scale: CueTrack?
    var scaleX: CueTrack?
    var scaleY: CueTrack?
    var offsetX: CueTrack?
    var offsetY: CueTrack?
    var rotation: CueTrack?
    var opacity: CueTrack?
    var glow: CueTrack?
    var progress: CueTrack?

    private var tracks: [CueTrack] {
        [scale, scaleX, scaleY, offsetX, offsetY, rotation, opacity, glow, progress].compactMap { $0 }
    }

    func frame(at time: TimeInterval) -> CueFrame {
        var frame = CueFrame.identity
        if let scale { frame.scale = scale.value(at: time) }
        if let scaleX { frame.scaleX = scaleX.value(at: time) }
        if let scaleY { frame.scaleY = scaleY.value(at: time) }
        if let offsetX { frame.offsetX = offsetX.value(at: time) }
        if let offsetY { frame.offsetY = offsetY.value(at: time) }
        if let rotation { frame.rotation = rotation.value(at: time) }
        if let opacity { frame.opacity = opacity.value(at: time) }
        if let glow { frame.glow = glow.value(at: time) }
        if let progress { frame.progress = progress.value(at: time) }
        return frame
    }

    var endTime: TimeInterval { tracks.map(\.endTime).max() ?? 0 }

    /// Every keyed moment, for checking that an accent is a real key.
    var keyTimes: [TimeInterval] { tracks.flatMap { $0.keys.map(\.time) } }

    /// Under Reduce Motion a part keeps only where its opacity starts and
    /// ends (a bubble still fades in, a closing card still fades out) and
    /// gets there with `DS.Animation.reducedMotionFade`'s easeInOut over
    /// 0.15 s. Nothing moves; glows settle straight to their end value.
    func reducedMotionFrame(at time: TimeInterval) -> CueFrame {
        let fade = CueChoreography.reducedMotionFadeDuration
        let startOpacity = opacity?.value(at: 0) ?? 1
        let endOpacity = opacity?.value(at: endTime) ?? 1
        var frame = CueFrame.identity
        frame.opacity = CueTrack([(0, startOpacity), (fade, endOpacity)]).value(at: time)
        frame.glow = glow?.value(at: endTime) ?? 0
        frame.progress = progress?.value(at: endTime) ?? 1
        return frame
    }
}

/// Where a cue's biggest moment is, for the sync test and for the screen
/// recordings that check it.
nonisolated struct CueAccent: Sendable {
    let part: CuePart
    let time: TimeInterval
}

nonisolated enum CueChoreography {

    /// Matches `DS.Animation.fast`, the duration of `reducedMotionFade`.
    static let reducedMotionFadeDuration: TimeInterval = 0.15

    // MARK: - Sound timing

    /// Peak and audible tail of every sound, measured from the rendered
    /// files. Extra beats come from the per-sound motion spec; the ones
    /// marked "est." are read off the sound's shape and should be checked
    /// against a screen recording.
    static func timing(for sound: UISoundPlayer.Sound) -> CueSoundTiming {
        switch sound {
        case .listenStart: return CueSoundTiming(peak: 0.071, audible: 0.599)
        case .responseReady: return CueSoundTiming(peak: 0.112, audible: 0.765)
        case .panelOpen: return CueSoundTiming(peak: 0.015, audible: 0.509, beats: [0.060])
        case .panelClose: return CueSoundTiming(peak: 0.011, audible: 0.604, beats: [0.0])
        case .messageSent: return CueSoundTiming(peak: 0.135, audible: 0.478)
        // Second note ~75 ms (spec), peaking at 120.
        case .messageReceived: return CueSoundTiming(peak: 0.120, audible: 0.548, beats: [0.075])
        case .question: return CueSoundTiming(peak: 0.202, audible: 0.787, beats: [0.090])
        case .permissionAsk: return CueSoundTiming(peak: 0.194, audible: 0.814)
        case .surprised: return CueSoundTiming(peak: 0.081, audible: 0.525)
        // First note est. ~70 ms; the octave is the peak.
        case .thumbsUp: return CueSoundTiming(peak: 0.182, audible: 0.529, beats: [0.070])
        case .jobStarted: return CueSoundTiming(peak: 0.047, audible: 0.407)
        // Two calls, at 0 and ~500 ms; the second one's top note peaks.
        case .jobNeedsYou: return CueSoundTiming(peak: 0.704, audible: 1.081, beats: [0.060, 0.560])
        case .jobDone: return CueSoundTiming(peak: 0.209, audible: 1.190)
        case .jobClosed: return CueSoundTiming(peak: 0.062, audible: 1.167, beats: [0.0])
        // Chirp, then the thump (~180 ms, spec) that peaks at 266.
        case .levelUp: return CueSoundTiming(peak: 0.266, audible: 0.682, beats: [0.180])
        case .levelDown: return CueSoundTiming(peak: 0.070, audible: 0.559, beats: [0.0])
        case .boot: return CueSoundTiming(peak: 0.762, audible: 1.384, beats: [0.0, 0.160, 0.360, 0.520, 0.740])
        // Three arpeggio notes, 80 ms apart, ending on the peak.
        case .homeReveal: return CueSoundTiming(peak: 0.392, audible: 1.130, beats: [0.232, 0.312])
        // Rumble, cracks at 1.6 and 2.1 s, burst 2.55–2.8 s.
        case .hatching: return CueSoundTiming(peak: 1.624, audible: 3.544, beats: [1.600, 2.100, 2.550, 2.800])
        }
    }

    /// The showpiece. Every other cue has to stay micro.
    static func isShowpiece(_ sound: UISoundPlayer.Sound) -> Bool {
        if case .hatching = sound { return true }
        return false
    }

    // MARK: - Accents

    static func accent(for sound: UISoundPlayer.Sound) -> CueAccent {
        switch sound {
        case .listenStart: return CueAccent(part: .subject, time: 0.071)
        case .responseReady: return CueAccent(part: .subject, time: 0.112)
        case .panelOpen: return CueAccent(part: .subject, time: 0.060)
        case .panelClose: return CueAccent(part: .subject, time: 0.0)
        case .messageSent: return CueAccent(part: .subject, time: 0.135)
        case .messageReceived: return CueAccent(part: .subject, time: 0.095)
        case .question: return CueAccent(part: .prop, time: 0.200)
        case .permissionAsk: return CueAccent(part: .subject, time: 0.194)
        case .surprised: return CueAccent(part: .subject, time: 0.081)
        case .thumbsUp: return CueAccent(part: .prop, time: 0.070)
        case .jobStarted: return CueAccent(part: .subject, time: 0.047)
        case .jobNeedsYou: return CueAccent(part: .subject, time: 0.560)
        case .jobDone: return CueAccent(part: .subject, time: 0.209)
        case .jobClosed: return CueAccent(part: .subject, time: 0.0)
        case .levelUp: return CueAccent(part: .subject, time: 0.240)
        case .levelDown: return CueAccent(part: .subject, time: 0.0)
        case .boot: return CueAccent(part: .subject, time: 0.740)
        case .homeReveal: return CueAccent(part: .item(2), time: 0.392)
        case .hatching: return CueAccent(part: .subject, time: 2.800)
        }
    }

    // MARK: - Choreography

    /// How long a cue keeps its views animating: the longest part, never
    /// shorter than the motion needs, never tied to the sound being heard
    /// (silent mode still plays the motion).
    static func duration(for sound: UISoundPlayer.Sound) -> TimeInterval {
        parts(for: sound).compactMap { motion(for: sound, part: $0)?.endTime }.max() ?? 0
    }

    /// Every part a sound animates, so tests and previews can walk them.
    static func parts(for sound: UISoundPlayer.Sound) -> [CuePart] {
        switch sound {
        case .listenStart: return [.subject] + (0..<listenBarCount).map { .item($0) }
        case .responseReady, .panelClose, .messageSent,
             .permissionAsk, .surprised, .jobStarted, .jobDone:
            return [.subject, .prop]
        case .question: return [.subject, .prop, .item(0)]
        case .panelOpen, .messageReceived, .jobNeedsYou, .jobClosed,
             .levelUp, .levelDown, .boot:
            return [.subject]
        case .thumbsUp: return [.prop]
        case .homeReveal: return (0..<homeTileCount).map { .item($0) } + (0..<sparkleCount).map { .sparkle($0) }
        case .hatching: return [.subject, .prop, .item(0), .item(1)] + (0..<sparkleCount).map { .sparkle($0) }
        }
    }

    static let listenBarCount = 5
    static let homeTileCount = 3
    static let sparkleCount = 4

    /// The motion for one part of one cue, or nil when that part sits
    /// still for this sound.
    static func motion(for sound: UISoundPlayer.Sound, part: CuePart) -> CueMotion? {
        switch sound {
        case .listenStart: return listenStart(part)
        case .responseReady: return responseReady(part)
        case .panelOpen: return panelOpen(part)
        case .panelClose: return panelClose(part)
        case .messageSent: return messageSent(part)
        case .messageReceived: return messageReceived(part)
        case .question: return question(part)
        case .permissionAsk: return permissionAsk(part)
        case .surprised: return surprised(part)
        case .thumbsUp: return thumbsUp(part)
        case .jobStarted: return jobStarted(part)
        case .jobNeedsYou: return jobNeedsYou(part)
        case .jobDone: return jobDone(part)
        case .jobClosed: return jobClosed(part)
        case .levelUp: return levelUp(part)
        case .levelDown: return levelDown(part)
        case .boot: return boot(part)
        case .homeReveal: return homeReveal(part)
        case .hatching: return hatching(part)
        }
    }

    /// The frame a part should show `elapsed` seconds after its cue fired.
    /// Past the end it is at rest, so a view can stop sampling.
    static func frame(
        for sound: UISoundPlayer.Sound,
        part: CuePart,
        elapsed: TimeInterval,
        reduceMotion: Bool
    ) -> CueFrame {
        guard let motion = motion(for: sound, part: part) else { return .identity }
        var frame = reduceMotion ? motion.reducedMotionFrame(at: elapsed) : motion.frame(at: elapsed)
        frame.isPlaying = true
        return frame
    }

    // MARK: Voice

    /// Mic dot scales 0.6 → 1.08 → 1 on the pluck; waveform bars rise in
    /// left to right, 30 ms apart.
    private static func listenStart(_ part: CuePart) -> CueMotion? {
        switch part {
        case .subject:
            return CueMotion(
                scale: CueTrack([(0, 0.6), (0.071, 1.08), (0.24, 1.0)]),
                opacity: CueTrack([(0, 0), (0.04, 1)])
            )
        case .item(let index):
            let start = Double(index) * 0.030
            return CueMotion(
                offsetY: CueTrack([(start, 4), (start + 0.16, 0)]),
                opacity: CueTrack([(start, 0), (start + 0.10, 1)])
            )
        default: return nil
        }
    }

    /// The buddy takes a soft breath; the caption (prop) is fully in by
    /// the peak, so its first word lands on the warm fifth.
    private static func responseReady(_ part: CuePart) -> CueMotion? {
        switch part {
        case .subject:
            return CueMotion(scale: CueTrack([(0, 1.0), (0.112, 1.05), (0.40, 1.0)]))
        case .prop:
            return CueMotion(
                offsetY: CueTrack([(0, 4), (0.112, 0)]),
                opacity: CueTrack([(0, 0), (0.112, 1)])
            )
        default: return nil
        }
    }

    // MARK: Panel

    /// The frame morph (NotchLayoutMath, 0.42 s) carries the open. The
    /// content fades up 6 pt starting 60 ms in, so the thump reads as the
    /// landing.
    private static func panelOpen(_ part: CuePart) -> CueMotion? {
        guard case .subject = part else { return nil }
        return CueMotion(
            offsetY: CueTrack([(0, 6), (0.060, 6), (0.42, 0)]),
            opacity: CueTrack([(0, 0), (0.060, 0), (0.30, 1)])
        )
    }

    /// Content dims in the first 120 ms (the tap), then the pill (prop)
    /// glows faintly twice, 130 ms apart, with the echoes.
    private static func panelClose(_ part: CuePart) -> CueMotion? {
        switch part {
        case .subject:
            return CueMotion(opacity: CueTrack([(0, 1), (0.12, 0)]))
        case .prop:
            return CueMotion(glow: CueTrack([
                (0.12, 0), (0.18, 0.35), (0.25, 0),
                (0.31, 0.22), (0.40, 0),
            ]))
        default: return nil
        }
    }

    // MARK: Chat

    /// The sent bubble slides up 8 pt and grows from 0.96, settling on the
    /// peak; a paper plane (prop) flies up and right 12 pt and fades.
    private static func messageSent(_ part: CuePart) -> CueMotion? {
        switch part {
        case .subject:
            return CueMotion(
                scale: CueTrack([(0, 0.96), (0.135, 1.0)]),
                offsetY: CueTrack([(0, 8), (0.135, 0)]),
                opacity: CueTrack([(0, 0), (0.06, 1)])
            )
        case .prop:
            return CueMotion(
                offsetX: CueTrack([(0, 0), (0.45, 12)]),
                offsetY: CueTrack([(0, 0), (0.45, -12)]),
                opacity: CueTrack([(0, 0), (0.06, 1), (0.20, 1), (0.45, 0)])
            )
        default: return nil
        }
    }

    /// The reply pops in, overshooting on the second note; its words then
    /// reveal at `wordRevealInterval(totalWords:)` (see `revealedWordCount`).
    private static func messageReceived(_ part: CuePart) -> CueMotion? {
        guard case .subject = part else { return nil }
        return CueMotion(
            scale: CueTrack([(0, 0.94), (0.095, 1.02), (0.22, 1.0)]),
            opacity: CueTrack([(0, 0), (0.06, 1)])
        )
    }

    /// ~35 ms per word, squeezed for long replies so the whole reveal
    /// stays under `maximumWordRevealSpan`.
    static let baseWordRevealInterval: TimeInterval = 0.035
    static let maximumWordRevealSpan: TimeInterval = 1.5

    static func wordRevealInterval(totalWords: Int) -> TimeInterval {
        guard totalWords > 1 else { return baseWordRevealInterval }
        return min(baseWordRevealInterval, maximumWordRevealSpan / Double(totalWords - 1))
    }

    /// How many words of a reply are showing `elapsed` seconds after its
    /// cue. The first word lands on the bubble's pop. Reduce Motion shows
    /// everything at once.
    static func revealedWordCount(totalWords: Int, elapsed: TimeInterval, reduceMotion: Bool) -> Int {
        guard !reduceMotion else { return totalWords }
        let firstWordAt = accent(for: .messageReceived).time
        guard elapsed >= firstWordAt else { return 0 }
        let shown = 1 + Int((elapsed - firstWordAt) / wordRevealInterval(totalWords: totalWords))
        return min(totalWords, shown)
    }

    /// The longest any reply reveals for.
    static var maximumWordRevealDuration: TimeInterval {
        accent(for: .messageReceived).time + maximumWordRevealSpan
    }

    /// How long a reply of `totalWords` keeps revealing.
    static func wordRevealDuration(totalWords: Int) -> TimeInterval {
        accent(for: .messageReceived).time
            + Double(max(totalWords - 1, 0)) * wordRevealInterval(totalWords: totalWords)
    }

    /// The buddy tilts 6° on the leap; a "?" (prop) pops above it on the
    /// top note. A reply that asks something back fires this instead of
    /// messageReceived, so its bubble (item 0) pops here, on the leap.
    private static func question(_ part: CuePart) -> CueMotion? {
        switch part {
        case .item(0):
            return CueMotion(
                scale: CueTrack([(0, 0.94), (0.200, 1.02), (0.32, 1.0)]),
                opacity: CueTrack([(0, 0), (0.06, 1)])
            )
        case .subject:
            return CueMotion(rotation: CueTrack([(0, 0), (0.200, 6), (0.62, 0)]))
        case .prop:
            return CueMotion(
                scale: CueTrack([(0, 0.6), (0.090, 0.9), (0.200, 1.08), (0.32, 1.0)]),
                offsetY: CueTrack([(0, 4), (0.200, -4), (0.32, -3)]),
                opacity: CueTrack([(0, 0), (0.09, 1), (0.60, 1), (0.80, 0)])
            )
        default: return nil
        }
    }

    // MARK: Jobs

    /// Two slow glow pulses across the held hum (the 5.5 Hz vibrato is too
    /// fast to follow); the approve button (prop) lifts 2 pt and stays.
    private static func permissionAsk(_ part: CuePart) -> CueMotion? {
        switch part {
        case .subject:
            return CueMotion(glow: CueTrack([
                (0, 0), (0.194, 1.0), (0.40, 0.2), (0.60, 0.8), (0.80, 0),
            ]))
        case .prop:
            return CueMotion(offsetY: CueTrack([(0, 0), (0.194, -2)]))
        default: return nil
        }
    }

    /// The buddy squashes for 60 ms, then stretch-pops on the peak; the
    /// failing row (prop) shakes ±3 pt twice.
    private static func surprised(_ part: CuePart) -> CueMotion? {
        switch part {
        case .subject:
            return CueMotion(scaleY: CueTrack([
                (0, 1.0), (0.020, 0.92), (0.055, 0.92), (0.081, 1.08), (0.24, 1.0),
            ]))
        case .prop:
            return CueMotion(offsetX: CueTrack([
                (0.081, 0), (0.12, 3), (0.18, -3), (0.24, 3), (0.30, -3), (0.36, 0),
            ]))
        default: return nil
        }
    }

    /// A neutral tapback badge springs out of the approve button's corner:
    /// 1.15 on the first note, settling to 1 on the octave, then fades as
    /// the sound ends.
    private static func thumbsUp(_ part: CuePart) -> CueMotion? {
        guard case .prop = part else { return nil }
        return CueMotion(
            scale: CueTrack([(0, 0), (0.070, 1.15), (0.182, 1.0)]),
            opacity: CueTrack([(0, 0), (0.04, 1), (0.45, 1), (0.62, 0)])
        )
    }

    /// The job row slides in from 10 pt below, in by the thump; a shimmer
    /// (prop) makes its first sweep with the rising tone.
    private static func jobStarted(_ part: CuePart) -> CueMotion? {
        switch part {
        case .subject:
            return CueMotion(
                offsetY: CueTrack([(0, 10), (0.047, 4), (0.24, 0)]),
                opacity: CueTrack([(0, 0), (0.047, 1)])
            )
        case .prop:
            return CueMotion(
                opacity: CueTrack([(0.047, 0), (0.10, 1), (0.34, 1), (0.40, 0)]),
                progress: CueTrack([(0.047, 0), (0.40, 1)])
            )
        default: return nil
        }
    }

    /// The activity dot pulses with each of the two calls. The second
    /// pulse ends lit; the view keeps it lit for as long as the job is
    /// still waiting.
    private static func jobNeedsYou(_ part: CuePart) -> CueMotion? {
        guard case .subject = part else { return nil }
        return CueMotion(
            scale: CueTrack([(0, 1), (0.060, 1.08), (0.30, 1), (0.560, 1.08), (0.80, 1)]),
            glow: CueTrack([(0, 0), (0.060, 1), (0.30, 0.15), (0.560, 1), (0.80, 1)])
        )
    }

    /// The checkmark draws on and finishes on the peak; one soft ring
    /// (prop) then expands and fades over the long tail.
    private static func jobDone(_ part: CuePart) -> CueMotion? {
        switch part {
        case .subject:
            return CueMotion(
                scale: CueTrack([(0, 0.96), (0.209, 1.04), (0.36, 1.0)]),
                progress: CueTrack([(0.009, 0), (0.209, 1)])
            )
        case .prop:
            return CueMotion(
                scale: CueTrack([(0.209, 1.0), (1.19, 1.6)]),
                opacity: CueTrack([(0.209, 0), (0.26, 0.5), (1.19, 0)])
            )
        default: return nil
        }
    }

    /// The card shrinks to 0.96 and fades over 350 ms, a slow fade for a
    /// long, deep tone.
    private static func jobClosed(_ part: CuePart) -> CueMotion? {
        guard case .subject = part else { return nil }
        return CueMotion(
            scale: CueTrack([(0, 1.0), (0.35, 0.96)]),
            opacity: CueTrack([(0, 1), (0.35, 0)])
        )
    }

    // MARK: Mates and skills

    /// The badge hops 6 pt on the chirp and lands with a squash on the
    /// thump.
    private static func levelUp(_ part: CuePart) -> CueMotion? {
        guard case .subject = part else { return nil }
        return CueMotion(
            scaleY: CueTrack([(0, 1), (0.12, 1.04), (0.20, 1.0), (0.240, 0.92), (0.40, 1.0)]),
            offsetY: CueTrack([(0, 0), (0.12, -6), (0.240, 0)])
        )
    }

    /// The removed item slides down 10 pt and fades with the falling slide.
    private static func levelDown(_ part: CuePart) -> CueMotion? {
        guard case .subject = part else { return nil }
        return CueMotion(
            offsetY: CueTrack([(0, 0), (0.50, 10)]),
            opacity: CueTrack([(0, 1), (0.50, 0)])
        )
    }

    // MARK: First run

    /// Four brightness steps with the low pulses, then the full reveal on
    /// the lift.
    private static func boot(_ part: CuePart) -> CueMotion? {
        guard case .subject = part else { return nil }
        return CueMotion(
            scale: CueTrack([(0, 0.96), (0.52, 0.96), (0.740, 1.02), (0.95, 1.0)]),
            opacity: CueTrack([
                (0, 0), (0.04, 0.22),
                (0.160, 0.22), (0.20, 0.36),
                (0.360, 0.36), (0.40, 0.50),
                (0.520, 0.50), (0.56, 0.62),
                (0.70, 0.62), (0.740, 1.0),
            ])
        )
    }

    /// Home tiles stagger in, one per arpeggio note, the last landing on
    /// the peak; a few tiny white sparkles twinkle over the top tile on
    /// the tail.
    private static func homeReveal(_ part: CuePart) -> CueMotion? {
        switch part {
        case .item(let index):
            let start = Double(index) * 0.080
            let land = start + 0.232
            return CueMotion(
                scale: CueTrack([(start, 0.97), (land, 1.0)]),
                offsetY: CueTrack([(start, 8), (land, 0)]),
                opacity: CueTrack([(0, 0), (start, 0), (start + 0.12, 1)])
            )
        case .sparkle(let index):
            return sparkle(index: index, start: 0.45, spread: 0.12)
        default: return nil
        }
    }

    /// A tiny twinkle: in, a beat at full, out. Staggered by index.
    private static func sparkle(index: Int, start: TimeInterval, spread: TimeInterval) -> CueMotion {
        let begin = start + Double(index) * spread
        return CueMotion(
            scale: CueTrack([(begin, 0.4), (begin + 0.12, 1.0), (begin + 0.30, 0.6)]),
            rotation: CueTrack([(begin, 0), (begin + 0.30, 45)]),
            opacity: CueTrack([(0, 0), (begin, 0), (begin + 0.10, 0.9), (begin + 0.30, 0)])
        )
    }

    // MARK: Hatching

    /// The showpiece. The mate's face sits as an egg (prop) that wobbles
    /// with the rumble, growing from ±2° to ±5°; cracks (items 0 and 1)
    /// appear at 1.6 s and 2.1 s; it splits at 2.55 s and the face
    /// (subject) pops 0.6 → 1.1 → 1 at 2.8 s, with sparkles.
    private static func hatching(_ part: CuePart) -> CueMotion? {
        switch part {
        case .prop:
            return CueMotion(
                scale: CueTrack([(2.55, 1.0), (2.75, 1.12)]),
                rotation: CueTrack(hatchingWobbleKeys),
                opacity: CueTrack([(0, 1), (2.55, 1), (2.75, 0)]),
                progress: CueTrack([(2.55, 0), (2.75, 1)])
            )
        case .item(let index):
            let at = index == 0 ? 1.600 : 2.100
            return CueMotion(opacity: CueTrack([(0, 0), (at, 0), (at + 0.03, 1), (2.55, 1), (2.65, 0)]))
        case .subject:
            return CueMotion(
                scale: CueTrack([(0, 0.6), (2.55, 0.6), (2.800, 1.1), (3.05, 1.0)]),
                opacity: CueTrack([(0, 0), (2.55, 0), (2.62, 1)])
            )
        case .sparkle(let index):
            return sparkle(index: index, start: 2.80, spread: 0.10)
        }
    }

    /// Alternating tilts every 0.17 s up to the split, swinging ±2° at the
    /// start of the rumble and ±5° just before it bursts.
    private static let hatchingWobbleKeys: [(TimeInterval, Double)] = {
        let step = 0.17
        let end = 2.55
        var keys: [(TimeInterval, Double)] = [(0, 0)]
        var time = step
        var sign = 1.0
        while time < end - step / 2 {
            let growth = time / end
            keys.append((time, sign * (2 + 3 * growth)))
            sign = -sign
            time += step
        }
        keys.append((end, 0))
        return keys
    }()
}
