import AppKit
import SwiftUI

/// The same portrait camera and accessory layers as the static catalog, with
/// independently rendered irises. Sidebar/profile portraits own a visible-only
/// clock; neither an active chat nor a hover is required for pupil tracking.
struct MiloPortraitGazeView: View {
    let look: MiloLook
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionMotionSuppressed) private var motionSuppressed
    @Environment(\.companionSnapshotRendering) private var snapshotRendering
    @AppStorage(CompanionAppearancePreference.idleAnimationsKey) private var idleAnimations = true
    @State private var visible = false

    private var policy: CompanionMotionPolicy {
        .init(reduceMotion: reduceMotion || motionSuppressed || snapshotRendering,
              idleAnimations: idleAnimations, isVisible: visible)
    }
    private var hasLayers: Bool {
        look.supportsPortraitGaze
            && NSImage(named: look.portraitGazeBaseAssetName) != nil
            && NSImage(named: look.portraitGazeEyesAssetName) != nil
    }

    var body: some View {
        Group {
            if hasLayers && !snapshotRendering {
                TimelineView(.animation(minimumInterval: 1 / 24, paused: !policy.allowsPlayback(isIdle: true))) { timeline in
                    MiloGazeArtwork(baseAssetName: look.portraitGazeBaseAssetName,
                                    eyesAssetName: look.portraitGazeEyesAssetName,
                                    sampleDate: timeline.date,
                                    isEnabled: policy.allowsPlayback(isIdle: true),
                                    eyeGeometry: .portrait,
                                    canvasSize: CGSize(width: 550, height: 600))
                        .overlay { LookAccessoryOverlay(look: look, kind: .head) }
                }
            } else {
                LookArtworkView(look: look, kind: .head)
            }
        }
        .background {
            if hasLayers && !snapshotRendering { CompanionVisibilityProbe(isVisible: $visible) }
        }
    }
}
