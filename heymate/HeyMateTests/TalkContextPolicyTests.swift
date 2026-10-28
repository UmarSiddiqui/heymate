import Testing
@testable import HeyMate

struct TalkContextPolicyTests {
    @Test func ordinaryTalkStaysTextOnly() {
        #expect(!TalkContextPolicy.shouldCaptureScreen(
            for: "explain database connection pooling",
            hasSpatialSelection: false
        ))
        #expect(!TalkContextPolicy.shouldCaptureScreen(
            for: "tell me a short joke",
            hasSpatialSelection: false
        ))
    }

    @Test func visibleAndSpatialRequestsKeepScreenContext() {
        #expect(TalkContextPolicy.shouldCaptureScreen(
            for: "what does this error mean",
            hasSpatialSelection: false
        ))
        #expect(TalkContextPolicy.shouldCaptureScreen(
            for: "click save",
            hasSpatialSelection: false
        ))
        #expect(TalkContextPolicy.shouldCaptureScreen(
            for: "explain it",
            hasSpatialSelection: true
        ))
    }

    @Test func guidanceRequestsKeepScreenContext() {
        for phrase in ["how do i export a video", "show me how to add a filter", "walk me through signing a pdf", "where is the share button"] {
            #expect(TalkContextPolicy.shouldCaptureScreen(for: phrase, hasSpatialSelection: false), "\(phrase)")
        }
    }

    @Test func perceptionQuestionsWithoutDemonstrativesKeepScreenContext() {
        for phrase in ["what am i looking at", "what do you see", "what's on my screen"] {
            #expect(TalkContextPolicy.shouldCaptureScreen(for: phrase, hasSpatialSelection: false), "\(phrase)")
        }
    }

    @Test func typedChatInsideHeyMateDoesNotCaptureHeyMate() {
        #expect(!TalkContextPolicy.allowCapture(
            wantsScreen: true,
            typedInsideHeyMate: true,
            frontmostIsHeyMate: true
        ))
        #expect(TalkContextPolicy.allowCapture(
            wantsScreen: true,
            typedInsideHeyMate: false,
            frontmostIsHeyMate: true
        ))
        #expect(TalkContextPolicy.allowCapture(
            wantsScreen: true,
            typedInsideHeyMate: true,
            frontmostIsHeyMate: false
        ))
        #expect(!TalkContextPolicy.allowCapture(
            wantsScreen: false,
            typedInsideHeyMate: false,
            frontmostIsHeyMate: false
        ))
        #expect(TalkContextPolicy.allowCapture(
            wantsScreen: false,
            typedInsideHeyMate: true,
            frontmostIsHeyMate: true,
            hasSpatialSelection: true
        ))
    }

    @Test func replayDropsEarlierScreenshotPaths() {
        let kept = TalkContextPolicy.withoutPriorScreenshots(
            """
            look at this
            screenshot /var/folders/x/heymate-talk-1.jpg
            the button says Save
            """
        )
        #expect(kept.contains("look at this"))
        #expect(kept.contains("the button says Save"))
        #expect(!kept.contains("heymate-talk-1.jpg"))
        #expect(!kept.lowercased().contains("screenshot "))
    }
}
