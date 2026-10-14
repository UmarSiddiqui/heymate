import AppKit
import SwiftUI

/// System accessibility always wins over decorative preferences.
nonisolated struct CompanionMotionPolicy: Equatable {
    var reduceMotion: Bool
    var idleAnimations: Bool
    var isVisible: Bool

    var allowsTransitions: Bool { !reduceMotion && isVisible }
    func allowsPlayback(isIdle: Bool) -> Bool {
        allowsTransitions && (!isIdle || idleAnimations)
    }
}

nonisolated enum CompanionAppearancePreference {
    static let idleAnimationsKey = "mateIdleAnimationsEnabled"
    static let floatingAgentsKey = "floatingAgentsEnabled"
}

/// A view-local visibility probe. No timers and no animation work in hidden windows.
struct CompanionVisibilityProbe: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.changed = { isVisible = $0 }
        return view
    }
    func updateNSView(_ view: Probe, context: Context) {
        view.changed = { isVisible = $0 }
        view.refresh()
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) {
        view.detach()
    }

    final class Probe: NSView {
        var changed: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastValue: Bool?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            if let window {
                observe(NSWindow.didChangeOcclusionStateNotification, object: window)
                if let clip = enclosingScrollView?.contentView {
                    clip.postsBoundsChangedNotifications = true
                    observe(NSView.boundsDidChangeNotification, object: clip)
                }
            }
            refresh()
        }
        override func viewDidHide() { super.viewDidHide(); refresh() }
        override func viewDidUnhide() { super.viewDidUnhide(); refresh() }
        override func layout() { super.layout(); refresh() }
        func refresh() {
            let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } == true
                && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
            guard visible != lastValue else { return }
            lastValue = visible
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastValue == visible else { return }
                self.changed?(visible)
            }
        }
        private func observe(_ name: Notification.Name, object: AnyObject) {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
    }
}

private struct CompanionMotionSuppressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Containers may suppress motion; this never overrides system Reduce Motion.
    var companionMotionSuppressed: Bool {
        get { self[CompanionMotionSuppressedKey.self] }
        set { self[CompanionMotionSuppressedKey.self] = newValue }
    }
}

private struct CompanionSnapshotRenderingKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    /// Set only by preview and snapshot renderers. Defined in every build so
    /// views can read it; it is always false in the shipping app.
    var companionSnapshotRendering: Bool {
        get { self[CompanionSnapshotRenderingKey.self] }
        set { self[CompanionSnapshotRenderingKey.self] = newValue }
    }
}
