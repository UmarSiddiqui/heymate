//
//  SpeechVoiceCatalogTests.swift
//  leanring-buddyTests
//

import AppKit
import Foundation
import Testing
@testable import HeyMate

struct SpeechVoiceCatalogTests {

    @Test func voiceIDsThatCouldSteerTheUpstreamURLAreRejected() {
        // The Worker interpolates this into a path, so anything with a slash,
        // a dot, or a query character has to be refused before it is sent.
        #expect(!SpeechVoiceCatalog.isValidElevenLabsVoiceID("../../v1/user"))
        #expect(!SpeechVoiceCatalog.isValidElevenLabsVoiceID("abc/def"))
        #expect(!SpeechVoiceCatalog.isValidElevenLabsVoiceID("abc?stream=true"))
        #expect(!SpeechVoiceCatalog.isValidElevenLabsVoiceID("abc def"))
        #expect(!SpeechVoiceCatalog.isValidElevenLabsVoiceID(""))
    }

    @Test func ordinaryVoiceIDsAreAccepted() {
        #expect(SpeechVoiceCatalog.isValidElevenLabsVoiceID("21m00Tcm4TlvDq8ikWAM"))
        #expect(SpeechVoiceCatalog.isValidElevenLabsVoiceID("Cedar1"))
    }
}

struct ModifierDoubleTapShortcutTests {

    @Test func eachShortcutRequiresAnExactModifierSet() {
        // Exactness is what stops ctrl+command from satisfying plain ctrl.
        #expect(ModifierDoubleTapShortcut.control.requiredModifierFlags == [.control])
        #expect(ModifierDoubleTapShortcut.controlFunction.requiredModifierFlags == [.control, .function])
        #expect(ModifierDoubleTapShortcut.control.requiredModifierFlags != ModifierDoubleTapShortcut.controlFunction.requiredModifierFlags)
    }

    @Test func everyShortcutHasLabelsToRender() {
        for shortcut in ModifierDoubleTapShortcut.allCases {
            #expect(!shortcut.displayText.isEmpty)
            #expect(!shortcut.keyCapsuleLabels.isEmpty)
        }
    }
}
