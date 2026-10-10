//
//  OverlayWindow.swift
//  HeyMate
//
//  The transparent, click-through windows the floating cursor and on-screen
//  drawings live in, one per display, and the manager that shows and hides
//  them. The manager also runs spatial selection: for one drag it lets the
//  overlay under the pointer take mouse events and records the shape drawn.
//

import AppKit
import SwiftUI

/// A borderless, clear window covering one screen. It sits above menus and
/// pop-ups, follows the user across Spaces and full-screen apps, and never
/// takes focus or clicks.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayWindowManager {
    private var windows: [OverlayWindow] = []
    /// The first overlay of a launch plays the welcome; later ones don't.
    var hasShownOverlayBefore = false

    func isShowingOverlay() -> Bool {
        !windows.isEmpty
    }

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        hideOverlay()
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        for screen in screens {
            let window = OverlayWindow(screen: screen)
            // Applies the "Show in screen recordings" preference to it.
            AppPresencePreferences.shared.registerAmbientWindow(window)

            let hostingView = NSHostingView(rootView: CompanionCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager
            ))
            // The window is sized once; don't let SwiftUI layout resize it.
            hostingView.sizingOptions = []
            hostingView.frame = screen.frame
            window.contentView = hostingView

            windows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
    }

    // MARK: - Spatial selection

    private struct SpatialCapture {
        let window: OverlayWindow
        let screenFrame: CGRect
        let draftChanged: ([CGPoint]) -> Void
        let completion: (CGRect?, SpatialGeometry.NormalizedSelection?) -> Void
        var points: [CGPoint] = []
        var monitors: [Any] = []
    }

    private var spatialCapture: SpatialCapture?

    /// True from the press until the gesture is finished or discarded.
    var isSpatialCaptureActive: Bool { spatialCapture != nil }

    /// Lets the overlay under the pointer receive the mouse and records the
    /// freehand drag in its top-left coordinates. `completion` gets the
    /// screen frame and the normalized selection, or two nils when nothing
    /// usable was drawn. A discarded gesture calls nothing.
    func beginSpatialCapture(
        draftChanged: @escaping ([CGPoint]) -> Void,
        completion: @escaping (CGRect?, SpatialGeometry.NormalizedSelection?) -> Void
    ) {
        guard spatialCapture == nil else { return }

        let mouse = NSEvent.mouseLocation
        guard let window = windows.first(where: { $0.screen?.frame.contains(mouse) ?? false }) ?? windows.first,
              let screenFrame = window.screen?.frame
        else {
            completion(nil, nil)
            return
        }

        window.ignoresMouseEvents = false
        var capture = SpatialCapture(
            window: window,
            screenFrame: screenFrame,
            draftChanged: draftChanged,
            completion: completion
        )

        let local = { (point: NSPoint) in
            CGPoint(x: point.x - screenFrame.minX, y: screenFrame.maxY - point.y)
        }
        let drag = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] event in
            guard let self, event.window === window, self.spatialCapture != nil else { return event }
            self.spatialCapture?.points.append(local(event.locationInWindow))
            if let capture = self.spatialCapture { capture.draftChanged(capture.points) }
            return event
        }
        let release = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self, event.window === window, let capture = self.spatialCapture else { return event }
            if !capture.points.isEmpty {
                self.spatialCapture?.points.append(local(event.locationInWindow))
            }
            self.finishSpatialCapture()
            return event
        }
        capture.monitors = [drag, release].compactMap { $0 }
        spatialCapture = capture
    }

    /// Finishes the gesture with whatever has been drawn so far.
    func finishSpatialCapture() {
        guard let capture = spatialCapture else { return }
        let outline = SpatialGeometry.ramerDouglasPeucker(points: capture.points, epsilon: 3.0)
        let selection = SpatialGeometry.normalize(polygonScreenLocal: outline, frameSize: capture.screenFrame.size)
        endSpatialCapture()
        capture.completion(selection == nil ? nil : capture.screenFrame, selection)
    }

    /// Discards the gesture and makes the overlay click-through again.
    func endSpatialCapture() {
        guard let capture = spatialCapture else { return }
        capture.monitors.forEach(NSEvent.removeMonitor)
        capture.window.ignoresMouseEvents = true
        spatialCapture = nil
    }
}
