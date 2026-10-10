//
//  ModifierDoubleTapMonitor.swift
//  HeyMate
//
//  Double-tap-a-modifier detection.
//
//  Why a separate monitor rather than a flag on GlobalShortcutMonitor:
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

/// The double-tap rule as a pure state machine, fed modifier changes and
/// key presses with their times. Kept apart from the event tap so the
/// timing rules are tested directly.
nonisolated struct DoubleTapDetector {
    /// Longest a tap may be held and still count as a tap, not a hold.
    var maximumHold: TimeInterval = 0.35
    /// Longest gap between the end of the first tap and the end of the second.
    var maximumGap: TimeInterval = 0.45

    private var heldSince: TimeInterval?
    private var keyPressedDuringHold = false
    private var firstTapEndedAt: TimeInterval?

    /// The required modifier set became exactly held (`true`) or stopped
    /// being held (`false`). Returns true when this release completes a
    /// double tap.
    mutating func modifiersChanged(requiredSetHeld: Bool, at now: TimeInterval) -> Bool {
        if requiredSetHeld {
            guard heldSince == nil else { return false }
            heldSince = now
            keyPressedDuringHold = false
            return false
        }
        guard let pressedAt = heldSince else { return false }
        heldSince = nil
        let isCleanTap = !keyPressedDuringHold && now - pressedAt <= maximumHold
        keyPressedDuringHold = false
        guard isCleanTap else {
            firstTapEndedAt = nil
            return false
        }
        if let firstTapEndedAt, now - firstTapEndedAt <= maximumGap {
            // Start over rather than chain, so three taps read as one double
            // tap plus a stray, not two overlapping doubles.
            self.firstTapEndedAt = nil
            return true
        }
        firstTapEndedAt = now
        return false
    }

    /// A real key went down: whatever is in progress is a chord (ctrl+C),
    /// not a tap.
    mutating func keyPressed() {
        keyPressedDuringHold = heldSince != nil
        firstTapEndedAt = nil
    }

    mutating func reset() {
        self = DoubleTapDetector(maximumHold: maximumHold, maximumGap: maximumGap)
    }
}

/// Publishes each double tap of one configurable modifier set, listening on
/// `SharedKeyboardTap` alongside the hold-to-talk shortcuts.
final class ModifierDoubleTapMonitor: SharedKeyboardTapListener {
    /// Fires once per completed double tap.
    let doubleTapPublisher = PassthroughSubject<Void, Never>()

    /// Both asked on every event, so a change in Settings applies at once.
    private let shortcutProvider: () -> ModifierDoubleTapShortcut
    private let isEnabledProvider: () -> Bool
    private var detector = DoubleTapDetector()

    init(
        shortcutProvider: @escaping () -> ModifierDoubleTapShortcut,
        isEnabledProvider: @escaping () -> Bool
    ) {
        self.shortcutProvider = shortcutProvider
        self.isEnabledProvider = isEnabledProvider
    }

    /// Safe to call repeatedly; the permission poller does.
    func start() {
        SharedKeyboardTap.shared.add(self)
    }

    func stop() {
        SharedKeyboardTap.shared.remove(self)
        detector.reset()
    }

    func keyboardTapReceived(_ type: CGEventType, keyCode: UInt16, flags: CGEventFlags) {
        guard isEnabledProvider() else {
            detector.reset()
            return
        }
        switch type {
        case .keyDown:
            detector.keyPressed()
        case .flagsChanged:
            let held = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(.capsLock)
            let requiredSetHeld = held == shortcutProvider().requiredModifierFlags
            if detector.modifiersChanged(requiredSetHeld: requiredSetHeld, at: ProcessInfo.processInfo.systemUptime) {
                doubleTapPublisher.send(())
            }
        default:
            break
        }
    }

    /// Releases may have been missed while the tap was off; start clean.
    func keyboardTapResumed() {
        detector.reset()
    }
}

/// Persisted configuration for the two double-tap channels: summon the typed ask box, and start a hands-free turn.
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
