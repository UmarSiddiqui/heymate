//
//  PushToTalkShortcut.swift
//  HeyMate
//
//  The held-key chords that drive voice: Talk, Dictate, spatial select and
//  the notch chat. Each is either a pair of modifiers (fires on flagsChanged)
//  or a pair of modifiers plus Space (fires on the Space key). Choices are
//  persisted under fixed keys, so renaming anything here must keep the raw
//  values and keys stable.
//

import AppKit
import CoreGraphics

nonisolated enum PushToTalkShortcut {

    /// Declaration order is the order Settings lists them in.
    enum Option: String, Hashable, CaseIterable {
        case controlOption
        case controlCommand
        case shiftFunction
        case shiftControl
        case controlOptionSpace
        case shiftControlSpace

        static let allOptions = allCases

        var keyCapsuleLabels: [String] {
            switch self {
            case .controlOption: return ["ctrl", "option"]
            case .controlCommand: return ["ctrl", "command"]
            case .shiftFunction: return ["shift", "fn"]
            case .shiftControl: return ["shift", "control"]
            case .controlOptionSpace: return ["ctrl", "option", "space"]
            case .shiftControlSpace: return ["shift", "control", "space"]
            }
        }

        var displayText: String {
            switch self {
            case .controlOption: return "ctrl + option"
            case .controlCommand: return "ctrl + command"
            case .shiftFunction: return "shift + fn"
            default: return keyCapsuleLabels.joined(separator: " + ")
            }
        }

        /// The modifiers that must be down for the chord.
        fileprivate var modifiers: NSEvent.ModifierFlags {
            switch self {
            case .controlOption, .controlOptionSpace: return [.control, .option]
            case .controlCommand: return [.control, .command]
            case .shiftFunction: return [.shift, .function]
            case .shiftControl, .shiftControlSpace: return [.shift, .control]
            }
        }

        /// Whether the chord ends with Space rather than being modifiers only.
        fileprivate var includesSpace: Bool {
            self == .controlOptionSpace || self == .shiftControlSpace
        }
    }

    enum Transition {
        case none
        case pressed
        case released
    }

    // MARK: - Saved choices

    static var talk: Option {
        get { stored("talkShortcutOption", default: .controlOption) }
        set { store(newValue, "talkShortcutOption") }
    }

    /// Contextual dictation. Should differ from Talk; if both match, whichever
    /// event tap sees the press first wins.
    static var dictate: Option {
        get { stored("dictateShortcutOption", default: .shiftFunction) }
        set { store(newValue, "dictateShortcutOption") }
    }

    /// Held while the user draws a region on screen to use as context.
    static var spatialSelect: Option {
        get { stored("spatialSelectShortcutOption", default: .shiftControl) }
        set { store(newValue, "spatialSelectShortcutOption") }
    }

    /// Toggles the compact notch chat; a press, not a hold.
    static var chat: Option {
        get { stored("chatShortcutOption", default: .controlCommand) }
        set { store(newValue, "chatShortcutOption") }
    }

    private static func stored(_ key: String, default fallback: Option) -> Option {
        UserDefaults.standard.string(forKey: key).flatMap(Option.init(rawValue:)) ?? fallback
    }

    private static func store(_ option: Option, _ key: String) {
        UserDefaults.standard.set(option.rawValue, forKey: key)
    }

    // MARK: - Matching

    private static let spaceKeyCode: UInt16 = 49

    /// What a keyboard event means for `option`, given whether the chord was
    /// already held. Modifier-only chords press when all their modifiers are
    /// down (extra ones are fine) and release when any lifts. Space chords
    /// press on Space with the modifiers down and release when Space comes
    /// up, whatever the modifiers are doing by then.
    static func transition(
        for eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        wasHeld: Bool,
        option: Option
    ) -> Transition {
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)
        let modifiersDown = modifiers.isSuperset(of: option.modifiers)

        if !option.includesSpace {
            guard eventType == .flagsChanged, modifiersDown != wasHeld else { return .none }
            return modifiersDown ? .pressed : .released
        }

        guard keyCode == spaceKeyCode else { return .none }
        switch eventType {
        case .keyDown where modifiersDown && !wasHeld: return .pressed
        case .keyUp where wasHeld: return .released
        default: return .none
        }
    }

    /// Reads the live keyboard state rather than waiting for an event. The
    /// event tap can miss a key-up (timeout, secure input, a tap restart), so
    /// the monitor polls this while a chord is held and treats "not held" as
    /// a release.
    static func isHeld(_ option: Option) -> Bool {
        let liveFlags = CGEventSource.flagsState(.combinedSessionState).rawValue
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(liveFlags))
            .intersection(.deviceIndependentFlagsMask)
        guard modifiers.isSuperset(of: option.modifiers) else { return false }
        return !option.includesSpace
            || CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(spaceKeyCode))
    }
}
