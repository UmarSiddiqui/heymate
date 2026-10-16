import AppKit
import Combine
import SwiftUI

/// Original rendered face and independently rendered irises share one camera.
/// The caller supplies its existing animation clock; this view owns no timer,
/// camera access, or event monitor.
struct MiloGazeArtwork: View {
    let baseAssetName: String
    let eyesAssetName: String
    let sampleDate: Date
    let isEnabled: Bool
    var eyeGeometry = MiloGazeEyeGeometry.standard

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionMotionSuppressed) private var motionSuppressed
    @Environment(\.companionSnapshotRendering) private var snapshotRendering
    @AppStorage(CompanionAppearancePreference.idleAnimationsKey) private var idleAnimations = true
    @StateObject private var cursor = MiloGazeCursorModel()
    @State private var displacement: CGSize = .zero
    @State private var lastSample: Date?

    private var tracksCursor: Bool {
        isEnabled && idleAnimations && !reduceMotion && !motionSuppressed && !snapshotRendering
    }

    var body: some View {
        GeometryReader { geometry in
            let artworkSize = fittedSize(in: geometry.size)
            ZStack {
                Image(baseAssetName)
                    .resizable().interpolation(.high)
                    .frame(width: artworkSize.width, height: artworkSize.height)
                Image(eyesAssetName)
                    .resizable().interpolation(.high)
                    .frame(width: artworkSize.width, height: artworkSize.height)
                    .offset(displacement)
                    .mask(MiloGazeEyeMask(geometry: eyeGeometry))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(width: artworkSize.width, height: artworkSize.height)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .background(MiloGazeCursorProbe(model: cursor))
            .onChange(of: sampleDate, initial: true) { _, date in
                updateGaze(at: date, artworkWidth: artworkSize.width)
            }
            .onChange(of: tracksCursor) { _, enabled in
                if !enabled { resetGaze() }
            }
            .onDisappear { resetGaze() }
        }
    }

    private func fittedSize(in size: CGSize) -> CGSize {
        let scale = min(max(size.width, 0) / 550, max(size.height, 0) / 490)
        return CGSize(width: 550 * scale, height: 490 * scale)
    }

    private func updateGaze(at date: Date, artworkWidth: CGFloat) {
        guard tracksCursor, let direction = cursor.direction() else {
            resetGaze()
            return
        }
        let maximum = min(4, max(0, artworkWidth * 0.025))
        let target = CGSize(width: direction.width * maximum, height: direction.height * maximum)
        let elapsed = lastSample.map { max(0, min(date.timeIntervalSince($0), 0.15)) } ?? 1 / 24
        // A bounded exponential settle follows pointer changes without a new
        // SwiftUI animation on each tick or a jump at the window boundary.
        let amount = 1 - exp(-elapsed / 0.075)
        displacement = CGSize(
            width: displacement.width + (target.width - displacement.width) * amount,
            height: displacement.height + (target.height - displacement.height) * amount
        )
        lastSample = date
    }

    private func resetGaze() {
        displacement = .zero
        lastSample = nil
    }
}

/// Coordinates refer to the shared 550 × 490 render, measured from top-left.
/// Separate masks keep displaced iris pixels inside the white eye contours.
struct MiloGazeEyeGeometry {
    var leftCenter: CGPoint
    var rightCenter: CGPoint
    var eyeSize: CGSize

    static let standard = Self(leftCenter: CGPoint(x: 0.35204625, y: 0.55648434),
                               rightCenter: CGPoint(x: 0.63708532, y: 0.55689162),
                               eyeSize: CGSize(width: 0.26974359, height: 0.36263736))
}

private struct MiloGazeEyeMask: Shape {
    let geometry: MiloGazeEyeGeometry

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for center in [geometry.leftCenter, geometry.rightCenter] {
            let size = CGSize(width: rect.width * geometry.eyeSize.width,
                              height: rect.height * geometry.eyeSize.height)
            path.addEllipse(in: CGRect(x: rect.minX + center.x * rect.width - size.width / 2,
                                       y: rect.minY + center.y * rect.height - size.height / 2,
                                       width: size.width, height: size.height))
        }
        return path
    }
}

@MainActor
private final class MiloGazeCursorModel: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    weak var view: NSView?

    func direction() -> CGSize? {
        guard let view, let window = view.window,
              window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible),
              !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty,
              view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let screenPoint = NSEvent.mouseLocation
        // Sampling is restricted to this app window. Leaving it releases gaze;
        // no other app's interactions are observed or retained.
        guard window.frame.contains(screenPoint) else { return .zero }
        let point = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        let x = (point.x - view.bounds.midX) / max(view.bounds.width, 120)
        let y = (point.y - view.bounds.midY) / max(view.bounds.height, 120)
        let length = max(1, hypot(x, y))
        return CGSize(width: x / length, height: y / length)
    }
}

private struct MiloGazeCursorProbe: NSViewRepresentable {
    let model: MiloGazeCursorModel

    func makeNSView(context: Context) -> MiloGazeProbeView {
        let view = MiloGazeProbeView()
        model.view = view
        return view
    }

    func updateNSView(_ nsView: MiloGazeProbeView, context: Context) {
        model.view = nsView
    }

    static func dismantleNSView(_ nsView: MiloGazeProbeView, coordinator: ()) {
        // No observers, input monitors, or timers to tear down.
    }
}

private final class MiloGazeProbeView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
