//
//  SpeechTextTests.swift
//  HeyMateTests
//
//  Voices never say "asterisk": markdown is gone before any TTSClient speaks.
//

import Foundation
import Testing
@testable import HeyMate

struct SpeechTextTests {

    @Test func plainSentenceIsUnchanged() {
        #expect(SpeechText.sanitize("Click the blue button.") == "Click the blue button.")
    }

    @Test func emphasisLosesItsMarkers() {
        #expect(SpeechText.sanitize("This is **really** *quite* _neat_ and `fast`.")
            == "This is really quite neat and fast.")
    }

    @Test func noAsteriskSurvives() {
        let reply = "* First thing\n* Second **bold\nA lone * here and ***triple***"
        #expect(!SpeechText.sanitize(reply).contains("*"))
    }

    @Test func bulletsBecomeSentences() {
        let reply = "Two ways:\n- open Settings\n* press the shortcut\n+ ask me"
        #expect(SpeechText.sanitize(reply) == "Two ways: open Settings. press the shortcut. ask me.")
    }

    @Test func headersAndQuotesLoseTheirMarks() {
        #expect(SpeechText.sanitize("## Steps\n> Save first") == "Steps. Save first.")
    }

    @Test func linksSayTheirWordsAndURLsTheirSite() {
        #expect(SpeechText.sanitize("See [the docs](https://example.com/a/b) or https://www.github.com/x?y=1")
            == "See the docs or github.com.")
    }

    @Test func fencesGoButWordsStay() {
        #expect(SpeechText.sanitize("Run this:\n```bash\ngit status\n```") == "Run this: git status.")
    }

    @Test func tablesReadAsLists() {
        let reply = "| Name | Size |\n|---|---|\n| Kokoro | 82M |"
        #expect(SpeechText.sanitize(reply) == "Name, Size. Kokoro, 82M.")
    }

    @Test func symbolsBecomeWords() {
        #expect(SpeechText.sanitize("Tom & Jerry, issue #12, 3 * 4") == "Tom and Jerry, issue number 12, 3 times 4.")
    }

    @Test func emojiAndRulesAreDropped() {
        #expect(SpeechText.sanitize("Done 🎉👍🏽\n---\nNext ❤️") == "Done. Next.")
    }

    @Test func markdownOnlyTextSpeaksNothing() {
        #expect(SpeechText.sanitize("***\n- \n```") == "")
    }
}
