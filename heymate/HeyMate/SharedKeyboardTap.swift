//
//  SharedKeyboardTap.swift
//  HeyMate
//
//  The one CGEvent tap behind every global keyboard shortcut:
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

/// Callbacks arrive on the main thread, in the order the keys were pressed.
/// The tap is created when the first listener joins (retried on later joins
/// until Accessibility is granted) and torn down when the last one leaves.
/// It is an active tap that passes every event through unchanged, which
/// needs only Accessibility; a listen-only tap would need Input Monitoring.
final class SharedKeyboardTap {
    static let shared = SharedKeyboardTap()

    private var listeners: [ObjectIdentifier: any SharedKeyboardTapListener] = [:]

    private let tap = PassThroughEventTap(
        name: "Global shortcuts",
        events: [.flagsChanged, .keyDown, .keyUp],
        onResume: {
            DispatchQueue.main.async { SharedKeyboardTap.shared.resumed() }
        },
        handler: { type, event in
            // Runs while the key press waits: copy two fields and move on.
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            DispatchQueue.main.async {
                SharedKeyboardTap.shared.deliver(type, keyCode: keyCode, flags: flags)
            }
        }
    )

    private init() {}

    func add(_ listener: any SharedKeyboardTapListener) {
        listeners[ObjectIdentifier(listener)] = listener
        if !tap.isRunning { tap.start() }
    }

    func remove(_ listener: any SharedKeyboardTapListener) {
        listeners[ObjectIdentifier(listener)] = nil
        if listeners.isEmpty { tap.stop() }
    }

    private func deliver(_ type: CGEventType, keyCode: UInt16, flags: CGEventFlags) {
        for listener in listeners.values {
            listener.keyboardTapReceived(type, keyCode: keyCode, flags: flags)
        }
    }

    private func resumed() {
        listeners.values.forEach { $0.keyboardTapResumed() }
    }
}
