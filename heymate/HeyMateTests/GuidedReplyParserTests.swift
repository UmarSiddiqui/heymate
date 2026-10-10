//
//  GuidedReplyParserTests.swift
//  HeyMateTests
//
import CoreGraphics
import Foundation
import Testing
@testable import HeyMate

struct GuidedReplyParserTests {
    @Test func singleTrailingPointStaysOneStep() {
        let reply = GuidedReplyParser.parse("click the color inspector up top. [POINT:1100,42:color inspector]")
        #expect(reply.steps.count == 1)
        #expect(reply.steps[0].displayText == "click the color inspector up top.")
        #expect(reply.steps[0].pointing?.coordinate == CGPoint(x: 1100, y: 42))
        #expect(reply.pointingStepCount == 1)
    }

    @Test func severalPointsBecomeOrderedSteps() {
        let reply = GuidedReplyParser.parse(
            "that's play [POINT:640,980:play] and this scrubs [POINT:900,980:timeline] and the gear sets quality [POINT:1500,980:settings]"
        )
        #expect(reply.steps.map(\.displayText) == [
            "that's play",
            "and this scrubs",
            "and the gear sets quality"
        ])
        #expect(reply.steps.map { $0.pointing?.elementLabel } == ["play", "timeline", "settings"])
        #expect(reply.pointingStepCount == 3)
        #expect(reply.spokenText == "that's play and this scrubs and the gear sets quality")
    }

    @Test func bunchedTagsShareTheSentenceClauseByClause() {
        // Seen live: one sentence, then every tag at the end.
        let reply = GuidedReplyParser.parse(
            "the back button returns to the previous page, reload loads the current page again, and the star saves the page as a bookmark. [POINT:10,60:back button] [POINT:80,60:reload button] [POINT:1170,60:bookmark star]"
        )
        #expect(reply.steps.map(\.displayText) == [
            "the back button returns to the previous page",
            "reload loads the current page again",
            "and the star saves the page as a bookmark."
        ])
        #expect(reply.steps.map { $0.pointing?.elementLabel } == ["back button", "reload button", "bookmark star"])
    }

    @Test func bunchedTagsStayTogetherWhenPartsDoNotMatch() {
        let reply = GuidedReplyParser.parse("these two do the same thing. [POINT:1,1:a] [POINT:2,2:b]")
        #expect(reply.steps.count == 2)
        #expect(reply.steps[0].displayText == "these two do the same thing.")
        #expect(reply.steps[1].displayText.isEmpty)
    }

    @Test func textAfterLastPointIsItsOwnUnpointedStep() {
        let reply = GuidedReplyParser.parse("open file [POINT:10,10:file] and you're set.")
        #expect(reply.steps.count == 2)
        #expect(reply.steps[1].displayText == "and you're set.")
        #expect(reply.steps[1].pointsSomewhere == false)
    }

    @Test func noTagsIsOnePlainStep() {
        let reply = GuidedReplyParser.parse("html is the skeleton of a web page.")
        #expect(reply.steps.count == 1)
        #expect(reply.pointingStepCount == 0)
    }

    @Test func pointNoneDoesNotPoint() {
        let reply = GuidedReplyParser.parse("html is markup. [POINT:none]")
        #expect(reply.pointingStepCount == 0)
        #expect(reply.spokenText == "html is markup.")
    }

    @Test func rectangleTagIsAStepDrawing() {
        let reply = GuidedReplyParser.parse("this whole panel is your inspector [RECT:10,20,300,400:inspector] and that's it")
        #expect(reply.steps.first?.pointsSomewhere == true)
        #expect(reply.steps.first?.pointing?.visualGuidance == .rectangle(CGRect(x: 10, y: 20, width: 300, height: 400)))
    }

    @Test func actionAfterPointStaysWithThatStep() {
        let reply = GuidedReplyParser.parse(
            "i'll hit send [POINT:500,600:send] [ACT:click:Send] then close it [POINT:20,20:close]"
        )
        #expect(reply.steps.count == 2)
        #expect(reply.steps[0].text.contains("[ACT:click:Send]"))
        #expect(reply.steps[0].displayText == "i'll hit send")
        #expect(!reply.steps[1].text.contains("[ACT"))
    }

    @Test func planAndStepTagsAreReadAndRemoved() {
        let reply = GuidedReplyParser.parse(
            "[PLAN:open the file menu|choose share|pick export] first, click file. [POINT:80,11:file menu] [STEP:1]"
        )
        #expect(reply.walkthroughDirectives == [
            .plan(["open the file menu", "choose share", "pick export"]),
            .step(1)
        ])
        #expect(reply.spokenText == "first, click file.")
        #expect(reply.pointingStepCount == 1)
    }

    @Test func planDoneEndsWalkthrough() {
        let reply = GuidedReplyParser.parse("that's everything, you're exported. [PLAN:done]")
        #expect(reply.walkthroughDirectives == [.done])
        #expect(reply.spokenText == "that's everything, you're exported.")
    }

    @Test func streamingDisplayHidesCompleteAndPartialTags() {
        #expect(GuidedReplyParser.streamingDisplayText("click file [POINT:80,11:file] then sh") == "click file then sh")
        #expect(GuidedReplyParser.streamingDisplayText("click file [POI") == "click file")
        #expect(GuidedReplyParser.streamingDisplayText("[PLAN:a|b") == "")
        #expect(GuidedReplyParser.streamingDisplayText("arrays start at [0") == "arrays start at [0")
    }
}

struct CursorCaptionTimingTests {
    private let shownAt = Date(timeIntervalSince1970: 1_000)

    @Test func readingTimeScalesWithLengthWithinBounds() {
        #expect(CursorCaptionTiming.readingSeconds(for: "hi") == CursorCaptionTiming.minimumReadingSeconds)
        let long = Array(repeating: "word", count: 200).joined(separator: " ")
        #expect(CursorCaptionTiming.readingSeconds(for: long) == CursorCaptionTiming.maximumReadingSeconds)
        let medium = Array(repeating: "word", count: 20).joined(separator: " ")
        #expect(CursorCaptionTiming.readingSeconds(for: medium) > CursorCaptionTiming.minimumReadingSeconds)
    }

    @Test func neverHidesWhileSpeaking() {
        #expect(!CursorCaptionTiming.shouldHide(
            text: "hi", shownAt: shownAt, now: shownAt.addingTimeInterval(60),
            isSpeaking: true, speechEndedAt: nil
        ))
    }

    @Test func waitsBrieflyAfterSpeechEnds() {
        let ended = shownAt.addingTimeInterval(10)
        #expect(!CursorCaptionTiming.shouldHide(
            text: "hi", shownAt: shownAt, now: ended.addingTimeInterval(0.5),
            isSpeaking: false, speechEndedAt: ended
        ))
        #expect(CursorCaptionTiming.shouldHide(
            text: "hi", shownAt: shownAt, now: ended.addingTimeInterval(CursorCaptionTiming.afterSpeechSeconds),
            isSpeaking: false, speechEndedAt: ended
        ))
    }

    @Test func silentReplyStaysLongEnoughToRead() {
        let text = Array(repeating: "word", count: 20).joined(separator: " ")
        let reading = CursorCaptionTiming.readingSeconds(for: text)
        #expect(!CursorCaptionTiming.shouldHide(
            text: text, shownAt: shownAt, now: shownAt.addingTimeInterval(reading - 0.5),
            isSpeaking: false, speechEndedAt: nil
        ))
        #expect(CursorCaptionTiming.shouldHide(
            text: text, shownAt: shownAt, now: shownAt.addingTimeInterval(reading + 0.01),
            isSpeaking: false, speechEndedAt: nil
        ))
    }
}

struct GuidedWalkthroughTests {
    @Test func promptMarksCurrentStepAndProgress() {
        let walkthrough = GuidedWalkthrough(
            goal: "export a video",
            steps: ["open file", "choose share", "pick export"],
            currentStepIndex: 1,
            updatedAt: Date()
        )
        #expect(walkthrough.progressLabel == "step 2 of 3")
        #expect(walkthrough.promptBlock.contains("2. choose share  <- current"))
        #expect(!walkthrough.isExpired)
    }

    @Test func staleWalkthroughExpires() {
        let walkthrough = GuidedWalkthrough(
            goal: "x",
            steps: ["a"],
            currentStepIndex: 0,
            updatedAt: Date().addingTimeInterval(-GuidedWalkthrough.idleExpirySeconds - 1)
        )
        #expect(walkthrough.isExpired)
    }
}
