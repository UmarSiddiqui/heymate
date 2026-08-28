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

    @Test func codexSparkIsDefaultOnlyWithoutImages() {
        let selected = "gpt-5.3-codex"
        let spark = SubscriptionCLIVisionClient.codexFastTalkModelIdentifier
        #expect(SubscriptionCLIVisionClient.resolvedModelIdentifier(
            selectedModel: selected,
            textOnlyModel: spark,
            hasImages: false
        ) == spark)
        #expect(SubscriptionCLIVisionClient.resolvedModelIdentifier(
            selectedModel: selected,
            textOnlyModel: spark,
            hasImages: true
        ) == selected)
    }
}
