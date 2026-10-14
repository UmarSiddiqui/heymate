import SwiftUI

/// Whole-art poses retain each original pack's drawing and identity.
/// Custom user photographs never enter this renderer.
nonisolated struct MateArtworkPose: Equatable {
    var rotation: Double = 0
    var lift: Double = 0
    var scale: Double = 1

    static func sample(assetName: String, expression: MateFaceExpression, elapsed: Double) -> Self {
        guard elapsed.isFinite, elapsed > 0, expression != .still else { return Self() }
        let wave = sin(elapsed * 1.7)
        var pose = Self(lift: wave * 0.008, scale: 1 + wave * 0.006)
        if assetName.hasPrefix("MateFaceSignal") {
            pose.rotation = sin(elapsed * 1.25) * 1.8
            pose.lift = sin(elapsed * 2.1) * 0.012
        } else if assetName.hasPrefix("MateFaceMargin") {
            pose.rotation = sin(elapsed * 1.4) * 1.5
        } else if assetName.hasPrefix("MateFaceInstrument") {
            pose.rotation = sin(elapsed * 2) * 1.2
        }
        switch expression {
        case .thinking: pose.rotation += sin(elapsed * 2.4) * 1.2
        case .reading: pose.lift += 0.01 + sin(elapsed * 1.2) * 0.003
        case .writing: pose.rotation += sin(elapsed * 6) * 0.8
        case .tooling: pose.rotation += sin(elapsed * 9) * 0.6
        case .browsing: pose.rotation += sin(elapsed * 1.1) * 2.4
        case .speaking: pose.lift += sin(elapsed * 8) * 0.006
        case .listening, .guiding: pose.scale += 0.008
        case .attention: pose.rotation += sin(elapsed * 3) * 1.8
        case .success:
            // A brief lift settles rather than bouncing forever on finished cards.
            let progress = min(elapsed / 0.92, 1)
            pose.lift -= sin(progress * .pi) * 0.035
        case .failure:
            pose.rotation += sin(min(elapsed / 0.65, 1) * .pi * 4) * 2
        case .idle, .still: break
        }
        return pose
    }
}

struct MateArtworkMotionView: View {
    let image: Image
    let assetName: String
    let size: CGFloat
    let expression: MateFaceExpression
    var reactionEvent: MateReactionEvent? = nil
    var interactive = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionMotionSuppressed) private var motionSuppressed
    @AppStorage(CompanionAppearancePreference.idleAnimationsKey) private var idleAnimations = true
    #if DEBUG
    @Environment(\.companionSnapshotRendering) private var snapshotRendering
    #endif
    @State private var visible = false
    @State private var hover: CGSize = .zero
    @State private var startedAt = Date()
    @StateObject private var reactions = MateReactionDriver()

    private var policy: CompanionMotionPolicy {
        .init(reduceMotion: reduceMotion || motionSuppressed, idleAnimations: idleAnimations, isVisible: visible)
    }
    private var plays: Bool { policy.allowsPlayback(isIdle: expression == .idle) }
    private var reacting: Bool { reactions.active != nil && policy.allowsTransitions }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !plays && !reacting)) { context in
            let reaction = reacting ? reactions.pose(at: context.date) : MateReactionPose()
            let elapsed = plays ? max(0, context.date.timeIntervalSince(startedAt)) : 0
            let pose = MateArtworkPose.sample(assetName: assetName, expression: expression, elapsed: elapsed)
            let looking = policy.allowsTransitions ? hover : .zero
            image.resizable().interpolation(.high).scaledToFill()
                .frame(width: size, height: size)
                .scaleEffect(pose.scale)
                .rotationEffect(.degrees(pose.rotation + looking.width * 2))
                .offset(x: looking.width * size * 0.012,
                        y: pose.lift * size + looking.height * size * 0.008)
                .frame(width: size, height: size)
                // Clip the art, not the reaction, so a hop leaves the circle.
                .clipShape(Circle())
                .animation(policy.allowsTransitions
                           ? .easeOut(duration: hover == .zero ? 0.28 : 0.2) : nil, value: hover)
                .mateReactionTransform(reaction, size: size)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .mateReactionTaps(enabled: interactive && policy.allowsTransitions, size: size, driver: reactions)
        .onAppear { reactions.offer(reactionEvent, isVisible: visible, allowed: policy.allowsTransitions) }
        .onChange(of: reactionEvent) { _, event in
            reactions.offer(event, isVisible: visible, allowed: policy.allowsTransitions)
        }
        .onChange(of: policy) { _, policy in
            if policy.reduceMotion { reactions.stop() }
            reactions.deliver(isVisible: policy.isVisible, allowed: policy.allowsTransitions)
        }
        .onDisappear { reactions.stop() }
        .background {
            #if DEBUG
            if !snapshotRendering { CompanionVisibilityProbe(isVisible: $visible) }
            #else
            CompanionVisibilityProbe(isVisible: $visible)
            #endif
        }
        .onContinuousHover { phase in
            guard policy.allowsTransitions else { hover = .zero; return }
            switch phase {
            case .active(let point):
                let x = (point.x / size - 0.5) * 2
                let y = (point.y / size - 0.5) * 2
                let length = max(1, hypot(x, y))
                hover = CGSize(width: x / length, height: y / length)
            case .ended: hover = .zero
            }
        }
        .onChange(of: plays) { _, _ in startedAt = Date(); hover = .zero }
        .onChange(of: expression) { _, _ in startedAt = Date() }
        .accessibilityHidden(true)
    }
}
