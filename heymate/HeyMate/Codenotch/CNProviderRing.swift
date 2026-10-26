// Adapted from vinzdg/codenotch Features/ProviderRing.swift, MIT, revision 6522e9f.
// Host adaptation: HeyMate glyphs/size, dark bezel palette, fixed inside weekly
// ring, system + app reduced motion. No upstream preference singleton.
import SwiftUI

struct CNProviderRing: View {
    let provider: NotchUsageProvider
    let usedFraction: Double?
    var weeklyFraction: Double? = nil
    var showsRemaining = false
    var isStale = false
    var activity: CNActivitySummary?
    var isRefreshing = false
    var reduceMotion = false
    var isBlocked = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var spin: Double = 0
    private var still: Bool { systemReduceMotion || reduceMotion }
    private var band: CNUsageBand { CNUsageBand.band(for: usedFraction ?? 0) }
    private var showsShutRings: Bool { isBlocked || (usedFraction ?? 0) >= 1 || (weeklyFraction ?? 0) >= 1 }
    private var sweep: CGFloat {
        CGFloat(min(max(CNPercent.metered(usedFraction ?? 0, showingRemaining: showsRemaining), 0), 1))
    }
    private var weeklySweep: CGFloat {
        CGFloat(min(max(CNPercent.metered(weeklyFraction ?? 0, showingRemaining: showsRemaining), 0), 1))
    }
    private var primaryColor: Color {
        if showsShutRings { return showsRemaining ? .gray : CNUsageBand.exhausted.color }
        return band == .ample ? provider.tint : band.color
    }

    var body: some View {
        ZStack {
            // Staleness affects usage, never the independently observed activity.
            ZStack {
                Circle().strokeBorder(.white.opacity(0.18), lineWidth: 3)
                if usedFraction != nil {
                    Circle().inset(by: 1.5).trim(from: 0, to: sweep)
                        .stroke(primaryColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90 + spin))
                        .animation(CNNotchMotion.respectingReduceMotion(CNNotchMotion.reading, still), value: sweep)
                        .animation(CNNotchMotion.respectingReduceMotion(CNNotchMotion.reading, still), value: band)
                }
                // Transient activity wins the inside band; week remains in details.
                if weeklyFraction != nil, activity == nil || activity?.state == .idle {
                    Circle().inset(by: 6).stroke(.white.opacity(0.14), lineWidth: 1.4)
                    Circle().inset(by: 6).trim(from: 0, to: weeklySweep)
                        .stroke(showsShutRings ? primaryColor : CNUsageBand.band(for: weeklyFraction ?? 0).color,
                                style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(CNNotchMotion.respectingReduceMotion(CNNotchMotion.reading, still), value: weeklySweep)
                }
                NotchProviderGlyph(provider: provider, size: 20)
                    .opacity(showsShutRings ? 0.4 : usedFraction == nil ? 0.65 : 1)
            }.opacity(isStale ? 0.45 : 1)
            if let activity, activity.state != .idle {
                if activity.state == .working {
                    if still {
                        Circle().inset(by: 6).trim(from: 0, to: 0.25)
                            .stroke(activity.color, lineWidth: CNNotchLayout.activityStroke)
                    } else {
                        CNSpinningArc(color: activity.color, arcFraction: 0.25, dashed: false, inset: 6, turns: true)
                    }
                } else {
                    CNActivityPulse(color: activity.color, still: still)
                }
            }
        }
        .frame(width: 44, height: 44)
        .scaleEffect(isRefreshing ? 0.93 : 1)
        .animation(CNNotchMotion.respectingReduceMotion(.spring(response: 0.3, dampingFraction: 0.62), still), value: isRefreshing)
        .onChange(of: isRefreshing) { _, refreshing in
            guard refreshing, !still else { return }
            // One finite turn avoids repeatForever's cancellation trap.
            withAnimation(.timingCurve(0.32, 0, 0.14, 1, duration: 0.95)) { spin += 360 }
        }
    }
}

private struct CNActivityPulse: View {
    let color: Color
    let still: Bool
    @State private var pulsing = false
    var body: some View {
        Circle().inset(by: 6).stroke(color, lineWidth: CNNotchLayout.activityStroke)
            .opacity(still ? 1 : pulsing ? 0.3 : 1)
            .onAppear { update() }
            .onChange(of: still) { _, _ in update() }
            .onDisappear { pulsing = false }
    }
    private func update() {
        pulsing = false
        guard !still else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulsing = true }
    }
}
