//
//  ShortcutConfigurationTests.swift
//  leanring-buddyTests
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
            BuddyPushToTalkShortcut.currentDictateOption = .controlOptionSpace
            #expect(BuddyPushToTalkShortcut.currentDictateOption == .controlOptionSpace)
        }
    }

    @Test func dictateOptionDefaultsToShiftFunctionWhenUnset() {
        withSavedDictateOption {
            UserDefaults.standard.removeObject(forKey: Self.dictateDefaultsKey)
            #expect(BuddyPushToTalkShortcut.currentDictateOption == .shiftFunction)
        }
    }

    @Test func talkAndDictateDefaultsDiffer() {
        // Collision would make whichever tap registered first win everything.
        withSavedDictateOption {
            UserDefaults.standard.removeObject(forKey: Self.dictateDefaultsKey)
            UserDefaults.standard.removeObject(forKey: "talkShortcutOption")
            #expect(BuddyPushToTalkShortcut.currentShortcutOption != BuddyPushToTalkShortcut.currentDictateOption)
        }
    }

    // MARK: - Explicit-option transitions (dictation channel)

    private func flags(_ modifiers: NSEvent.ModifierFlags) -> UInt64 {
        UInt64(modifiers.rawValue)
    }

    @Test func controlOptionSpacePressesOnSpaceKeyDown() {
        let pressed = BuddyPushToTalkShortcut.shortcutTransition(
            for: .keyDown,
            keyCode: 49,
            modifierFlagsRawValue: flags([.control, .option]),
            wasShortcutPreviouslyPressed: false,
            option: .controlOptionSpace
        )
        #expect(pressed == .pressed)
    }

    @Test func controlOptionSpaceReleasesOnKeyUpWithoutModifiers() {
        let released = BuddyPushToTalkShortcut.shortcutTransition(
            for: .keyUp,
            keyCode: 49,
            modifierFlagsRawValue: 0,
            wasShortcutPreviouslyPressed: true,
            option: .controlOptionSpace
        )
        #expect(released == .released)
    }

    @Test func shiftFunctionTransitionsViaFlagsChanged() {
        let pressed = BuddyPushToTalkShortcut.shortcutTransition(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: flags([.shift, .function]),
            wasShortcutPreviouslyPressed: false,
            option: .shiftFunction
        )
        #expect(pressed == .pressed)

        let released = BuddyPushToTalkShortcut.shortcutTransition(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: flags([.shift]),
            wasShortcutPreviouslyPressed: true,
            option: .shiftFunction
        )
        #expect(released == .released)
    }

    @Test func wrongModifiersProduceNoTransition() {
        // Control+Option held while the dictate channel expects Shift+Fn.
        let none = BuddyPushToTalkShortcut.shortcutTransition(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: flags([.control, .option]),
            wasShortcutPreviouslyPressed: false,
            option: .shiftFunction
        )
        #expect(none == .none)
    }

    @Test func controlCommandPressesOnFlagsChanged() {
        let pressed = BuddyPushToTalkShortcut.shortcutTransition(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: flags([.control, .command]),
            wasShortcutPreviouslyPressed: false,
            option: .controlCommand
        )
        #expect(pressed == .pressed)

        let released = BuddyPushToTalkShortcut.shortcutTransition(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: flags([.control]),
            wasShortcutPreviouslyPressed: true,
            option: .controlCommand
        )
        #expect(released == .released)
    }

    @Test func controlCommandDoesNotFireForTalkDefault() {
        let none = BuddyPushToTalkShortcut.shortcutTransition(
            for: .flagsChanged,
            keyCode: 0,
            modifierFlagsRawValue: flags([.control, .command]),
            wasShortcutPreviouslyPressed: false,
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
            #expect(BuddyPushToTalkShortcut.currentChatOption == .controlCommand)
            #expect(BuddyPushToTalkShortcut.currentChatOption != BuddyPushToTalkShortcut.currentShortcutOption)
        }
    }
}
