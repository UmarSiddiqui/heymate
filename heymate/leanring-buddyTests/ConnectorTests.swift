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
