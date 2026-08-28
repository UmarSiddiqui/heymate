//
//  SpeechVoiceCatalogElevenLabsTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct SpeechVoiceCatalogElevenLabsTests {

    /// Every listed id ends up in the Worker's upstream URL path, which
    /// validates against this same pattern before interpolating it.
    @Test func everyListedVoiceIDIsAcceptedByTheWorkerPattern() {
        for voice in SpeechVoiceCatalog.elevenLabsPremadeVoices {
            #expect(SpeechVoiceCatalog.isValidElevenLabsVoiceID(voice.id))
        }
    }

    @Test func listedVoiceIDsAreUnique() {
        let identifiers = SpeechVoiceCatalog.elevenLabsPremadeVoices.map(\.id)
        #expect(Set(identifiers).count == identifiers.count)
    }

    /// The one Australian voice on the free plan. Named rather than left to
    /// the Worker default, which was a library voice a free account cannot
    /// use at all.
    @Test func australianVoiceIsListed() {
        let australianVoices = SpeechVoiceCatalog.elevenLabsPremadeVoices
            .filter { $0.accent == "australian" }
        #expect(australianVoices.map(\.name) == ["Charlie"])
        #expect(australianVoices.first?.id == "IKne3meq5aSn9XLyUdCD")
    }

    /// The custom tag must never be mistaken for a voice id, or selecting it
    /// would send "custom-voice-id" upstream as a voice.
    @Test func customSelectionTagIsNotAValidVoiceID() {
        #expect(
            SpeechVoiceCatalog.isValidElevenLabsVoiceID(
                SpeechVoiceCatalog.customElevenLabsVoiceSelectionTag
            ) == false
        )
        #expect(SpeechVoiceCatalog.premadeVoice(
            withID: SpeechVoiceCatalog.customElevenLabsVoiceSelectionTag
        ) == nil)
    }

    @Test func storedIDDecidesWhatThePickerShows() {
        #expect(SpeechVoiceCatalog.elevenLabsPickerSelection(forStoredVoiceID: "") == "")
        #expect(SpeechVoiceCatalog.elevenLabsPickerSelection(forStoredVoiceID: "   ") == "")
        #expect(
            SpeechVoiceCatalog.elevenLabsPickerSelection(forStoredVoiceID: "IKne3meq5aSn9XLyUdCD")
                == "IKne3meq5aSn9XLyUdCD"
        )
    }

    /// A cloned or library voice has a per-account id that cannot be listed,
    /// so it has to land on the custom row rather than silently reset to the
    /// server default.
    @Test func unknownStoredIDLandsOnTheCustomRow() {
        #expect(
            SpeechVoiceCatalog.elevenLabsPickerSelection(forStoredVoiceID: "kPzsL2i3teMYv0FxEYQ6")
                == SpeechVoiceCatalog.customElevenLabsVoiceSelectionTag
        )
    }
}
