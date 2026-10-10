//
//  CompanionCursorIndicators.swift
//  HeyMate
//
//  What the floating cursor turns into during a voice turn: a small level
//  meter while the user talks, then a spinner while HeyMate thinks.
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

/// A fading arc that spins while a reply is on its way.
struct CompanionThinkingSpinner: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [DS.Colors.overlayCursorBlue.opacity(0), DS.Colors.overlayCursorBlue],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
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
