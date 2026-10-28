//
//  CompanionCursorIndicators.swift
//  HeyMate
//
//  What the floating cursor turns into during a voice turn: a small level
//  meter while the user talks, then orbiting dots while HeyMate thinks.
//

import SwiftUI

/// Five bars that follow the microphone level, tallest in the middle.
struct CompanionListeningMeter: View {
    let audioPowerLevel: CGFloat

    private static let barWeights: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        let level = Self.easedLevel(audioPowerLevel)
        HStack(spacing: 2) {
            ForEach(Self.barWeights.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(DS.Colors.overlayCursorBlue)
                    .frame(width: 2, height: 3 + level * 10 * Self.barWeights[index])
            }
        }
        .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6)
        .animation(.linear(duration: 0.08), value: audioPowerLevel)
    }

    /// Ignores the noise floor, then boosts quiet speech so it still moves.
    nonisolated static func easedLevel(_ power: CGFloat) -> CGFloat {
        pow(min(max(power - 0.008, 0) * 2.85, 1), 0.76)
    }
}

/// Three comet dots orbiting while a reply is on its way. The orbit
/// speeds up as the reply streams faster, breathes in and out between
/// bursts, and a small symbol beside it says what kind of step is running.
struct CompanionThinkingSpinner: View {
    var tempo: CursorWorkPace.Tempo = .calm
    var activity: CursorActivityKind?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Orbit angle carried across tempo changes so a speed-up never jumps.
    @State private var clock = OrbitClock()

    private static let headCount = 3
    private static let trailLength = 5

    var body: some View {
        HStack(spacing: 5) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                Canvas { canvas, size in
                    let angle = reduceMotion ? 0 : clock.angle(at: time, orbitSeconds: tempo.orbitSeconds)
                    draw(in: &canvas, size: size, angle: angle, time: reduceMotion ? 0 : time)
                }
            }
            .frame(width: 18, height: 18)
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6)

            if let activity {
                Image(systemName: activity.symbolName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.Colors.overlayCursorBlue)
                    .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 4)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .id(activity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: activity)
        // The orbit sits on the cursor point; the symbol hangs to its right.
        .frame(width: 18, alignment: .leading)
        .accessibilityHidden(true)
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, angle: Double, time: TimeInterval) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // Breathes between 5 and 7 pt every 1.6 s.
        let radius = 6 + sin(time * 2 * .pi / 1.6)
        for head in 0..<Self.headCount {
            let base = angle + Double(head) * 2 * .pi / Double(Self.headCount)
            for step in 0..<Self.trailLength {
                let fade = 1 - Double(step) / Double(Self.trailLength)
                let a = base - Double(step) * 0.28
                let dot = 2.4 * fade + 0.6
                let point = CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
                canvas.fill(
                    Path(ellipseIn: CGRect(x: point.x - dot / 2, y: point.y - dot / 2, width: dot, height: dot)),
                    with: .color(DS.Colors.overlayCursorBlue.opacity(fade * fade))
                )
            }
        }
    }
}

/// Integrates the orbit angle so a tempo change bends the speed, not the
/// position.
private final class OrbitClock {
    private var lastTime: TimeInterval?
    private var angle: Double = 0

    func angle(at time: TimeInterval, orbitSeconds: Double) -> Double {
        if let lastTime { angle += min(max(time - lastTime, 0), 0.1) * 2 * .pi / orbitSeconds }
        lastTime = time
        return angle
    }
}

/// The small blue label that sits beside the cursor: the welcome line, the
/// onboarding prompt, "right here!" when pointing, and caption annotations.
struct CursorPillLabel: View {
    let text: String
    /// 0 at rest; higher values brighten and widen the glow.
    var glow: CGFloat = 0

    var body: some View {
        Text(text)
            .font(DS.Fonts.caption.weight(.medium))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(DS.Colors.overlayCursorBlue)
                    .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5 + glow), radius: 6 + glow * 16)
            )
            .fixedSize()
    }
}
