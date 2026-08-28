//
//  NotchPillSurface.swift
//  leanring-buddy
//
//  The collapsed notch tab, rebuilt around three rules learned from the
//  previous version:
//
//  1. HOVER PEEKS, CLICK OPENS. Resting the pointer on the camera housing
//     no longer drops the whole Home card. It widens the tab a few points
//     and reveals a leading glyph + a trailing context chip on either side
//     of the physical camera — the Dynamic Island "compact leading /
//     compact trailing" idea. Committing to the full card stays a click,
//     so brushing past the notch on the way to the menu bar costs nothing.
//
//  2. NOTHING ANIMATES WHILE IDLE. The old pill hosted a
//     `TimelineView(.animation)` that re-evaluated its body 24 times a
//     second forever, on a menu-bar app that is idle ~99% of the time.
//     Every recurring animation here is an implicit `repeatForever`
//     animation, which Core Animation runs on the render server without
//     waking SwiftUI, and the ones that cost anything only exist while the
//     matching state is live.
//
//  3. THE HOSTING VIEW IS BUILT ONCE. `NotchCompanionController` used to
//     assign a fresh `rootView` on every audio-power tick, which throws
//     away and rebuilds the whole SwiftUI graph 12×/sec while listening.
//     State now lives in `NotchPillModel`, an ObservableObject the view
//     observes, so updates are ordinary SwiftUI diffs.
//

import Combine
import SwiftUI

// MARK: - Model

/// Everything the collapsed tab renders. Owned by `NotchCompanionController`,
/// handed to the hosting view once, and mutated in place afterwards.
@MainActor
final class NotchPillModel: ObservableObject {

    /// Live voice pipeline state. Drives the leading indicator and, when
    /// non-idle, the trailing waveform.
    @Published var voiceState: CompanionVoiceState = .idle

    /// Smoothed 0…1 mic power. Only published while listening — see
    /// `NotchCompanionController.observeStateChanges`.
    @Published var audioPowerLevel: CGFloat = 0

    /// Pointer is resting on the tab. Widens the frame and reveals the
    /// peek slots; never opens the card by itself.
    @Published var isHovered = false

    /// A file drag is hovering the notch. Outranks every other visual so
    /// the drop target is unmistakable while the pointer holds a file.
    @Published var isDropTargeted = false

    /// Highest-priority ambient fact from the micro-apps (media, timer,
    /// shelf, battery…). Shown in the trailing slot when the companion is
    /// idle, because voice state always outranks ambient state.
    @Published var activity: NotchActivity?

    @Published var themeColor: Color = AppTheme.color
    @Published var isOutlineEnabled = true
    @Published var isAgentActive = false
    /// One line per live agent. Filaments fit inside housing and never widen
    /// notch or show dashboard count.
    @Published var agentFilaments: [AgentFilament] = []

    /// Height of the camera housing (`NSScreen.safeAreaInsets.top`).
    @Published var occludedTopInset: CGFloat = 0

    /// Width of the physical cutout. The peek slots are laid out *outside*
    /// this span so their content is never hidden behind the camera.
    @Published var hardwareNotchWidth: CGFloat = NotchLayoutMath.fallbackIdleWidth

    /// True when the pill should render its widened form. Recomputed by the
    /// controller alongside the window frame so pixels and layout agree.
    var wantsWidenedFrame: Bool {
        voiceState != .idle || isHovered || isDropTargeted || activity != nil
    }
}

// MARK: - View

/// The notch pill: a black fill of the live hardware cutout, plus optional
/// peek slots that only exist once the window has widened enough to expose
/// screen on either side of the camera.
struct NotchPillView: View {
    @ObservedObject var model: NotchPillModel
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        VStack(spacing: 0) {
            pillCore
            if model.isOutlineEnabled {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, model.isOutlineEnabled ? NotchLayoutMath.outlinePad : 0)
        .padding(.bottom, model.isOutlineEnabled ? NotchLayoutMath.outlinePad : 0)
    }

    private var housingCornerRadius: CGFloat {
        NotchLayoutMath.pillCornerRadius(forHeight: model.occludedTopInset)
    }

    private var pillCore: some View {
        // GeometryReader rather than a fixed constant: the exposed width on
        // each side is whatever the window currently has beyond the physical
        // cutout, so the slots stay correct mid-animation and on any Mac.
        GeometryReader { geometry in
            let exposedSideWidth = max(
                (geometry.size.width - model.hardwareNotchWidth) / 2,
                0
            )
            HStack(spacing: 0) {
                leadingSlot
                    .frame(width: exposedSideWidth, alignment: .center)
                    .opacity(slotOpacity(forExposedWidth: exposedSideWidth))
                    .allowsHitTesting(false)

                Spacer(minLength: 0)

                trailingSlot
                    .frame(width: exposedSideWidth, alignment: .center)
                    .opacity(slotOpacity(forExposedWidth: exposedSideWidth))
                    .allowsHitTesting(false)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("notch-pill-\(Int(model.occludedTopInset))")
        .accessibilityLabel(Text(accessibilitySummary))
        .background(housingFill)
        .overlay { if model.isOutlineEnabled { outlineGlow } }
        .overlay(alignment: .bottom) {
            AgentFilamentStrip(filaments: model.agentFilaments)
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
        }
        .overlay(alignment: .bottom) { bottomHairline }
        .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.18), value: model.isHovered)
        .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.16), value: model.isDropTargeted)
        .animation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.22), value: model.voiceState)
        .animation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.22), value: model.activity)
        .animation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.2), value: model.isOutlineEnabled)
    }

    // MARK: Chrome

    private var housingFill: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: housingCornerRadius,
            bottomTrailingRadius: housingCornerRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
        .fill(Color.black)
    }

    private var outlineGlow: some View {
        NotchOutlineGlow(color: model.themeColor, cornerRadius: housingCornerRadius)
    }

    /// One hairline under the housing, tinted while a voice interaction is
    /// live. Previously two stacked overlays; a single rectangle whose color
    /// interpolates is both cheaper and avoids the double-edge seam.
    private var bottomHairline: some View {
        Rectangle()
            .fill(hairlineColor)
            .frame(height: model.voiceState == .idle ? 0.5 : 1)
    }

    private var hairlineColor: Color {
        if model.isDropTargeted { return model.themeColor }
        if model.voiceState != .idle {
            return model.themeColor.opacity(0.5)
        }
        return .white.opacity(model.isHovered ? 0.20 : 0.10)
    }

    /// Slots fade in only once there is real estate to draw them in, so a
    /// half-finished widen animation never clips a glyph against the camera.
    private func slotOpacity(forExposedWidth exposedSideWidth: CGFloat) -> Double {
        let fadeInThreshold: CGFloat = 10
        let fullyVisibleWidth: CGFloat = 26
        guard exposedSideWidth > fadeInThreshold else { return 0 }
        let progress = (exposedSideWidth - fadeInThreshold) / (fullyVisibleWidth - fadeInThreshold)
        return Double(min(max(progress, 0), 1))
    }

    // MARK: Compact leading

    /// Left of the camera: what the companion IS doing. Voice state always
    /// wins; an ambient activity fills in while idle.
    @ViewBuilder
    private var leadingSlot: some View {
        if model.isDropTargeted {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(model.themeColor)
        } else {
            switch model.voiceState {
            case .idle:
                if let activity = model.activity {
                    NotchActivityGlyph(activity: activity, themeColor: model.themeColor)
                } else {
                    NotchReadyDot(isHovered: model.isHovered)
                }
            case .listening:
                NotchListeningDot(themeColor: model.themeColor)
            case .processing:
                NotchThinkingDot()
            case .responding:
                NotchSpeakingRings(themeColor: model.themeColor)
            }
        }
    }

    // MARK: Compact trailing

    /// Right of the camera: the shortest possible words for what is going
    /// on. Live meter while listening, one status word while busy, the
    /// activity's own label while idle, and a shortcut hint on bare hover.
    @ViewBuilder
    private var trailingSlot: some View {
        if model.isDropTargeted {
            pillLabel("drop")
                .foregroundColor(model.themeColor)
        } else {
            switch model.voiceState {
            case .listening:
                NotchLiveWaveform(
                    audioPowerLevel: model.audioPowerLevel,
                    themeColor: model.themeColor
                )
            case .processing, .responding:
                pillLabel(model.isAgentActive ? "agent" : busyWord)
            case .idle:
                if let activity = model.activity {
                    pillLabel(activity.trailingText)
                        .foregroundColor(activity.tintColor.opacity(0.92))
                } else if model.isHovered {
                    pillLabel("ready")
                } else {
                    EmptyView()
                }
            }
        }
    }

    private var busyWord: String {
        model.voiceState == .processing ? "thinking" : "speaking"
    }

    private func pillLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundColor(DS.Colors.textPrimary.opacity(0.92))
            .contentTransition(.opacity)
            .padding(.horizontal, 4)
    }

    private var accessibilitySummary: String {
        if model.isAgentActive { return "HeyMate, agent running" }
        switch model.voiceState {
        case .idle:
            if let activity = model.activity {
                return "HeyMate, \(activity.kind.rawValue) \(activity.trailingText)"
            }
            return "HeyMate, ready"
        case .listening: return "HeyMate, listening"
        case .processing: return "HeyMate, thinking"
        case .responding: return "HeyMate, speaking"
        }
    }
}

/// Thin breathing lines: ambient evidence, not another status slot.
private struct AgentFilamentStrip: View {
    let filaments: [AgentFilament]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(filaments) { filament in
                AgentFilamentLine(filament: filament)
            }
        }
        .frame(maxWidth: 120)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct AgentFilamentLine: View {
    let filament: AgentFilament
    @State private var isBreathing = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        let color = Color(hue: filament.hue, saturation: 0.78, brightness: 0.98)
        Capsule(style: .continuous)
            .fill(color)
            .frame(maxWidth: 24)
            .frame(height: 1.5)
            .opacity(accessibilityReduceMotion ? 0.9 : (isBreathing ? 0.95 : 0.38))
            .shadow(color: color.opacity(0.6), radius: isBreathing ? 3 : 1)
            .onAppear {
                guard !accessibilityReduceMotion else { return }
                let duration = 1.45 + filament.hue * 0.65
                withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
                    isBreathing = true
                }
            }
    }
}

// MARK: - Indicators
//
// Each indicator owns its own animation. None of them use TimelineView:
// a `repeatForever` implicit animation is handed to Core Animation once
// and then runs without re-evaluating any SwiftUI body, which is the
// difference between ~0% and a permanently warm CPU core on an app that
// sits in the menu bar all day.

/// Idle: a slow green breath. The only always-on animation in the app, and
/// it costs one interpolated opacity on the render server.
private struct NotchReadyDot: View {
    let isHovered: Bool
    @State private var isBreathingIn = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        Circle()
            .fill(DS.Colors.success)
            .frame(width: 6, height: 6)
            .opacity(accessibilityReduceMotion ? 1.0 : (isBreathingIn ? 1.0 : 0.62))
            .shadow(color: DS.Colors.success.opacity(0.55), radius: isHovered ? 4 : 2)
            .onAppear {
                guard !accessibilityReduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    isBreathingIn = true
                }
            }
    }
}

/// Listening: steady, saturated, no motion — the waveform beside it is
/// already carrying all the movement the eye needs.
private struct NotchListeningDot: View {
    let themeColor: Color

    var body: some View {
        Circle()
            .fill(themeColor)
            .frame(width: 6, height: 6)
            .shadow(color: themeColor.opacity(0.9), radius: 3)
    }
}

/// Thinking: a fast amber blink. Exists only while processing.
private struct NotchThinkingDot: View {
    @State private var isDim = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        Circle()
            .fill(DS.Colors.warning)
            .frame(width: 6, height: 6)
            .opacity(accessibilityReduceMotion ? 1.0 : (isDim ? 0.3 : 1.0))
            .onAppear {
                guard !accessibilityReduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.42).repeatForever(autoreverses: true)) {
                    isDim = true
                }
            }
    }
}

/// Speaking: a solid core with one expanding ring, matching the cursor
/// overlay's speaking treatment.
private struct NotchSpeakingRings: View {
    let themeColor: Color
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(themeColor.opacity(0.28), lineWidth: 1)
                .frame(width: 10, height: 10)
                .scaleEffect(accessibilityReduceMotion ? 1 : (isExpanded ? 1.12 : 0.9))
            Circle()
                .stroke(themeColor, lineWidth: 1.4)
                .frame(width: 7, height: 7)
        }
        .onAppear {
            guard !accessibilityReduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isExpanded = true
            }
        }
    }
}

/// Micro-app glyph with an optional progress ring (timer countdown, file
/// copy, download). Static unless the producer moves `progress`.
private struct NotchActivityGlyph: View {
    let activity: NotchActivity
    let themeColor: Color

    var body: some View {
        ZStack {
            if let progress = activity.progress {
                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(
                        activity.tintColor,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 13, height: 13)
                    .animation(.linear(duration: 0.25), value: progress)
            }
            Image(systemName: activity.kind.symbolName)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(activity.tintColor)
        }
    }
}

/// Five-bar mic meter. Heights come straight from the published power
/// level with a per-bar weighting, so the bars move because audio moved —
/// not because a 24fps clock ticked. Only instantiated while listening.
private struct NotchLiveWaveform: View {
    let audioPowerLevel: CGFloat
    let themeColor: Color

    /// Weights give the middle bars more travel, which reads as a voice
    /// envelope instead of a flat equalizer.
    private static let barWeights: [CGFloat] = [0.45, 0.8, 1.0, 0.75, 0.4]

    private static let minimumBarHeight: CGFloat = 2.5
    private static let maximumBarTravel: CGFloat = 9

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(Self.barWeights.enumerated()), id: \.offset) { barIndex, weight in
                Capsule(style: .continuous)
                    .fill(themeColor.opacity(0.55 + 0.45 * Double(weight)))
                    .frame(width: 2, height: height(forWeight: weight))
            }
        }
        .animation(.easeOut(duration: 0.09), value: audioPowerLevel)
    }

    private func height(forWeight weight: CGFloat) -> CGFloat {
        let normalizedPower = min(max(audioPowerLevel, 0), 1)
        return Self.minimumBarHeight + normalizedPower * Self.maximumBarTravel * weight
    }
}
