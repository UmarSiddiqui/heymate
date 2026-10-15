//
//  CueMotionViews.swift
//  HeyMate
//
//  The SwiftUI side of cues: views that sample `CueChoreography` while a
//  cue they care about is playing, and sit perfectly still otherwise. The
//  timeline is paused between cues, so an idle notch or a long transcript
//  costs nothing per frame.
//
//  Time is always measured from the cue's `firedAt`, never from when the
//  view appeared, so a bubble inserted a tick after its sound still lands
//  its pop on the sound's peak.
//

import Combine
import SwiftUI

// MARK: - Reader

/// Hands its content the current `CueFrame` for one part of a cue. Use it
/// directly for anything beyond the standard transforms (glows, trims,
/// shimmer); `.cueMotion(...)` covers the common case.
struct CueMotionReader<Content: View>: View {
    let sounds: [UISoundPlayer.Sound]
    let part: CuePart
    var subject: String? = nil
    var bornAt: Date? = nil
    @ViewBuilder let content: (CueFrame) -> Content

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.companionMotionSuppressed) private var motionSuppressed
    @State private var playing: HeyMateCueEvent?

    /// A container that suppresses motion (a preview) gets the same
    /// opacity-only cues as Reduce Motion.
    private var reduceMotion: Bool { systemReduceMotion || motionSuppressed }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: playing == nil)) { context in
            content(frame(at: context.date))
        }
        .onReceive(HeyMateCue.shared.$recentCues) { _ in joinActiveCue() }
        .task(id: playing?.id) { await finishWhenDone() }
    }

    private func frame(at date: Date) -> CueFrame {
        guard let playing else { return .identity }
        return CueChoreography.frame(
            for: playing.sound,
            part: part,
            elapsed: playing.elapsed(at: date),
            reduceMotion: reduceMotion
        )
    }

    private func joinActiveCue() {
        guard let cue = HeyMateCue.shared.activeCue(for: sounds, subject: subject, bornAt: bornAt, at: Date()),
              cue.id != playing?.id else { return }
        playing = cue
    }

    private func finishWhenDone() async {
        guard let cue = playing else { return }
        let remaining = cue.duration - cue.elapsed(at: Date())
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        guard !Task.isCancelled, playing?.id == cue.id else { return }
        playing = nil
    }
}

// MARK: - Standard transforms

/// Applies one frame's scale, rotation, offset and opacity.
struct CueFrameModifier: ViewModifier {
    let frame: CueFrame
    var anchor: UnitPoint = .center

    func body(content: Content) -> some View {
        content
            .scaleEffect(
                x: frame.scale * frame.scaleX,
                y: frame.scale * frame.scaleY,
                anchor: anchor
            )
            .rotationEffect(.degrees(frame.rotation), anchor: anchor)
            .offset(x: frame.offsetX, y: frame.offsetY)
            .opacity(frame.opacity)
    }
}

private struct CueMotionModifier: ViewModifier {
    let sounds: [UISoundPlayer.Sound]
    let part: CuePart
    let subject: String?
    let bornAt: Date?
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        CueMotionReader(sounds: sounds, part: part, subject: subject, bornAt: bornAt) { frame in
            content.modifier(CueFrameModifier(frame: frame, anchor: anchor))
        }
    }
}

// MARK: - Exits

/// A cue whose subject leaves (a closed job card, a removed item) can't be
/// sampled by a reader: the view is gone the moment its row is. These play
/// the same choreography as the removal transition instead, starting in
/// the same tick the cue fires.
extension AnyTransition {
    static func cueExit(_ sound: UISoundPlayer.Sound, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion,
              let motion = CueChoreography.motion(for: sound, part: .subject) else {
            return .opacity
        }
        let end = motion.frame(at: motion.endTime)
        return .modifier(
            active: CueFrameModifier(frame: end),
            identity: CueFrameModifier(frame: .identity)
        )
    }
}

extension Animation {
    /// The animation a container uses for rows leaving with `cueExit`.
    static func cueExit(_ sound: UISoundPlayer.Sound, reduceMotion: Bool) -> Animation {
        guard !reduceMotion,
              let motion = CueChoreography.motion(for: sound, part: .subject) else {
            return DS.Animation.reducedMotionFade
        }
        return .easeInOut(duration: motion.endTime)
    }
}

extension View {
    /// Moves this view with one part of the cues it listens for: scale,
    /// rotation, offset and opacity. Pass `subject` (a message, run or
    /// mate id) when several of these can be on screen at once, or
    /// `bornAt` (a message's createdAt) so only the newest one reacts.
    func cueMotion(
        _ sounds: UISoundPlayer.Sound...,
        part: CuePart = .subject,
        subject: String? = nil,
        bornAt: Date? = nil,
        anchor: UnitPoint = .center
    ) -> some View {
        modifier(CueMotionModifier(sounds: sounds, part: part, subject: subject, bornAt: bornAt, anchor: anchor))
    }

    /// A soft neutral glow that follows a cue's `glow` track (the permission
    /// card's two pulses, the pill's echo after a close, the needs-you dot).
    func cueGlow(
        _ sounds: UISoundPlayer.Sound...,
        part: CuePart = .subject,
        subject: String? = nil,
        cornerRadius: CGFloat,
        color: Color = DS.Colors.textPrimary
    ) -> some View {
        overlay(
            CueMotionReader(sounds: sounds, part: part, subject: subject) { frame in
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(color.opacity(0.35 * frame.glow), lineWidth: 1)
                    .shadow(color: color.opacity(0.25 * frame.glow), radius: 6)
                    .allowsHitTesting(false)
            }
        )
    }
}

private struct CueGlowOpacityModifier: ViewModifier {
    let sounds: [UISoundPlayer.Sound]
    let part: CuePart
    let subject: String?

    func body(content: Content) -> some View {
        CueMotionReader(sounds: sounds, part: part, subject: subject) { frame in
            content.opacity(frame.isPlaying ? frame.glow : 1)
        }
    }
}

extension View {
    /// For something that is lit at rest (a needs-you halo): while the cue
    /// plays, its opacity follows the cue's `glow` track instead.
    func cueGlowOpacity(_ sounds: UISoundPlayer.Sound..., part: CuePart = .subject, subject: String? = nil) -> some View {
        modifier(CueGlowOpacityModifier(sounds: sounds, part: part, subject: subject))
    }
}

// MARK: - Props

/// The small symbolic objects that spring out of a cue's subject. Matte:
/// neutral glyphs in text colors, never tinted. Each draws nothing until
/// its cue plays.
struct CueProp: View {
    enum Kind {
        /// messageSent — flies up and right off the sent bubble.
        case paperPlane
        /// question — pops above the buddy.
        case questionMark
        /// thumbsUp — a tapback badge at the approve button's corner.
        case tapback
        /// jobDone — one soft ring expanding from the checkmark.
        case ring
    }

    let kind: Kind
    var subject: String? = nil
    var bornAt: Date? = nil

    private var sound: UISoundPlayer.Sound {
        switch kind {
        case .paperPlane: return .messageSent
        case .questionMark: return .question
        case .tapback: return .thumbsUp
        case .ring: return .jobDone
        }
    }

    var body: some View {
        CueMotionReader(sounds: [sound], part: .prop, subject: subject, bornAt: bornAt) { frame in
            glyph
                .scaleEffect(frame.scale)
                .rotationEffect(.degrees(frame.rotation))
                .offset(x: frame.offsetX, y: frame.offsetY)
                .opacity(frame.isPlaying ? frame.opacity : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        switch kind {
        case .paperPlane:
            Image(systemName: "paperplane.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.Colors.textSecondary)
        case .questionMark:
            Text("?")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(DS.Colors.textPrimary)
        case .tapback:
            Image(systemName: "hand.thumbsup.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(DS.Colors.surface3))
                .overlay(Circle().stroke(DS.Colors.borderStrong, lineWidth: 1))
        case .ring:
            Circle()
                .stroke(DS.Colors.textPrimary.opacity(0.5), lineWidth: 1)
        }
    }
}

/// A checkmark that draws itself on with `jobDone`, finishing on the
/// sound's peak, then rests fully drawn.
struct CueCheckmark: View {
    var subject: String? = nil
    var lineWidth: CGFloat = 1.6

    var body: some View {
        CueMotionReader(sounds: [.jobDone], part: .subject, subject: subject) { frame in
            CheckmarkShape()
                .trim(from: 0, to: frame.progress)
                .stroke(
                    DS.Colors.textPrimary,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
                .scaleEffect(frame.scale)
        }
        .overlay(CueProp(kind: .ring, subject: subject))
        .accessibilityHidden(true)
    }
}

struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.midY + rect.height * 0.02))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.maxY - rect.height * 0.24))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.16, y: rect.minY + rect.height * 0.26))
        return path
    }
}

/// The first sweep of light across a job row as it starts.
struct CueShimmer: View {
    var subject: String? = nil

    var body: some View {
        CueMotionReader(sounds: [.jobStarted], part: .prop, subject: subject) { frame in
            GeometryReader { proxy in
                let bandWidth = max(proxy.size.width * 0.35, 24)
                LinearGradient(
                    colors: [.clear, DS.Colors.textPrimary.opacity(0.08), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: bandWidth)
                .offset(x: -bandWidth + (proxy.size.width + bandWidth) * frame.progress)
                .opacity(frame.isPlaying ? frame.opacity : 0)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A four-point twinkle. White and tiny: the matte stand-in for confetti.
struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.28
        var path = Path()
        for index in 0..<8 {
            let angle = Double(index) * .pi / 4 - .pi / 2
            let radius = index.isMultiple(of: 2) ? outer : inner
            let point = CGPoint(
                x: center.x + CGFloat(cos(angle)) * radius,
                y: center.y + CGFloat(sin(angle)) * radius
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// A few sparkles scattered over a view for the cues that have them
/// (homeReveal over the top tile, hatching around the new face).
struct CueSparkles: View {
    let sound: UISoundPlayer.Sound
    var subject: String? = nil
    /// Where each sparkle sits, as fractions of the view's size.
    var positions: [UnitPoint] = [
        UnitPoint(x: 0.18, y: 0.22), UnitPoint(x: 0.82, y: 0.16),
        UnitPoint(x: 0.70, y: 0.78), UnitPoint(x: 0.26, y: 0.84),
    ]
    var size: CGFloat = 7

    var body: some View {
        GeometryReader { proxy in
            ForEach(Array(positions.prefix(CueChoreography.sparkleCount).enumerated()), id: \.offset) { index, position in
                CueMotionReader(sounds: [sound], part: .sparkle(index), subject: subject) { frame in
                    SparkleShape()
                        .fill(Color.white)
                        .frame(width: size, height: size)
                        .scaleEffect(frame.scale)
                        .rotationEffect(.degrees(frame.rotation))
                        .opacity(frame.isPlaying ? frame.opacity : 0)
                }
                .position(x: proxy.size.width * position.x, y: proxy.size.height * position.y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Word reveal

/// Gives its content how many words of a reply to show. Only a reply whose
/// cue asked for it (`revealsText`) reveals; anything else, including a
/// reply loaded from history or one that streamed in, shows in full.
struct CueWordReveal<Content: View>: View {
    /// The reply's text; its words are only counted once a cue joins.
    let text: String
    /// When the reply was created; only the cue fired with it reveals it.
    let bornAt: Date
    @ViewBuilder let content: (Int?) -> Content

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.companionMotionSuppressed) private var motionSuppressed
    @State private var playing: HeyMateCueEvent?

    /// A container that suppresses motion (a preview) gets the same
    /// opacity-only cues as Reduce Motion.
    private var reduceMotion: Bool { systemReduceMotion || motionSuppressed }
    @State private var totalWords = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: playing == nil)) { context in
            content(visibleWords(at: context.date))
        }
        .onReceive(HeyMateCue.shared.$recentCues) { _ in joinActiveCue() }
        .task(id: playing?.id) {
            guard let cue = playing else { return }
            let remaining = CueChoreography.wordRevealDuration(totalWords: totalWords) - cue.elapsed(at: Date())
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            guard !Task.isCancelled, playing?.id == cue.id else { return }
            playing = nil
        }
    }

    private func joinActiveCue() {
        guard !reduceMotion,
              let cue = HeyMateCue.shared.activeCue(
                  for: [.messageReceived], subject: nil, bornAt: bornAt, at: Date(),
                  duration: { _ in CueChoreography.maximumWordRevealDuration }
              ),
              cue.revealsText, cue.id != playing?.id else { return }
        let words = ChatWordReveal.totalWords(in: text)
        guard cue.elapsed(at: Date()) < CueChoreography.wordRevealDuration(totalWords: words) else { return }
        totalWords = words
        playing = cue
    }

    private func visibleWords(at date: Date) -> Int? {
        guard let playing else { return nil }
        let shown = CueChoreography.revealedWordCount(
            totalWords: totalWords,
            elapsed: playing.elapsed(at: date),
            reduceMotion: reduceMotion
        )
        return shown >= totalWords ? nil : shown
    }
}

// MARK: - Hatching

/// The showpiece: a new mate's face sits in an egg that wobbles with the
/// rumble, cracks twice, splits, and the face pops out with sparkles. When
/// no hatching cue is playing for this mate, it is just the face.
struct HatchingReveal<Face: View>: View {
    let subject: String
    var side: CGFloat = 56
    @ViewBuilder let face: () -> Face

    var body: some View {
        ZStack {
            face()
                .cueMotion(.hatching, subject: subject)

            CueMotionReader(sounds: [.hatching], part: .prop, subject: subject) { frame in
                egg(frame: frame)
            }

            CueSparkles(sound: .hatching, subject: subject, size: max(side * 0.12, 6))
                .frame(width: side * 1.5, height: side * 1.5)
        }
        .frame(width: side, height: side)
    }

    /// The shell. It only exists while a hatching plays.
    private func egg(frame: CueFrame) -> some View {
        let split = frame.progress
        return ZStack {
            EggHalf(isTop: true)
                .fill(DS.Colors.surface3)
                .overlay(EggHalf(isTop: true).stroke(DS.Colors.borderStrong, lineWidth: 1))
                .offset(y: -side * 0.22 * split)
                .rotationEffect(.degrees(-14 * split))
            EggHalf(isTop: false)
                .fill(DS.Colors.surface3)
                .overlay(EggHalf(isTop: false).stroke(DS.Colors.borderStrong, lineWidth: 1))
                .offset(y: side * 0.10 * split)
            crack(index: 0, path: EggCrack(isSecond: false))
            crack(index: 1, path: EggCrack(isSecond: true))
        }
        .frame(width: side * 0.86, height: side)
        .scaleEffect(frame.scale)
        .rotationEffect(.degrees(frame.rotation), anchor: .bottom)
        .opacity(frame.isPlaying ? frame.opacity : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func crack(index: Int, path: EggCrack) -> some View {
        CueMotionReader(sounds: [.hatching], part: .item(index), subject: subject) { frame in
            path
                .stroke(DS.Colors.textSecondary, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                .opacity(frame.isPlaying ? frame.opacity : 0)
        }
    }
}

/// Top or bottom of an egg, split along a zigzag a little above the middle.
private struct EggHalf: Shape {
    let isTop: Bool

    func path(in rect: CGRect) -> Path {
        let egg = Path(ellipseIn: rect)
        var clip = Path()
        let seamY = rect.minY + rect.height * 0.46
        let teeth = 5
        let toothWidth = rect.width / CGFloat(teeth)
        clip.move(to: CGPoint(x: rect.minX, y: isTop ? rect.minY : rect.maxY))
        clip.addLine(to: CGPoint(x: rect.minX, y: seamY))
        for tooth in 0..<teeth {
            let x = rect.minX + CGFloat(tooth) * toothWidth
            clip.addLine(to: CGPoint(x: x + toothWidth / 2, y: seamY + (tooth.isMultiple(of: 2) ? -4 : 4)))
            clip.addLine(to: CGPoint(x: x + toothWidth, y: seamY))
        }
        clip.addLine(to: CGPoint(x: rect.maxX, y: isTop ? rect.minY : rect.maxY))
        clip.closeSubpath()
        return egg.intersection(clip)
    }
}

/// The two cracks that show before the split.
private struct EggCrack: Shape {
    let isSecond: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let y = rect.minY + rect.height * 0.46
        if isSecond {
            path.move(to: CGPoint(x: rect.midX, y: y))
            path.addLine(to: CGPoint(x: rect.midX + rect.width * 0.12, y: y - 5))
            path.addLine(to: CGPoint(x: rect.midX + rect.width * 0.22, y: y + 3))
            path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.12, y: y - 2))
        } else {
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.14, y: y + 2))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.26, y: y - 4))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: y + 4))
            path.addLine(to: CGPoint(x: rect.midX, y: y))
        }
        return path
    }
}
