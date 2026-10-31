import AppKit
import Combine
import SwiftUI

/// Visible Blobatars breathe, blink and track the pointer by default, including
/// small bot avatars. Motion preferences and system Reduce Motion always win.
struct BlobatarLiveView: View {
    let mate: Mate
    let token: String
    let size: CGFloat
    var expression: MateFaceExpression = .idle
    var reactionEvent: MateReactionEvent?
    var interactive = false
    var restsOnSurface = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionMotionSuppressed) private var motionSuppressed
    @Environment(\.companionSnapshotRendering) private var snapshotRendering
    @AppStorage(CompanionAppearancePreference.idleAnimationsKey) private var idleAnimations = true
    @State private var visible = false
    @State private var renderID = UUID().uuidString
    @StateObject private var cursor = BlobatarCursorModel()
    @StateObject private var reactions = MateReactionDriver()

    private var policy: CompanionMotionPolicy {
        .init(reduceMotion: reduceMotion || motionSuppressed || snapshotRendering,
              idleAnimations: idleAnimations, isVisible: visible)
    }
    private var animates: Bool {
        policy.allowsPlayback(isIdle: expression == .idle || expression == .still)
    }

    var body: some View {
        let configuration = BlobatarCharacter.configuration(token: token, mateID: mate.id)
        let renderer = BlobatarNativeRenderer.shared
        Group {
            if snapshotRendering {
                snapshotArtwork(configuration: configuration, renderer: renderer)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !animates && !(reactions.active != nil && policy.allowsTransitions))) { timeline in
                    let figure = renderer.figure(seed: configuration.seed, options: configuration.options)
                    let frame = figure.flatMap {
                        renderer.frame(id: renderID, seed: configuration.seed, options: configuration.options,
                                       expression: BlobatarCharacter.pose(for: expression),
                                       now: timeline.date.timeIntervalSinceReferenceDate * 1000,
                                       animate: animates, target: animates ? cursor.target() : nil, figure: $0)
                    }
                    let reaction = policy.allowsTransitions ? reactions.pose(at: timeline.date) : MateReactionPose()
                    Canvas { context, bounds in
                        guard let figure, let frame else { return }
                        context.concatenate(figure.fittingTransform(in: bounds, restsOnSurface: restsOnSurface))
                        for path in figure.body {
                            context.fill(path.applying(frame.body), with: .color(figure.headColor))
                        }
                        for (index, path) in figure.eyes.enumerated() {
                            let eye = path.applying(frame.eyes[index])
                            let openness = index == 0 ? reaction.leftEyeOpen : reaction.rightEyeOpen
                            let center = eye.boundingRect.midY
                            let blink = CGAffineTransform(translationX: 0, y: center)
                                .scaledBy(x: 1, y: openness)
                                .translatedBy(x: 0, y: -center)
                            context.fill(eye.applying(blink), with: .color(figure.eyeColor))
                        }
                    }
                    .mateReactionTransform(reaction, size: size)
                }
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .background {
            if !snapshotRendering {
                BlobatarCursorProbe(model: cursor)
                CompanionVisibilityProbe(isVisible: $visible)
            }
        }
        .mateReactionTaps(enabled: interactive && policy.allowsTransitions, size: size, driver: reactions)
        .onAppear { offerReaction() }
        .onChange(of: reactionEvent) { _, _ in offerReaction() }
        .onChange(of: policy) { _, updated in
            if updated.reduceMotion { reactions.stop() }
            if !updated.isVisible { renderer.forget(renderID) }
            reactions.deliver(isVisible: updated.isVisible, allowed: updated.allowsTransitions)
        }
        .onDisappear { reactions.stop(); renderer.forget(renderID) }
        .accessibilityLabel("\(mate.name), Blobatar")
    }

    /// ImageRenderer cannot snapshot a live TimelineView/Canvas subtree.
    /// The same upstream paths and transforms render directly for static fixtures.
    private func snapshotArtwork(configuration: BlobatarCharacter.Configuration, renderer: BlobatarNativeRenderer) -> some View {
        let figure = renderer.figure(seed: configuration.seed, options: configuration.options)
        let frame = figure.flatMap {
            renderer.frame(id: renderID, seed: configuration.seed, options: configuration.options,
                           expression: BlobatarCharacter.pose(for: expression), now: 0,
                           animate: false, target: nil, figure: $0)
        }
        return ZStack(alignment: .topLeading) {
            if let figure, let frame {
                ForEach(figure.body.indices, id: \.self) { index in
                    figure.body[index].applying(frame.body)
                        .applying(figure.fittingTransform(in: CGSize(width: size, height: size), restsOnSurface: restsOnSurface))
                        .fill(figure.headColor)
                }
                ForEach(figure.eyes.indices, id: \.self) { index in
                    figure.eyes[index].applying(frame.eyes[index])
                        .applying(figure.fittingTransform(in: CGSize(width: size, height: size), restsOnSurface: restsOnSurface))
                        .fill(figure.eyeColor)
                }
            }
        }
        .frame(width: size, height: size)
    }

    private func offerReaction() {
        reactions.offer(reactionEvent, isVisible: visible, allowed: policy.allowsTransitions)
    }
}

@MainActor
private final class BlobatarCursorModel: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    weak var view: NSView?

    func target() -> [String: Double]? {
        guard let view, let window = view.window,
              window.isVisible, window.occlusionState.contains(.visible),
              !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty else { return nil }
        // Position only; no event monitor, accessibility permission or click capture.
        let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return ["dx": point.x - view.bounds.midX, "dy": point.y - view.bounds.midY,
                "radius": min(view.bounds.width, view.bounds.height) / 2]
    }
}

private struct BlobatarCursorProbe: NSViewRepresentable {
    let model: BlobatarCursorModel
    func makeNSView(context: Context) -> Probe {
        let view = Probe(); model.view = view; return view
    }
    func updateNSView(_ view: Probe, context: Context) { model.view = view }
    final class Probe: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
