//
//  NotchPillSurface.swift
//  HeyMate
//
//  Native notch silhouette, restrained edge colour, and event-driven activity.
//  The hosting view is stable; idle has no timer or repeating animation.
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

    /// Pointer is resting on the tab. Highlights compact surface without
    /// changing geometry; open-on-hover remains controller policy.
    @Published var isHovered = false
    @Published var openingCue: NotchOpenCue?
    @Published var reducesMotion = false

    @Published var hasUsage = false
    @Published var usageProviderCount = 0

    /// Highest-priority ambient fact from the micro-apps (media, timer,
    /// battery…). Shown in the trailing slot when the companion is
    /// idle, because voice state always outranks ambient state.
    @Published var activity: NotchActivity?

    @Published var themeColor: Color = AppTheme.color
    @Published var isOutlineEnabled = true
    @Published var isAgentActive = false
    @Published var agentStatus: NotchCompactStatus.Snapshot?
    @Published var activeAgentCount = 0
    /// Silent mode swaps voice words ("speaking", "ready") for ones that
    /// match what is happening: a reply being written, a quiet companion.
    @Published var isSilentModeEnabled = false

    /// Height of the camera housing (`NSScreen.safeAreaInsets.top`).
    @Published var occludedTopInset: CGFloat = 0

    /// Width of the physical cutout. The peek slots are laid out *outside*
    /// this span so their content is never hidden behind the camera.
    @Published var hardwareNotchWidth: CGFloat = NotchLayoutMath.fallbackIdleWidth

    var showsStatusText: Bool {
        voiceState != .idle || agentStatus != nil || activity != nil
    }

    /// Only live status or usage needs space outside the camera housing.
    var wantsWidenedFrame: Bool {
        showsStatusText || hasUsage
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

    private var housingShape: NotchSilhouetteShape {
        NotchSilhouetteShape(
            shoulderRadius: model.occludedTopInset > 0 ? NotchLayoutMath.compactShoulderRadius : 0,
            bottomRadius: housingCornerRadius
        )
    }

    private var identityColor: Color {
        guard let status = model.agentStatus, model.voiceState == .idle else { return model.themeColor }
        switch status.phase {
        case .needsUser: return DS.Colors.warning
        case .failed: return .red
        default: return Color(hue: status.hue, saturation: 0.62, brightness: 0.98)
        }
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
        .overlay {
            housingShape
            .stroke(LinearGradient(colors: [.clear, .white.opacity(model.isHovered ? 0.18 : 0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
            .allowsHitTesting(false)
        }
        .overlay { closeEchoGlow }
        .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.18), value: model.isHovered)
        .animation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.22), value: model.voiceState)
        .animation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.22), value: model.activity)
        .animation(accessibilityReduceMotion ? nil : .easeInOut(duration: 0.2), value: model.isOutlineEnabled)
    }

    // MARK: Chrome

    private var housingFill: some View {
        housingShape.fill(Color.black)
            .overlay {
                if model.voiceState == .responding && !model.isSilentModeEnabled {
                    RadialGradient(colors: [.orange.opacity(0.38), .orange.opacity(0.12), .clear],
                                   center: .trailing, startRadius: 0, endRadius: 48)
                        .clipShape(housingShape)
                }
            }
    }

    /// After a deliberate close, the pill glows faintly twice with the
    /// close sound's echoes.
    private var closeEchoGlow: some View {
        CueMotionReader(sounds: [.panelClose], part: .prop) { frame in
            housingShape
            .stroke(Color.white.opacity(0.45 * frame.glow), lineWidth: 1)
            .shadow(color: Color.white.opacity(0.3 * frame.glow), radius: 4)
        }
        .allowsHitTesting(false)
    }

    private var outlineGlow: some View {
        housingShape
            .stroke(LinearGradient(
                colors: [.clear, identityColor.opacity(0.25), identityColor.opacity(0.8)],
                startPoint: .top, endPoint: .bottom
            ), lineWidth: 0.75)
            .shadow(color: identityColor.opacity(model.showsStatusText ? 0.4 : 0.18), radius: 4)
            .opacity(model.showsStatusText ? 0.85 : (model.isHovered ? 0.65 : 0.42))
            .allowsHitTesting(false)
    }

    /// Slots fade in only once there is real estate to draw them in, so a
    /// half-finished widen animation never clips a glyph against the camera.
    private func slotOpacity(forExposedWidth exposedSideWidth: CGFloat) -> Double {
        let fadeInThreshold: CGFloat = 10
        let fullyVisibleWidth: CGFloat = 20
        guard exposedSideWidth > fadeInThreshold else { return 0 }
        let progress = (exposedSideWidth - fadeInThreshold) / (fullyVisibleWidth - fadeInThreshold)
        return Double(min(max(progress, 0), 1))
    }

    // MARK: Compact leading

    /// Small state glyphs appear only while there is something to report.
    @ViewBuilder
    private var leadingSlot: some View {
        if let cue = model.openingCue {
            NotchOpenRing(cue: cue, reduceMotion: accessibilityReduceMotion || model.reducesMotion)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        } else {
            switch model.voiceState {
            case .listening:
                Circle().fill(model.themeColor).frame(width: 6, height: 6)
            case .processing:
                NotchBrandMark()
            case .responding:
                Text(model.isSilentModeEnabled ? "Replying" : "Speaking")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            case .idle:
                if let status = model.agentStatus {
                    HStack(spacing: 6) {
                        if status.phase == .working || status.phase == .planning {
                            NotchBrandMark()
                        } else {
                            Image(systemName: statusSymbol(for: status.phase))
                                .font(.system(size: 12, weight: .medium))
                        }
                        if model.activeAgentCount > 1 {
                            Text("\(model.activeAgentCount)").font(.system(size: 10, weight: .medium)).monospacedDigit()
                        }
                    }
                    .foregroundStyle(identityColor)
                } else if let activity = model.activity {
                    Image(systemName: activity.symbolName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(activity.tintColor)
                }
            }
        }
    }

    private func statusSymbol(for phase: NotchCompactStatus.Phase) -> String {
        switch phase {
        case .needsUser: return "exclamationmark.circle.fill"
        case .succeeded: return "checkmark.circle.fill"
        case .failed, .cancelled: return "xmark.circle.fill"
        case .queued: return "clock"
        case .planning: return "ellipsis"
        case .working: return "sparkle"
        }
    }

    // MARK: Compact trailing

    /// Live voice, task or ambient status outranks usage. Usage returns as
    /// soon as the task completion expires.
    @ViewBuilder
    private var trailingSlot: some View {
        switch model.voiceState {
            case .listening:
                NotchLiveWaveform(
                    audioPowerLevel: model.audioPowerLevel,
                    themeColor: model.themeColor
                )
            case .processing:
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            case .responding:
                if model.isSilentModeEnabled {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(model.themeColor)
                } else {
                    NotchSpeakingWaveform(reduceMotion: accessibilityReduceMotion || model.reducesMotion)
                }
            case .idle:
                if let status = model.agentStatus {
                    Text(status.phase == .needsUser ? "Needs you" : status.displayText)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .truncationMode(.tail)
                        .contentTransition(.opacity)
                        .foregroundStyle(identityColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                } else if let activity = model.activity {
                    pillLabel(activity.trailingText)
                        .foregroundColor(activity.tintColor.opacity(0.92))
                } else if model.hasUsage {
                    NotchCompactUsage()
                }
        }
    }

    private func pillLabel(_ text: String) -> some View {
        Text(text)
            .font(DS.Fonts.keycap)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundColor(DS.Colors.textPrimary.opacity(0.92))
            .contentTransition(.opacity)
            .padding(.horizontal, 3)
    }

    private var accessibilitySummary: String {
        if model.openingCue != nil { return "HeyMate, opening" }
        if model.voiceState == .idle, let status = model.agentStatus {
            return "HeyMate, \(status.title), \(status.phase.label), \(status.displayText), \(model.activeAgentCount) active tasks"
        }
        if model.isAgentActive { return "HeyMate, agent running" }
        switch model.voiceState {
        case .idle:
            if let activity = model.activity {
                return "HeyMate, \(activity.kind.rawValue) \(activity.trailingText)"
            }
            return model.isSilentModeEnabled ? "HeyMate, ready, silent mode" : "HeyMate, ready"
        case .listening: return "HeyMate, listening"
        case .processing: return "HeyMate, thinking"
        case .responding: return model.isSilentModeEnabled ? "HeyMate, replying" : "HeyMate, speaking"
        }
    }
}

private struct NotchSpeakingWaveform: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4) { index in
                    let wave = reduceMotion ? 0.5 : (sin(time * 7 + Double(index) * 1.6) + 1) / 2
                    Capsule()
                        .fill(Color(red: 1, green: 0.61, blue: 0.27))
                        .frame(width: 2, height: 4 + 9 * wave)
                }
            }
            .shadow(color: .orange.opacity(0.55), radius: 4)
            .accessibilityHidden(true)
        }
    }
}

/// Speaking: a solid core with one expanding ring, matching the cursor
/// overlay's speaking treatment.
struct NotchSpeakingRings: View {
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
                    .cueMotion(.listenStart, part: .item(barIndex))
            }
        }
        .animation(.easeOut(duration: 0.09), value: audioPowerLevel)
    }

    private func height(forWeight weight: CGFloat) -> CGFloat {
        let normalizedPower = min(max(audioPowerLevel, 0), 1)
        return Self.minimumBarHeight + normalizedPower * Self.maximumBarTravel * weight
    }
}
