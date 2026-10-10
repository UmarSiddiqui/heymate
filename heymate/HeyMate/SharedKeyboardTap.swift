//
//  SharedKeyboardTap.swift
//  HeyMate
//
//  The one listen-only CGEvent tap behind every global keyboard shortcut:
//  hold-to-talk chords and modifier double taps alike. One tap for all of
//  them keeps HeyMate's cost on every keystroke in the system to a single
//  callback, however many shortcuts are switched on.
//

import CoreGraphics
import Foundation

/// Something that reacts to keys pressed anywhere while HeyMate runs.
protocol SharedKeyboardTapListener: AnyObject {
    /// Every flags-changed, key-down and key-up event, on the main thread.
    func keyboardTapReceived(_ type: CGEventType, keyCode: UInt16, flags: CGEventFlags)
    /// The system disabled the tap (it was slow, or secure input took the
    /// keyboard) and it has just been re-enabled. Events in the gap are
    /// gone for good, so state built on them may be stale.
    func keyboardTapResumed()
}

/// A global shortcut that HeyMate switches on and off with Accessibility.
protocol KeyboardShortcutChannel: AnyObject {
    /// Safe to call repeatedly.
    func start()
    func stop()
}

/// Lives on the main run loop, so callbacks arrive on the main thread. The
/// tap is created when the first listener joins (retried on later joins
/// until Accessibility is granted) and torn down when the last one leaves.
final class SharedKeyboardTap {
    static let shared = SharedKeyboardTap()

    private var listeners: [ObjectIdentifier: any SharedKeyboardTapListener] = [:]
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    func add(_ listener: any SharedKeyboardTapListener) {
        listeners[ObjectIdentifier(listener)] = listener
        if tap == nil { install() }
    }

    func remove(_ listener: any SharedKeyboardTapListener) {
        listeners[ObjectIdentifier(listener)] = nil
        if listeners.isEmpty { uninstall() }
    }

    private func install() {
        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    Unmanaged<SharedKeyboardTap>.fromOpaque(userInfo).takeUnretainedValue()
                        .dispatch(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            HeyMateLog.log("⚠️ Global shortcuts: couldn't create the keyboard event tap")
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            HeyMateLog.log("⚠️ Global shortcuts: couldn't create the event tap run loop source")
            return
        }
        self.tap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func uninstall() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
    }

    private func dispatch(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            listeners.values.forEach { $0.keyboardTapResumed() }
            return
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        for listener in listeners.values {
            listener.keyboardTapReceived(type, keyCode: keyCode, flags: flags)
        }
    }
}
