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

    @Test func selectedCodexModelWinsWithOrWithoutImages() {
        let selected = "gpt-5.3-codex"
        let spark = SubscriptionCLIVisionClient.codexFastTalkModelIdentifier
        #expect(SubscriptionCLIVisionClient.resolvedModelIdentifier(
            selectedModel: selected,
            textOnlyModel: nil,
            hasImages: false
        ) == selected)
        #expect(SubscriptionCLIVisionClient.resolvedModelIdentifier(
            selectedModel: selected,
            textOnlyModel: nil,
            hasImages: true
        ) == selected)
        #expect(SubscriptionCLIVisionClient.resolvedModelIdentifier(
            selectedModel: "",
            textOnlyModel: spark,
            hasImages: false
        ) == spark)
    }

    /// With connected apps reachable the turn keeps `--strict-mcp-config` and the
    /// empty setting sources — only the two isolations that would refuse the
    /// tool call are traded away, and the key stays out of the arguments.
    @Test func claudeTalkCarriesTheLoopbackServerWhenAppsAreReachable() {
        let arguments = SubscriptionCLIVisionClient.claudeTalkArguments(
            prompt: "what did i last upload",
            systemPrompt: "answer briefly",
            model: "sonnet",
            connectedAppServers: [
                "heymate": [
                    "command": "/usr/bin/node",
                    "args": ["/tmp/heymate-mcp.mjs"]
                ]
            ],
            connectedAppToolNames: ["mcp__heymate", "mcp__heymate__heymate_point"]
        )

        #expect(arguments.contains("--strict-mcp-config"))
        #expect(arguments.contains("--setting-sources"))
        // The bare server name is the half that covers the connector tools,
        // which are discovered at `tools/list` time and cannot be named here.
        #expect(arguments.contains("mcp__heymate,mcp__heymate__heymate_point"))
        #expect(arguments.contains("--allowedTools"))
        // Safe mode drops explicitly supplied MCP, and plan mode refuses the
        // call — carrying either would leave the tools loaded but unusable.
        #expect(!arguments.contains("--safe-mode"))
        #expect(!arguments.contains("plan"))
        #expect(arguments.contains("acceptEdits"))
        #expect(!arguments.joined().contains(#"{"mcpServers":{}}"#))
    }

    @Test func claudeTalkCannotLoadAmbientHooksOrMCPServers() {
        let arguments = SubscriptionCLIVisionClient.claudeTalkArguments(
            prompt: "look at /tmp/private-screen.jpg",
            systemPrompt: "answer briefly",
            model: "sonnet"
        )

        #expect(arguments.contains("--permission-mode"))
        #expect(arguments.contains("plan"))
        #expect(arguments.contains("--safe-mode"))
        #expect(arguments.contains("--setting-sources"))
        #expect(arguments.contains(#"{"mcpServers":{}}"#))
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(arguments.contains("sonnet"))
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
