//
//  ModifierDoubleTapMonitor.swift
//  leanring-buddy
//
//  Double-tap-a-modifier detection, as its own listen-only CGEvent tap.
//
//  Why a separate monitor rather than a flag on GlobalPushToTalkShortcutMonitor:
//  that monitor's whole contract is press/release for hold-to-talk, and the
//  shortcuts it watches are two-modifier combos. Double-tap modes are the
//  opposite shape — a single modifier, tapped twice, with nothing held — and
//  mixing the two state machines would mean every hold-to-talk press had to
//  first prove it was not the first half of a double tap.
//
//  A tap only counts when the modifier set is pressed and released cleanly:
//  held briefly, with no other key pressed in between. That is what keeps
//  ctrl+C from ever looking like half of a ctrl double tap.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

/// The single-modifier chords that can be double-tapped.
enum ModifierDoubleTapShortcut: String, Hashable, CaseIterable {
    case control
    case controlFunction
    case command
    case option

    var displayText: String {
        switch self {
        case .control: return "ctrl ctrl"
        case .controlFunction: return "fn + ctrl, twice"
        case .command: return "command command"
        case .option: return "option option"
        }
    }

    var keyCapsuleLabels: [String] {
        switch self {
        case .control: return ["ctrl", "ctrl"]
        case .controlFunction: return ["fn", "ctrl", "×2"]
        case .command: return ["cmd", "cmd"]
        case .option: return ["option", "option"]
        }
    }

    /// The exact modifier set that must be held. Exact, not "contains", so
    /// ctrl+command never satisfies the plain-ctrl shortcut.
    var requiredModifierFlags: NSEvent.ModifierFlags {
        switch self {
        case .control: return [.control]
        case .controlFunction: return [.control, .function]
        case .command: return [.command]
        case .option: return [.option]
        }
    }
}

final class ModifierDoubleTapMonitor: ObservableObject {

    /// Fires once per completed double tap.
    let doubleTapPublisher = PassthroughSubject<Void, Never>()

    /// Longest a tap may be held and still count as a tap rather than a hold.
    private static let maximumTapHoldDuration: TimeInterval = 0.35

    /// Longest gap between the two taps.
    private static let maximumGapBetweenTaps: TimeInterval = 0.45

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?

    /// Resolved per event so a shortcut changed in Settings takes effect
    /// without restarting the tap, matching the push-to-talk monitor.
    private let shortcutProvider: () -> ModifierDoubleTapShortcut

    /// Whether this channel is switched on at all. Also resolved per event so
    /// the toggle takes effect immediately.
    private let isEnabledProvider: () -> Bool

    /// All mutated only from the tap callback, which CoreGraphics runs on the
    /// main run loop, so no synchronization is needed.
    private var isModifierSetCurrentlyHeld = false
    private var currentHoldStartedAt: TimeInterval = 0
    private var lastCompletedTapEndedAt: TimeInterval = 0
    /// Set when a key is pressed while the modifier is down, which
    /// disqualifies the hold from counting as a tap.
    private var didPressKeyDuringCurrentHold = false

    init(
        shortcutProvider: @escaping () -> ModifierDoubleTapShortcut,
        isEnabledProvider: @escaping () -> Bool
    ) {
        self.shortcutProvider = shortcutProvider
        self.isEnabledProvider = isEnabledProvider
    }

    deinit {
        stop()
    }

    func start() {
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<ModifierDoubleTapMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            return monitor.handleGlobalEventTap(eventType: eventType, event: event)
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Modifier double tap: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Modifier double tap: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isModifierSetCurrentlyHeld = false
        didPressKeyDuringCurrentHold = false
        lastCompletedTapEndedAt = 0

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard isEnabledProvider() else {
            isModifierSetCurrentlyHeld = false
            return Unmanaged.passUnretained(event)
        }

        if eventType == .keyDown {
            // A real keystroke while the modifier is down means the user is
            // typing a chord, not tapping. Disqualify the whole sequence.
            didPressKeyDuringCurrentHold = true
            lastCompletedTapEndedAt = 0
            return Unmanaged.passUnretained(event)
        }

        guard eventType == .flagsChanged else { return Unmanaged.passUnretained(event) }

        let requiredFlags = shortcutProvider().requiredModifierFlags
        let currentFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)

        let isModifierSetHeldNow = currentFlags == requiredFlags
        guard isModifierSetHeldNow != isModifierSetCurrentlyHeld else {
            return Unmanaged.passUnretained(event)
        }

        let now = ProcessInfo.processInfo.systemUptime
        isModifierSetCurrentlyHeld = isModifierSetHeldNow

        if isModifierSetHeldNow {
            currentHoldStartedAt = now
            didPressKeyDuringCurrentHold = false
            return Unmanaged.passUnretained(event)
        }

        // Released. Decide whether that was a clean tap, and if so whether it
        // completes a pair.
        let holdDuration = now - currentHoldStartedAt
        let wasCleanTap = !didPressKeyDuringCurrentHold && holdDuration <= Self.maximumTapHoldDuration
        didPressKeyDuringCurrentHold = false

        guard wasCleanTap else {
            lastCompletedTapEndedAt = 0
            return Unmanaged.passUnretained(event)
        }

        let gapSincePreviousTap = now - lastCompletedTapEndedAt
        if lastCompletedTapEndedAt > 0, gapSincePreviousTap <= Self.maximumGapBetweenTaps {
            // Reset rather than keep the timestamp, so three taps read as one
            // double tap plus a stray, not two overlapping doubles.
            lastCompletedTapEndedAt = 0
            doubleTapPublisher.send(())
        } else {
            lastCompletedTapEndedAt = now
        }

        return Unmanaged.passUnretained(event)
    }
}

/// Persisted configuration for the two double-tap channels HeyClicky has and
/// HeyMate did not: summon the typed ask box, and start a hands-free turn.
nonisolated enum ModifierDoubleTapPreferences {

    private static let textShortcutKey = "textDoubleTapShortcut"
    private static let textEnabledKey = "textDoubleTapEnabled"
    private static let handsFreeShortcutKey = "handsFreeDoubleTapShortcut"
    private static let handsFreeEnabledKey = "handsFreeDoubleTapEnabled"

    /// Text mode: tap ctrl twice to open the compact chat with the composer
    /// focused. Off by default — a bare ctrl double tap is easy to trigger by
    /// accident, so it is opt-in rather than sprung on existing users.
    static var textShortcut: ModifierDoubleTapShortcut {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: textShortcutKey),
                  let shortcut = ModifierDoubleTapShortcut(rawValue: rawValue) else { return .control }
            return shortcut
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: textShortcutKey) }
    }

    static var isTextShortcutEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: textEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: textEnabledKey) }
    }

    /// Hands-free: tap fn+ctrl twice to start a turn that records until you
    /// stop talking, instead of until you let go of a key.
    static var handsFreeShortcut: ModifierDoubleTapShortcut {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: handsFreeShortcutKey),
                  let shortcut = ModifierDoubleTapShortcut(rawValue: rawValue) else { return .controlFunction }
            return shortcut
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: handsFreeShortcutKey) }
    }

    static var isHandsFreeShortcutEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: handsFreeEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: handsFreeEnabledKey) }
    }
}
