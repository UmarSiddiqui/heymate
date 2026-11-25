//
//  AnnotationClearKeyMonitor.swift
//  HeyMate
//
//  Clears screen marks when Escape is pressed or the content scrolls.
//  Uses the passive Accessibility event tap.
//

import AppKit
import CoreGraphics
import Foundation

final class AnnotationClearKeyMonitor {
    private var tap: PassThroughEventTap?
    private let onEscape: (UInt64) -> Void
    private let onScroll: () -> Void

    init(onEscape: @escaping (UInt64) -> Void, onScroll: @escaping () -> Void) {
        self.onEscape = onEscape
        self.onScroll = onScroll
    }

    deinit {
        tap?.stop()
    }

    func start() {
        guard tap == nil else { return }
        let tap = PassThroughEventTap(name: "Annotation clear monitor", events: [.keyDown, .scrollWheel]) { [weak self] type, event in
            if type == .scrollWheel {
                DispatchQueue.main.async { self?.onScroll() }
            } else if event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                let timestamp = event.timestamp
                DispatchQueue.main.async { self?.onEscape(timestamp) }
            }
        }
        // Without Accessibility there is no tap; the next start() retries.
        if tap.start() { self.tap = tap }
    }

    func stop() {
        tap?.stop()
        tap = nil
    }
}
