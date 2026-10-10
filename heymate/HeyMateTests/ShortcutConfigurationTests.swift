//
//  ShortcutConfigurationTests.swift
//  HeyMateTests
//
//  Tests for the dual shortcut channels: dictation option persistence and
//  the explicit-option transition overload used by the second CGEvent tap.
//

import AppKit
import CoreGraphics
import Testing
@testable import HeyMate

@MainActor
struct ShortcutConfigurationTests {

    private static let dictateDefaultsKey = "dictateShortcutOption"

    /// Restores the user's real persisted dictate option after the test.
    private func withSavedDictateOption(_ body: () -> Void) {
        let previousRawValue = UserDefaults.standard.string(forKey: Self.dictateDefaultsKey)
        defer {
            if let previousRawValue {
                UserDefaults.standard.set(previousRawValue, forKey: Self.dictateDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.dictateDefaultsKey)
            }
        }
        body()
    }

    // MARK: - Persistence

    @Test func dictateOptionRoundTripsThroughDefaults() {
        withSavedDictateOption {
            PushToTalkShortcut.dictate = .controlOptionSpace
            #expect(PushToTalkShortcut.dictate == .controlOptionSpace)
        }
    }

    @Test func dictateOptionDefaultsToShiftFunctionWhenUnset() {
        withSavedDictateOption {
            UserDefaults.standard.removeObject(forKey: Self.dictateDefaultsKey)
            #expect(PushToTalkShortcut.dictate == .shiftFunction)
        }
    }

    @Test func talkAndDictateDefaultsDiffer() {
        // Collision would make whichever tap registered first win everything.
        withSavedDictateOption {
            UserDefaults.standard.removeObject(forKey: Self.dictateDefaultsKey)
            UserDefaults.standard.removeObject(forKey: "talkShortcutOption")
            #expect(PushToTalkShortcut.talk != PushToTalkShortcut.dictate)
        }
    }

    // MARK: - Explicit-option transitions (dictation channel)

    private func flags(_ modifiers: NSEvent.ModifierFlags) -> UInt64 {
        UInt64(modifiers.rawValue)
    }

    @Test func controlOptionSpacePressesOnSpaceKeyDown() {
        let pressed = PushToTalkShortcut.transition(
            for: .keyDown,
            keyCode: 49,
            modifierFlagsRawValue: flags([.control, .option]),
            wasHeld: false,
            option: .controlOptionSpace
        )
        #expect(pressed == .pressed)
    }

    @Test func controlOptionSpaceReleasesOnKeyUpWithoutModifiers() {
        let released = PushToTalkShortcut.transition(
            for: .keyUp,
            keyCode: 49,
            modifierFlagsRawValue: 0,
            wasHeld: true,
            option: .controlOptionSpace
        )
        #expect(released == .released)
    }

    @Test func shiftFunctionTransitionsViaFlagsChanged() {
        let pressed = PushToTalkShortcut.transition(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: flags([.shift, .function]),
            wasHeld: false,
            option: .shiftFunction
        )
        #expect(pressed == .pressed)

        let released = PushToTalkShortcut.transition(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: flags([.shift]),
            wasHeld: true,
            option: .shiftFunction
        )
        #expect(released == .released)
    }

    @Test func wrongModifiersProduceNoTransition() {
        // Control+Option held while the dictate channel expects Shift+Fn.
        let none = PushToTalkShortcut.transition(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: flags([.control, .option]),
            wasHeld: false,
            option: .shiftFunction
        )
        #expect(none == .none)
    }

    @Test func controlCommandPressesOnFlagsChanged() {
        let pressed = PushToTalkShortcut.transition(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: flags([.control, .command]),
            wasHeld: false,
            option: .controlCommand
        )
        #expect(pressed == .pressed)

        let released = PushToTalkShortcut.transition(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: flags([.control]),
            wasHeld: true,
            option: .controlCommand
        )
        #expect(released == .released)
    }

    @Test func controlCommandDoesNotFireForTalkDefault() {
        let none = PushToTalkShortcut.transition(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: flags([.control, .command]),
            wasHeld: false,
            option: .controlOption
        )
        #expect(none == .none)
    }

    // MARK: - Chat shortcut persistence

    private static let chatDefaultsKey = "chatShortcutOption"

    private func withSavedChatOption(_ body: () -> Void) {
        let previousRawValue = UserDefaults.standard.string(forKey: Self.chatDefaultsKey)
        defer {
            if let previousRawValue {
                UserDefaults.standard.set(previousRawValue, forKey: Self.chatDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.chatDefaultsKey)
            }
        }
        body()
    }

    @Test func chatOptionDefaultsToControlCommandWhenUnset() {
        withSavedChatOption {
            UserDefaults.standard.removeObject(forKey: Self.chatDefaultsKey)
            UserDefaults.standard.removeObject(forKey: "talkShortcutOption")
            #expect(PushToTalkShortcut.chat == .controlCommand)
            #expect(PushToTalkShortcut.chat != PushToTalkShortcut.talk)
        }
    }
}
