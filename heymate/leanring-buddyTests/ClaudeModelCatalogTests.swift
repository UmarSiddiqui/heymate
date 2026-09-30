import Foundation
import Testing
@testable import HeyMate

struct ClaudeModelCatalogTests {
    @Test func longestQuotedRunBecomesLatestAliasesAndExactModels() {
        let embedded = """
        noise "claude-in-chrome" then
        new Set(["claude-fable-5","claude-mythos-5","claude-opus-5","claude-opus-4-8","claude-sonnet-5","claude-haiku-4-5","claude-3-5-sonnet"])
        """
        let identifiers = ClaudeModelCatalogParser.identifiers(in: embedded)
        #expect(identifiers.contains("claude-fable-5"))
        #expect(identifiers.contains("claude-mythos-5"))
        #expect(!identifiers.contains("claude-in-chrome"))

        let options = ClaudeModelCatalogParser.options(from: identifiers)
        #expect(options.first?.id == "fable")
        #expect(options.first?.displayName == "Fable 5")
        #expect(options.contains { $0.id == "mythos" && $0.displayName == "Mythos 5" && $0.isLatestAlias })
        #expect(options.contains { $0.id == "opus" && $0.displayName == "Opus 5" })
        #expect(options.contains { $0.id == "claude-opus-4-8" && $0.displayName == "Opus 4.8" })
        #expect(!options.contains { $0.id == "claude-opus-5" })
        #expect(!options.contains { $0.id == "claude-3-5-sonnet" })
    }

    @Test func highestVersionWinsWhenOlderIdsAreListedFirst() {
        let identifiers = [
            "claude-fable-5",
            "claude-fable-5-1",
            "claude-mythos-5",
            "claude-mythos-5-1",
            "claude-opus-4-0",
            "claude-opus-5",
            "claude-opus-5-5",
            "claude-sonnet-4-6",
            "claude-sonnet-5",
            "claude-haiku-4-5"
        ]
        let options = ClaudeModelCatalogParser.options(from: identifiers)
        #expect(options.contains { $0.id == "fable" && $0.displayName == "Fable 5.1" && $0.isLatestAlias })
        #expect(options.contains { $0.id == "mythos" && $0.displayName == "Mythos 5.1" && $0.isLatestAlias })
        #expect(options.contains { $0.id == "opus" && $0.displayName == "Opus 5.5" && $0.isLatestAlias })
        #expect(options.contains { $0.id == "sonnet" && $0.displayName == "Sonnet 5" && $0.isLatestAlias })
        #expect(options.contains { $0.id == "claude-fable-5" && !$0.isLatestAlias })
        #expect(options.contains { $0.id == "claude-opus-5" && !$0.isLatestAlias })
        #expect(!options.contains { $0.id == "claude-opus-5-5" })
    }

    @Test func familyAliasIgnoresNumberedLegacyIds() {
        #expect(ClaudeModelCatalogParser.familyName("claude-opus-4-8") == "opus")
        #expect(ClaudeModelCatalogParser.familyName("claude-3-5-sonnet") == nil)
    }

    @Test func installedClaudeCLINamesTheCurrentModels() async throws {
        let binary = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/claude")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }
        let options = try await ClaudeModelCatalogLoader.fetchAvailableModels()
        #expect(options.contains { $0.id == "fable" && $0.displayName == "Fable 5.1" && $0.isLatestAlias })
        #expect(options.contains { $0.id == "mythos" && $0.displayName == "Mythos 5.1" && $0.isLatestAlias })
        #expect(options.contains { $0.id == "opus" && $0.displayName == "Opus 5.5" && $0.isLatestAlias })
        #expect(options.contains { $0.id == "sonnet" && $0.displayName == "Sonnet 5.5" && $0.isLatestAlias })
        #expect(options.contains { $0.id == "haiku" && $0.displayName == "Haiku 4.5" && $0.isLatestAlias })
    }

    @Test func effortLevelsComeFromTheCLIHelpText() {
        let help = """
          --disallowedTools <tools...>          Comma or space-separated list
          --effort <level>                      Effort level for the current session
                                                (low, medium, high, xhigh, max)
          --environment <environment_id>        Create a new cloud session
        """
        let efforts = ClaudeEffortCatalog.options(fromHelpText: help).map(\.effort)
        #expect(efforts == ["low", "medium", "high", "xhigh", "max"])
        #expect(ClaudeEffortOption(effort: "xhigh").displayName == "X-High")
    }

    @Test func olderCLIWithoutEffortFlagOffersNoLevels() {
        let help = "  --model <model>   Model for the current session (e.g. 'sonnet')"
        #expect(ClaudeEffortCatalog.options(fromHelpText: help).isEmpty)
    }

    @Test func effortReachesClaudeTalkAndAgentLaunches() {
        let talk = SubscriptionCLIVisionClient.claudeTalkArguments(
            prompt: "hi",
            systemPrompt: "",
            model: "opus",
            effort: "high"
        )
        #expect(talk.firstIndex(of: "--effort").map { talk[$0 + 1] } == "high")

        let spec = ClaudePrintAdapter(modelIdentifier: "opus", effort: "max").launchSpec(
            workspaceURL: URL(fileURLWithPath: "/tmp"),
            leg: .plan(prompt: "do it"),
            origin: .sandbox,
            title: "t",
            sessionIdentifier: ""
        )
        #expect(spec.arguments.firstIndex(of: "--effort").map { spec.arguments[$0 + 1] } == "max")

        let unset = ClaudePrintAdapter(modelIdentifier: "opus").launchSpec(
            workspaceURL: URL(fileURLWithPath: "/tmp"),
            leg: .plan(prompt: "do it"),
            origin: .sandbox,
            title: "t",
            sessionIdentifier: ""
        )
        #expect(!unset.arguments.contains("--effort"))
    }
}
