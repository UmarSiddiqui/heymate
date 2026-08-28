//
//  AnnotationClearKeyMonitor.swift
//  leanring-buddy
//
//  Global listen-only Escape watcher. Escape clears on-screen annotations
//  immediately (master spec: "Escape clears"), independent of model state.
//  Mirrors the CGEvent tap pattern of GlobalPushToTalkShortcutMonitor.
//

import AppKit
import CoreGraphics
import Foundation

final class AnnotationClearKeyMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Called on the main thread whenever Escape is pressed anywhere.
    private let onEscape: () -> Void

    init(onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
    }

    deinit {
        stop()
    }

    func start() {
        guard eventTap == nil else { return }

        let eventMask = CGEventMask(1 << CGEventType.keyDown.rawValue)

        let tapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard eventType == .keyDown, let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            // Escape keycode is 53.
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == 53 {
                let monitor = Unmanaged<AnnotationClearKeyMonitor>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                DispatchQueue.main.async {
                    monitor.onEscape()
                }
            }

            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Annotation clear monitor: couldn't create CGEvent tap (needs Accessibility)")
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            print("⚠️ Annotation clear monitor: couldn't create run loop source")
            return
        }

        self.eventTap = tap
        self.runLoopSource = source

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }
}
