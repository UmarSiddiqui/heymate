import SwiftUI

/// The six colour mates' body colours, shared by the live face and the
/// notch character so a mate wears the same colour everywhere.
enum MateFacePalette {
    static let ink = Color(red: 0.22, green: 0.18, blue: 0.23)

    static func color(for assetName: String) -> Color {
        switch assetName {
        case "MateFacePeach": return Color(red: 0.98, green: 0.77, blue: 0.65)
        case "MateFaceSky": return Color(red: 0.64, green: 0.82, blue: 0.94)
        case "MateFaceButter": return Color(red: 0.97, green: 0.87, blue: 0.58)
        case "MateFaceMint": return Color(red: 0.64, green: 0.86, blue: 0.76)
        case "MateFaceBlush": return Color(red: 0.95, green: 0.71, blue: 0.77)
        default: return Color(red: 0.82, green: 0.73, blue: 0.93)
        }
    }

    /// A colour mate keeps its own colour. Drawn packs and photos have no
    /// single body colour, so they borrow one of the six by id.
    static func color(forMateAsset assetName: String, mateID: UUID) -> Color {
        if MateFace.fillsFrame(assetName) { return color(for: assetName) }
        let index = MateFace.index(for: mateID) % 6
        return color(for: MateFace.legacyAssetNames[index])
    }
}

/// Original vector rig for the six color mates. Photos and drawn packs keep their art.
struct MateLiveFace: View {
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
    @State private var gaze: CGSize = .zero
    @State private var startedAt = Date()
    @StateObject private var reactions = MateReactionDriver()

    private var policy: CompanionMotionPolicy {
        .init(reduceMotion: reduceMotion || motionSuppressed, idleAnimations: idleAnimations, isVisible: visible)
    }
    private var plays: Bool { policy.allowsPlayback(isIdle: expression == .idle) }
    private var reacting: Bool { reactions.active != nil && policy.allowsTransitions }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !plays && !reacting)) { context in
            let elapsed = plays ? max(0, context.date.timeIntervalSince(startedAt)) : 0
            let pose = reacting ? reactions.pose(at: context.date) : MateReactionPose()
            AnimatedFaceCanvas(assetName: assetName, expression: expression, elapsed: elapsed,
                               reaction: pose, gaze: policy.allowsTransitions ? gaze : .zero)
                .animation(policy.allowsTransitions
                           ? .easeOut(duration: gaze == .zero ? 0.28 : 0.2) : nil, value: gaze)
                .mateReactionTransform(pose, size: size)
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
            guard policy.allowsTransitions else { gaze = .zero; return }
            switch phase {
            case .active(let point):
                let x = (point.x / size - 0.5) * 2
                let y = (point.y / size - 0.5) * 2
                let length = max(1, hypot(x, y))
                gaze = CGSize(width: x / length, height: y / length)
            case .ended: gaze = .zero
            }
        }
        .onChange(of: plays) { _, _ in startedAt = Date(); gaze = .zero }
        .onChange(of: expression) { _, _ in startedAt = Date() }
        .accessibilityHidden(!interactive)
        .accessibilityElement()
        .accessibilityAddTraits(interactive ? .isButton : .isImage)
        .accessibilityHint(interactive ? "Click to say hello." : "")
        .accessibilityAction { if interactive && policy.allowsTransitions { reactions.play(.wink) } }
    }

    /// Animatable input lets gaze ease independently of the idle timeline.
    /// Pointer feedback still works when the user disables idle animation.
    private struct AnimatedFaceCanvas: View, Animatable {
        let assetName: String
        let expression: MateFaceExpression
        let elapsed: Double
        let reaction: MateReactionPose
        var gaze: CGSize

        var animatableData: AnimatablePair<CGFloat, CGFloat> {
            get { AnimatablePair(gaze.width, gaze.height) }
            set { gaze = CGSize(width: newValue.first, height: newValue.second) }
        }

        var body: some View {
            Canvas { context, canvasSize in
                draw(in: &context, size: canvasSize, elapsed: elapsed)
            }
        }

        private var color: Color { MateFacePalette.color(for: assetName) }

        /// Smile depth: lower is a frown, 0.63 is a flat line.
        private var mouthCurve: Double {
            switch expression {
            case .failure: return 0.58
            case .reading, .writing, .tooling: return 0.65
            default: return 0.68
            }
        }

        private func draw(in context: inout GraphicsContext, size: CGSize, elapsed: Double) {
            let s = size.width
            let ink = MateFacePalette.ink
            let breathe = elapsed == 0 ? 0 : sin(elapsed * 1.7) * s * 0.009
            context.translateBy(x: 0, y: breathe)
            context.fill(Path(ellipseIn: CGRect(x: s * 0.025, y: s * 0.025, width: s * 0.95, height: s * 0.95)),
                         with: .linearGradient(Gradient(colors: [color.opacity(0.85), color]),
                                               startPoint: .zero, endPoint: CGPoint(x: s, y: s)))
            let blinkPhase = elapsed.truncatingRemainder(dividingBy: 4.7)
            let blink = elapsed > 0 && blinkPhase > 4.51
                ? max(0.06, abs((blinkPhase - 4.605) / 0.095)) : 1
            // Work looks steer the eyes on top of the pointer's gaze.
            var looking = gaze
            switch expression {
            case .reading: looking.height += 0.9
            case .writing: looking.height += 0.8; looking.width -= 0.4
            case .browsing: looking.width += elapsed == 0 ? 0 : sin(elapsed * 2.2) * 0.9
            default: break
            }
            let eyeY = s * (expression == .thinking ? 0.46 : 0.49) + looking.height * s * 0.025
            let eyeHeight = s * (expression == .success ? 0.055 : 0.105) * blink
            for (index, x) in [0.35, 0.65].enumerated() {
                var open = index == 0 ? reaction.leftEyeOpen : reaction.rightEyeOpen
                if expression == .tooling && index == 1 { open *= 0.6 }
                let height = eyeHeight * max(0.06, open)
                let rect = CGRect(x: s * x - s * 0.043 + looking.width * s * 0.035,
                                  y: eyeY - height / 2, width: s * 0.086, height: height)
                context.fill(Path(ellipseIn: rect), with: .color(ink))
            }
            for x in [0.24, 0.76] {
                context.fill(Path(ellipseIn: CGRect(x: s * x - s * 0.065, y: s * 0.57,
                                                   width: s * 0.13, height: s * 0.065)),
                             with: .color(Color.pink.opacity(0.23 + 0.4 * reaction.flush)))
            }
            var mouth = Path()
            if expression == .speaking || expression == .listening || expression == .attention {
                let opening = expression == .speaking && elapsed > 0 ? 0.055 + 0.045 * abs(sin(elapsed * 9)) : 0.07
                mouth.addEllipse(in: CGRect(x: s * 0.465, y: s * 0.61, width: s * 0.07, height: s * opening))
                context.fill(mouth, with: .color(ink))
            } else {
                mouth.move(to: CGPoint(x: s * 0.45, y: s * 0.63))
                mouth.addQuadCurve(to: CGPoint(x: s * 0.55, y: s * 0.63),
                                   control: CGPoint(x: s * 0.50, y: s * mouthCurve))
                context.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: max(1, s * 0.014), lineCap: .round))
            }
            if [.thinking, .attention, .failure, .tooling, .writing].contains(expression) {
                var brow = Path()
                brow.move(to: CGPoint(x: s * 0.60, y: s * 0.36))
                brow.addLine(to: CGPoint(x: s * 0.70, y: s * 0.34))
                context.stroke(brow, with: .color(ink.opacity(0.7)), style: StrokeStyle(lineWidth: max(1, s * 0.014), lineCap: .round))
            }
        }
    }
}
