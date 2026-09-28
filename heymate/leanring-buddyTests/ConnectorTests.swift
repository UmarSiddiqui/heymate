//
//  ConnectorTests.swift
//  leanring-buddyTests
//
//  Catalog integrity and the approval floor. The floor test is the
//  important one: no user preference may make a "send" or a "delete" run
//  without being asked.
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct ConnectorCatalogTests {

    @Test func everyConnectorIDIsUnique() {
        let identifiers = ConnectorCatalog.all.map(\.id)
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test func everyConnectorIsReachableByID() {
        for connector in ConnectorCatalog.all {
            #expect(ConnectorCatalog.connector(withID: connector.id)?.id == connector.id)
        }
    }

    @Test func everyConnectorLandsInAPopulatedCategory() {
        let categorized = ConnectorCatalog.populatedCategories
            .flatMap { ConnectorCatalog.connectors(in: $0) }
        #expect(categorized.count == ConnectorCatalog.all.count)
    }

    @Test func mcpConnectorsCarryALaunchCommandOrAreExplicitlyUserSupplied() {
        for connector in ConnectorCatalog.all where connector.transport == .mcp {
            // "mcp-custom" is the bring-your-own-server entry and
            // "composio" mints its own URL at connect time; everything else
            // must know how to start itself.
            if connector.id == "mcp-custom" { continue }
            if connector.id == ComposioSessionStore.connectorID { continue }
            #expect(connector.mcpLaunchCommand?.isEmpty == false, "\(connector.id) has no launch command")
        }
    }

    @Test func localCLIConnectorsNameTheirExecutableAndHowToInstallIt() {
        for connector in ConnectorCatalog.all where connector.transport == .localCLI {
            #expect(connector.requiredExecutableName?.isEmpty == false, "\(connector.id) names no executable")
            #expect(connector.installHint?.isEmpty == false, "\(connector.id) has no install hint")
        }
    }

    @Test func everyConnectorExplainsWhatItGivesTheAgent() {
        for connector in ConnectorCatalog.all {
            #expect(!connector.capabilities.isEmpty, "\(connector.id) lists no capabilities")
            #expect(!connector.summary.isEmpty, "\(connector.id) has no summary")
        }
    }

    @Test func categoriesSortLocalTransportsFirst() {
        let developerConnectors = ConnectorCatalog.connectors(in: .developer)
        let localityRanks = developerConnectors.map(\.transport.localityRank)
        #expect(localityRanks == localityRanks.sorted())
    }

    @Test func searchIsCaseAndDiacriticInsensitive() {
        #expect(ConnectorCatalog.search("PLAYWRIGHT").contains { $0.id == "mcp-playwright" })
        #expect(ConnectorCatalog.search("project files").contains { $0.id == "mcp-filesystem" })
    }

    @Test func searchMatchesCapabilityText() {
        let results = ConnectorCatalog.search("free time")
        #expect(results.contains { $0.id == "apple-calendar" })
    }

    @Test func emptySearchReturnsTheWholeCatalog() {
        #expect(ConnectorCatalog.search("   ").count == ConnectorCatalog.all.count)
    }

    @Test func theFirstCustomServerStaysInTheCatalogAndExtrasAreSynthesized() {
        let primary = ConnectorCatalog.connector(withID: ConnectorCatalog.customMCPConnectorID)
        #expect(primary?.id == "mcp-custom")
        #expect(primary?.mcpLaunchCommand == nil)
        #expect(ConnectorCatalog.isAdditionalCustomMCPID("mcp-custom") == false)

        let extraID = ConnectorCatalog.additionalCustomMCPIDPrefix + "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let extra = ConnectorCatalog.connector(withID: extraID)
        #expect(extra?.transport == .mcp)
        #expect(extra?.mcpLaunchCommand == nil)
        #expect(extra?.id == extraID)
        #expect(ConnectorCatalog.connector(withID: "gmail") == nil)
        #expect(ConnectorCatalog.all.contains { $0.id == extraID } == false)
    }

    @Test func customCommandDisplayNamesPreferTheHostOrPackage() {
        #expect(ConnectorCatalog.displayName(forCustomLaunchCommand: nil) == "Custom MCP server")
        #expect(ConnectorCatalog.displayName(forCustomLaunchCommand: "  ") == "Custom MCP server")
        #expect(
            ConnectorCatalog.displayName(forCustomLaunchCommand: "npx -y @scope/server") == "@scope/server"
        )
        #expect(
            ConnectorCatalog.displayName(forCustomLaunchCommand: "https://mcp.example.com/sse")
                == "mcp.example.com"
        )
        #expect(
            ConnectorCatalog.displayName(forCustomLaunchCommand: "uvx mcp-server-time") == "mcp-server-time"
        )
    }
}

@MainActor
struct CustomMCPServerStoreTests {

    @Test func anExtraServerSurvivesReloadAndARemovedCatalogIDDoesNot() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ConnectorStore(userDefaults: defaults)
        let extraID = ConnectorCatalog.additionalCustomMCPIDPrefix + UUID().uuidString
        store.setCustomLaunchCommand("  npx -y @scope/server  ", for: extraID)
        store.setCustomLaunchCommand("npx -y forgotten", for: "gmail")

        let reloaded = ConnectorStore(userDefaults: defaults)
        #expect(reloaded.record(for: extraID).customLaunchCommand == "npx -y @scope/server")
        #expect(reloaded.records["gmail"] == nil)
        #expect(reloaded.additionalCustomMCPConnectors().map(\.id) == [extraID])
        #expect(reloaded.additionalCustomMCPConnectors().first?.transport == .mcp)
        #expect(reloaded.additionalCustomMCPConnectors().first?.mcpLaunchCommand == nil)
    }

    @Test func disconnectKeepsTheCommandUntilItIsCleared() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ConnectorStore(userDefaults: defaults)
        // A throwaway id so the disconnect's keychain delete cannot touch a
        // real saved command or secret.
        let connectorID = "test-disconnect-" + UUID().uuidString
        store.setCustomLaunchCommand("npx -y server", for: connectorID)
        store.markConnected(connectorID: connectorID, accountLabel: "1 tool")

        store.disconnect(connectorID: connectorID)
        #expect(store.record(for: connectorID).isEnabled == false)
        #expect(store.record(for: connectorID).customLaunchCommand == "npx -y server")
        #expect(store.connectionState(for: connectorID) == .notConnected)

        store.setCustomLaunchCommand(nil, for: connectorID)
        #expect(store.record(for: connectorID).customLaunchCommand == nil)
    }

    @Test func removingAnExtraServerDropsOnlyThatRecord() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = ConnectorStore(userDefaults: defaults)
        let extraID = ConnectorCatalog.additionalCustomMCPIDPrefix + UUID().uuidString
        store.setCustomLaunchCommand("npx -y extra", for: extraID)
        store.setCustomLaunchCommand("npx -y first", for: ConnectorCatalog.customMCPConnectorID)
        store.markConnected(connectorID: extraID, accountLabel: "2 tools")

        #expect(store.activeConnectors.contains { $0.id == extraID })

        store.removeAdditionalCustomMCP(connectorID: ConnectorCatalog.customMCPConnectorID)
        #expect(store.record(for: ConnectorCatalog.customMCPConnectorID).customLaunchCommand == "npx -y first")

        store.removeAdditionalCustomMCP(connectorID: extraID)
        #expect(store.records[extraID] == nil)
        #expect(store.activeConnectors.contains { $0.id == extraID } == false)
    }
}

@MainActor
struct ConnectorApprovalPolicyTests {

    @Test func noPolicyEverWaivesApprovalForSendsOrDeletions() {
        for policy in ConnectorApprovalPolicy.allCases {
            #expect(policy.requiresApproval(forRisk: .externalSideEffect), "\(policy) waived a send")
            #expect(policy.requiresApproval(forRisk: .destructive), "\(policy) waived a deletion")
        }
    }

    @Test func askAlwaysCoversEvenReads() {
        #expect(ConnectorApprovalPolicy.askAlways.requiresApproval(forRisk: .readOnly))
    }

    @Test func askForWritesLetsReadsThroughButNotWrites() {
        let policy = ConnectorApprovalPolicy.askForWrites
        #expect(!policy.requiresApproval(forRisk: .readOnly))
        #expect(policy.requiresApproval(forRisk: .reversibleWrite))
    }

    @Test func askForExternalEffectsLetsReversibleWritesThrough() {
        let policy = ConnectorApprovalPolicy.askForExternalEffects
        #expect(!policy.requiresApproval(forRisk: .readOnly))
        #expect(!policy.requiresApproval(forRisk: .reversibleWrite))
    }

    @Test func riskLadderOrdersFromReadOnlyToDestructive() {
        #expect(ConnectorToolRisk.readOnly < ConnectorToolRisk.reversibleWrite)
        #expect(ConnectorToolRisk.reversibleWrite < ConnectorToolRisk.externalSideEffect)
        #expect(ConnectorToolRisk.externalSideEffect < ConnectorToolRisk.destructive)
        #expect(!ConnectorToolRisk.reversibleWrite.requiresApproval)
        #expect(ConnectorToolRisk.externalSideEffect.requiresApproval)
    }
}

@MainActor
struct ConnectorRuntimeNamingTests {

    @Test func environmentVariableNamesFollowThePublishedServerConvention() {
        #expect(ConnectorRuntime.environmentVariableName(forConnectorID: "mcp-slack") == "SLACK_API_KEY")
        #expect(ConnectorRuntime.environmentVariableName(forConnectorID: "mcp-brave-search") == "BRAVE_SEARCH_API_KEY")
        #expect(ConnectorRuntime.environmentVariableName(forConnectorID: "gmail") == "GMAIL_API_KEY")
    }
}

@MainActor
struct MCPClientParsingTests {

    @Test func childEnvironmentStripsAppSecretsAndKeepsOnlyScopedOverride() {
        let environment = MCPClient.childEnvironment(
            processEnvironment: [
                "PATH": "/usr/bin",
                "HOME": "/Users/tester",
                "HEYMATE_CLIENT_TOKEN": "worker-secret",
                "OPENAI_API_KEY": "provider-secret",
                "NOTION_API_KEY": "unrelated-secret",
                "GITHUB_TOKEN": "unknown-secret",
                "AWS_SECRET_ACCESS_KEY": "unknown-secret",
                "DATABASE_URL": "postgres://secret",
                "NPM_TOKEN": "unknown-secret"
            ],
            overrides: ["SLACK_API_KEY": "scoped-secret"]
        )

        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["HOME"] == "/Users/tester")
        #expect(environment["HEYMATE_CLIENT_TOKEN"] == nil)
        #expect(environment["OPENAI_API_KEY"] == nil)
        #expect(environment["NOTION_API_KEY"] == nil)
        #expect(environment["GITHUB_TOKEN"] == nil)
        #expect(environment["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(environment["DATABASE_URL"] == nil)
        #expect(environment["NPM_TOKEN"] == nil)
        #expect(environment["SLACK_API_KEY"] == "scoped-secret")
    }

    @Test func childShellSkipsStartupFilesThatCouldRestoreSecrets() {
        #expect(MCPClient.shellArguments(for: "npx server") == ["-dfc", "npx server"])
    }

    @Test func diagnosticPipeStopsMonitoringAtEOF() {
        let pipe = Pipe()
        let readHandle = pipe.fileHandleForReading
        readHandle.readabilityHandler = { _ in }
        pipe.fileHandleForWriting.closeFile()

        #expect(!MCPClient.drainDiagnostics(from: readHandle))
        #expect(readHandle.readabilityHandler == nil)
    }

    @Test func parsesToolDefinitionsAndKeepsTheSchemaVerbatim() {
        let result: [String: Any] = [
            "tools": [
                [
                    "name": "search_messages",
                    "description": "Search Slack",
                    "inputSchema": ["type": "object", "properties": ["query": ["type": "string"]]]
                ]
            ]
        ]
        let tools = MCPClient.parseToolDefinitions(from: result)
        #expect(tools.count == 1)
        #expect(tools.first?.name == "search_messages")
        #expect(tools.first?.inputSchemaJSON.contains("\"query\"") == true)
    }

    @Test func toolsMissingANameAreSkippedRatherThanCrashing() {
        let result: [String: Any] = ["tools": [["description": "nameless"]]]
        #expect(MCPClient.parseToolDefinitions(from: result).isEmpty)
    }

    @Test func aToolWithNoSchemaStillGetsAValidOne() {
        let result: [String: Any] = ["tools": [["name": "ping"]]]
        #expect(MCPClient.parseToolDefinitions(from: result).first?.inputSchemaJSON == "{\"type\":\"object\"}")
    }

    @Test func flattensTextContentBlocks() {
        let result: [String: Any] = [
            "content": [
                ["type": "text", "text": "first"],
                ["type": "text", "text": "second"]
            ]
        ]
        let parsed = MCPClient.parseToolResult(from: result)
        #expect(parsed.textContent == "first\nsecond")
        #expect(!parsed.isError)
    }

    @Test func summarizesNonTextBlocksInsteadOfDroppingThemSilently() {
        let result: [String: Any] = [
            "content": [
                ["type": "image", "data": "…"],
                ["type": "resource", "resource": ["uri": "file:///tmp/a.txt"]]
            ]
        ]
        let parsed = MCPClient.parseToolResult(from: result)
        #expect(parsed.textContent.contains("image"))
        #expect(parsed.textContent.contains("file:///tmp/a.txt"))
    }

    @Test func propagatesTheServersErrorFlag() {
        let result: [String: Any] = ["isError": true, "content": [["type": "text", "text": "nope"]]]
        #expect(MCPClient.parseToolResult(from: result).isError)
    }
}

@MainActor
struct CalendarPeekTests {

    @Test(arguments: [
        "https://zoom.us/j/12345",
        "https://meet.google.com/abc-defg-hij",
        "https://teams.microsoft.com/l/meetup-join/x"
    ])
    func recognizesConferenceLinksInFreeText(link: String) {
        let text = "Agenda attached. Join here: \(link) — see you then."
        #expect(CalendarPeekMonitor.firstConferenceURL(in: text)?.absoluteString == link)
    }

    @Test func ignoresOrdinaryLinks() {
        #expect(CalendarPeekMonitor.firstConferenceURL(in: "See https://example.com/agenda") == nil)
    }

    @Test func countdownLabelStaysShortEnoughForThePill() {
        #expect(CalendarPeekMonitor.countdownLabel(secondsUntilStart: 0) == "now")
        #expect(CalendarPeekMonitor.countdownLabel(secondsUntilStart: 540) == "in 9m")
        #expect(CalendarPeekMonitor.countdownLabel(secondsUntilStart: 7_200) == "in 2h")
    }
}

// MARK: - Per-tool risk

/// A connector's `maximumRisk` is the worst thing it can do, which is the
/// wrong yardstick for one call. Composio can delete in someone else's
/// account, so judging every call by the ceiling put a destructive-red
/// approval card in front of a tool search — and a turn that needs a click
/// to discover anything ran out of time before it answered.
struct ConnectorToolRiskInferenceTests {

    @Test func discoveryIsReadOnlyEvenOnADestructiveConnector() {
        #expect(ConnectorToolRisk.inferred(
            forToolNamed: "composio__COMPOSIO_SEARCH_TOOLS",
            ceiling: .destructive
        ) == .readOnly)
        #expect(ConnectorToolRisk.inferred(
            forToolNamed: "composio__COMPOSIO_GET_TOOL_SCHEMAS",
            ceiling: .destructive
        ) == .readOnly)
    }

    /// The meta-tool that can run anything is not readable as a verb, so it
    /// stays at the ceiling and still stops for a yes.
    @Test func anUnreadableToolStaysAtTheConnectorCeiling() {
        #expect(ConnectorToolRisk.inferred(
            forToolNamed: "composio__COMPOSIO_MULTI_EXECUTE_TOOL",
            ceiling: .destructive
        ) == .destructive)
        #expect(ConnectorToolRisk.inferred(
            forToolNamed: "composio__COMPOSIO_MANAGE_CONNECTIONS",
            ceiling: .destructive
        ) == .destructive)
    }

    @Test func composioReadBatchNeedsNoApproval() {
        #expect(ConnectorToolRisk.inferred(
            forToolNamed: "composio__COMPOSIO_MULTI_EXECUTE_TOOL",
            arguments: [
                "tools": [[
                    "tool_slug": "YOUTUBE_GET_CHANNEL_STATISTICS",
                    "arguments": [:]
                ]]
            ],
            ceiling: .destructive
        ) == .readOnly)
    }

    @Test func composioWriteBatchStillRequiresApproval() {
        #expect(ConnectorToolRisk.inferred(
            forToolNamed: "composio__COMPOSIO_MULTI_EXECUTE_TOOL",
            arguments: ["tools": [["tool_slug": "GMAIL_SEND_EMAIL"]]],
            ceiling: .destructive
        ) == .externalSideEffect)
        #expect(ConnectorToolRisk.inferred(
            forToolNamed: "composio__COMPOSIO_MULTI_EXECUTE_TOOL",
            arguments: ["tools": [["tool_slug": "YOUTUBE_DELETE_VIDEO"]]],
            ceiling: .destructive
        ) == .destructive)
    }

    @Test func malformedComposioBatchFailsClosed() {
        #expect(ConnectorToolRisk.inferred(
            forToolNamed: "composio__COMPOSIO_MULTI_EXECUTE_TOOL",
            arguments: ["tools": [["arguments": [:]]]],
            ceiling: .destructive
        ) == .destructive)
    }

    @Test func theMostDangerousVerbInANameWins() {
        #expect(ConnectorToolRisk.inferred(
            forToolNamed: "gmail__LIST_AND_DELETE_THREADS",
            ceiling: .destructive
        ) == .destructive)
        #expect(ConnectorToolRisk.inferred(
            forToolNamed: "gmail__SEND_EMAIL",
            ceiling: .destructive
        ) == .externalSideEffect)
        #expect(ConnectorToolRisk.inferred(
            forToolNamed: "notion__CREATE_PAGE",
            ceiling: .destructive
        ) == .reversibleWrite)
    }

    /// Whole tokens only. "forget" contains "get" and is not a read.
    @Test func aVerbIsMatchedAsAWholeTokenNotASubstring() {
        #expect(ConnectorToolRisk.tokenize("composio__COMPOSIO_SEARCH_TOOLS")
            .contains("search"))
        #expect(ConnectorToolRisk.tokenize("getTargetBudget") == ["get", "target", "budget"])
        #expect(ConnectorToolRisk.inferred(
            forToolNamed: "vendor__FORGET_ACCOUNT",
            ceiling: .destructive
        ) == .destructive)
    }

    /// The ceiling is a cap, never a floor: a read-only connector cannot be
    /// talked into a destructive rating by a scary-sounding name.
    @Test func theCeilingCapsTheInference() {
        #expect(ConnectorToolRisk.inferred(
            forToolNamed: "docs__DELETE_DRAFT",
            ceiling: .readOnly
        ) == .readOnly)
    }
}

/// A turn that can reach connected apps has to survive a human answering an
/// approval card; killing the child underneath one produced a truncated
/// half-answer instead of a result.
struct TalkTurnTimeoutTests {

    @Test func connectedAppTurnsGetALongerBudgetThanPlainOnes() {
        #expect(SubscriptionCLIVisionClient.plainTurnTimeout == 90)
        #expect(SubscriptionCLIVisionClient.connectedAppTurnTimeout
            > SubscriptionCLIVisionClient.plainTurnTimeout)
    }
}

/// Asked about a connected app, the model would call connection management to
/// "verify" it first — inventing a session id to do it — then read the empty
/// answer as proof the app was never connected, and hand the user a sign-in
/// link for an account that already worked. HeyMate owns connecting apps, so
/// the lever is simply not offered.
struct TalkWithheldToolTests {

    @Test func connectionManagementAndRemoteShellsAreNotOfferedToTalk() {
        #expect(CompanionManager.isWithheldFromTalk("COMPOSIO_MANAGE_CONNECTIONS"))
        #expect(CompanionManager.isWithheldFromTalk("COMPOSIO_REMOTE_BASH_TOOL"))
        #expect(CompanionManager.isWithheldFromTalk("COMPOSIO_REMOTE_WORKBENCH"))
    }

    @Test func theToolsATurnActuallyNeedsStayAvailable() {
        #expect(!CompanionManager.isWithheldFromTalk("COMPOSIO_SEARCH_TOOLS"))
        #expect(!CompanionManager.isWithheldFromTalk("COMPOSIO_MULTI_EXECUTE_TOOL"))
        #expect(!CompanionManager.isWithheldFromTalk("COMPOSIO_GET_TOOL_SCHEMAS"))
        #expect(!CompanionManager.isWithheldFromTalk("YOUTUBE_GET_CHANNEL_STATISTICS"))
    }

    @Test func theCheckIgnoresCase() {
        #expect(CompanionManager.isWithheldFromTalk("composio_manage_connections"))
    }
}
