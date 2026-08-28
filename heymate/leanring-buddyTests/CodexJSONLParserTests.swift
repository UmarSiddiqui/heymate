//
//  CodexJSONLParserTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct CodexJSONLParserTests {

    @Test func threadStartedIdentifiesTheSession() {
        let line = #"{"type":"thread.started","thread_id":"01a038fe-895a-71e1-a874-d66ddd64d7f5"}"#
        let events = CodexJSONLParser.events(fromStdoutLine: line)
        #expect(events.contains { event in
            if case .sessionIdentified(let id) = event {
                return id == "01a038fe-895a-71e1-a874-d66ddd64d7f5"
            }
            return false
        })
    }

    @Test func completedAgentMessageBecomesFinishedText() {
        let line = #"{"type":"item.completed","item":{"type":"agent_message","text":"the plan is to add a dark mode"}}"#
        #expect(
            CodexJSONLParser.agentMessageText(fromStdoutLine: line)
                == "the plan is to add a dark mode"
        )
    }

    @Test func errorLinesFailTheJob() {
        let events = CodexJSONLParser.events(fromStdoutLine: #"{"type":"error","message":"not logged in"}"#)
        #expect(events.contains { event in
            if case .failed(let message) = event { return message == "not logged in" }
            return false
        })
    }

    @Test func itemIdsAreNotTreatedAsSessionIds() {
        let line = #"{"type":"item.started","id":"item_123","item":{"type":"command_execution","command":"ls"}}"#
        let events = CodexJSONLParser.events(fromStdoutLine: line)
        #expect(events.contains { event in
            if case .sessionIdentified = event { return true }
            return false
        } == false)
    }
}

struct CodexExecAdapterTests {

    private let workspaceURL = URL(fileURLWithPath: "/tmp/heymate-codex-test", isDirectory: true)

    private func spec(leg: AgentRunLeg, origin: AgentRunOrigin = .sandbox) -> HeadlessCLILaunchSpec {
        HeadlessCLIAdapterFactory.adapter(
            for: .codex,
            codexModelIdentifier: "gpt-5.4",
            codexReasoningEffort: "xhigh",
            codexMCPConfigurationArguments: ["-c", "mcp_servers.heymate.command=\"/usr/bin/node\""],
            mcpChildEnvironment: ["HEYMATE_BRIDGE_TOKEN": "secret"]
        ).launchSpec(
            workspaceURL: workspaceURL,
            leg: leg,
            origin: origin,
            title: "build a landing page",
            sessionIdentifier: "01a038fe-895a-71e1-a874-d66ddd64d7f5"
        )
    }

    @Test func planLegIsReadOnlyAndPassesTheModel() {
        let arguments = spec(leg: .plan(prompt: "build a landing page")).arguments
        #expect(arguments.contains("exec"))
        #expect(arguments.contains("--json"))
        #expect(arguments.contains("--ignore-user-config"))
        #expect(arguments.contains("read-only"))
        #expect(arguments.contains("-m"))
        #expect(arguments.contains("gpt-5.4"))
        #expect(arguments.contains("model_reasoning_effort=\"xhigh\""))
        #expect(arguments.contains("resume") == false)
        #expect(arguments.contains("build a landing page"))
        #expect(arguments.contains("mcp_servers.heymate.command=\"/usr/bin/node\"") == false)
        #expect(spec(leg: .plan(prompt: "x")).environmentOverrides.isEmpty)
    }

    @Test func executeLegResumesTheApprovedThread() {
        let arguments = spec(leg: .execute).arguments
        #expect(arguments.contains("resume"))
        #expect(arguments.contains("01a038fe-895a-71e1-a874-d66ddd64d7f5"))
        #expect(arguments.contains("workspace-write"))
        #expect(arguments.contains(headlessAgentExecuteInstruction))
        #expect(arguments.contains("mcp_servers.heymate.command=\"/usr/bin/node\""))
        #expect(spec(leg: .execute).environmentOverrides["HEYMATE_BRIDGE_TOKEN"] == "secret")
    }

    @Test func defaultModelOmitsTheFlag() {
        let arguments = HeadlessCLIAdapterFactory.adapter(for: .codex).launchSpec(
            workspaceURL: workspaceURL,
            leg: .plan(prompt: "x"),
            origin: .sandbox,
            title: "x",
            sessionIdentifier: ""
        ).arguments
        #expect(arguments.contains("-m") == false)
    }
}
