//
//  AnnotationClearKeyMonitor.swift
//  HeyMate
//
//  Global Escape watcher. Escape clears on-screen annotations immediately
//  (master spec: "Escape clears"), independent of model state. A
//  PassThroughEventTap, so it needs Accessibility and not Input Monitoring.
//

import AppKit
import CoreGraphics
import Foundation

final class AnnotationClearKeyMonitor {
    private var tap: PassThroughEventTap?
    /// Called on the main thread whenever Escape is pressed anywhere.
    private let onEscape: () -> Void

    init(onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
    }

    deinit {
        tap?.stop()
    }

    func start() {
        guard tap == nil else { return }
        let tap = PassThroughEventTap(name: "Annotation clear monitor", events: [.keyDown]) { [weak self] type, event in
            // Escape keycode is 53.
            guard type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 else { return }
            DispatchQueue.main.async { self?.onEscape() }
        }
        // Without Accessibility there is no tap; the next start() retries.
        if tap.start() { self.tap = tap }
    }

    func stop() {
        tap?.stop()
        tap = nil
    }
}
