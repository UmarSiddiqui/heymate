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

/// 2026-11-01: "Your five-photo scrapbook is ready: [Open the scrapbook PDF](file:///Users/…)"
/// showed raw in the notch and paths were read aloud slash by slash.
struct PathSpeechAndCaptionTests {
    private let reply = "Your five-photo scrapbook is ready:\n\n[Open the scrapbook PDF](file:///Users/umarsiddiqui/Projects/heymate/scrapbook-designer/output/AB-photoshoot-scrapbook.pdf)"

    @Test func captionShowsLinkLabelNotMarkdown() {
        let shown = CaptionText.display(reply)
        #expect(shown.contains("Open the scrapbook PDF"))
        #expect(!shown.contains("file://"))
        #expect(!shown.contains("]("))
        #expect(CaptionText.display("Saved to file:///Users/me/out/report.pdf") == "Saved to report.pdf")
    }

    @Test func pathsAreSpokenAsFileNames() {
        let spoken = SpeechText.sanitize("Saved it to /Users/umarsiddiqui/Projects/heymate/output/AB-photoshoot-scrapbook.pdf and ~/Desktop/notes.txt")
        #expect(spoken.contains("AB-photoshoot-scrapbook.pdf"))
        #expect(spoken.contains("notes.txt"))
        #expect(!spoken.contains("/"))
        #expect(SpeechText.sanitize("Open file:///Users/me/out/report.pdf now").contains("report.pdf now"))
        #expect(!SpeechText.sanitize(reply).contains("/"))
    }

    @Test func slashesThatAreNotPathsStay() {
        #expect(SpeechText.fileNamesForPaths("and/or 10/31/2026 km/h") == "and/or 10/31/2026 km/h")
    }
}
