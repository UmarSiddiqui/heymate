//
//  SpeechVoiceCatalogTests.swift
//  leanring-buddyTests
//

import AppKit
import AVFoundation
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

    @Test func noveltyAndEloquenceVoicesAreHidden() {
        #expect(SpeechVoiceCatalog.isNoveltyVoiceIdentifier("com.apple.speech.synthesis.voice.Zarvox"))
        #expect(SpeechVoiceCatalog.isNoveltyVoiceIdentifier("com.apple.eloquence.en-US.Reed"))
        #expect(!SpeechVoiceCatalog.isNoveltyVoiceIdentifier("com.apple.siri.natural.en-US-G"))
        #expect(!SpeechVoiceCatalog.isNoveltyVoiceIdentifier("com.apple.voice.premium.en-US.Zoe"))
    }

    @Test func availableVoicesNeverIncludeNoveltyVoices() {
        let voices = SpeechVoiceCatalog.availableSystemVoices()
        #expect(voices.allSatisfy { !SpeechVoiceCatalog.isNoveltyVoiceIdentifier($0.id) })
    }

    @Test func automaticVoiceIsTheBestRankedInstalledVoice() {
        let voices = SpeechVoiceCatalog.availableSystemVoices()
        // Within the user's language, higher quality always sorts first.
        let languagePrefix = String(Locale.current.identifier.prefix(2))
        let sameLanguage = voices.filter { $0.languageCode.hasPrefix(languagePrefix) }
        #expect(zip(sameLanguage, sameLanguage.dropFirst()).allSatisfy { $0.qualityRank >= $1.qualityRank })
        if let best = sameLanguage.first {
            #expect(SpeechVoiceCatalog.bestSystemVoice()?.identifier == best.id)
        }
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

@MainActor
struct KokoroSentenceSplitTests {

    @Test func repliesSplitIntoSentences() {
        let sentences = KokoroTTSClient.splitIntoSentences("Hi there. Click Save, then Done! Ready?")
        #expect(sentences == ["Hi there.", "Click Save, then Done!", "Ready?"])
    }

    @Test func textWithoutPunctuationStaysOneChunk() {
        #expect(KokoroTTSClient.splitIntoSentences("  open the settings  ") == ["open the settings"])
        #expect(KokoroTTSClient.splitIntoSentences("   ").isEmpty)
    }

    @Test func edgeSilenceIsTrimmedToANaturalPause() {
        // 1 kHz sample rate: one sample per millisecond.
        let samples = [Float](repeating: 0, count: 400) + [Float](repeating: 0.5, count: 100) + [Float](repeating: 0, count: 500)
        let trimmed = KokoroTTSClient.trimmingEdgeSilence((samples, 1000))
        #expect(trimmed.samples.count == 30 + 100 + 170)
        #expect(KokoroTTSClient.edgeSilenceMilliseconds(trimmed) == (30, 170))
    }

    @Test func silentAudioIsLeftAlone() {
        let silence = [Float](repeating: 0, count: 200)
        #expect(KokoroTTSClient.trimmingEdgeSilence((silence, 1000)).samples.count == 200)
    }
}
