//
//  ClaudeStreamJSONParserTests.swift
//  HeyMateTests
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct ClaudeStreamJSONParserTests {

    @Test func assistantToolUseBecomesAShortToolLine() {
        let line = """
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/tmp/index.html"}}]}}
        """
        #expect(ClaudeStreamJSONParser.events(fromStdoutLine: line) == [
            .tool(summary: "Writing index.html")
        ])
    }

    @Test func successfulResultFinishesTheJob() {
        let line = """
        {"type":"result","is_error":false,"result":"Built the landing page."}
        """
        #expect(ClaudeStreamJSONParser.events(fromStdoutLine: line) == [
            .finished(summary: "Built the landing page.")
        ])
    }

    @Test func errorResultFailsTheJob() {
        let line = """
        {"type":"result","is_error":true,"result":"Model overloaded"}
        """
        #expect(ClaudeStreamJSONParser.events(fromStdoutLine: line) == [
            .failed(message: "Model overloaded")
        ])
    }

    @Test func controlRequestBecomesApproval() {
        let line = """
        {"type":"control_request","request_id":"perm-1","request":{"subtype":"can_use_tool","tool_name":"Bash"}}
        """
        #expect(ClaudeStreamJSONParser.events(fromStdoutLine: line) == [
            .approvalRequested(id: "perm-1", summary: "Allow Bash?")
        ])
    }

    @Test func unknownLinesAreIgnored() {
        #expect(ClaudeStreamJSONParser.events(fromStdoutLine: "not json").isEmpty)
        #expect(ClaudeStreamJSONParser.events(fromStdoutLine: "{\"type\":\"system\"}").isEmpty)
    }
}

@MainActor
struct OpenCodeRunParserTests {

    @Test func toolEventUsesNameAndPath() {
        let line = """
        {"type":"tool_use","name":"write","path":"/tmp/App.swift"}
        """
        #expect(OpenCodeRunParser.events(fromStdoutLine: line) == [
            .tool(summary: "write App.swift")
        ])
    }

    @Test func errorTypeFails() {
        let line = """
        {"type":"error","error":"crash"}
        """
        #expect(OpenCodeRunParser.events(fromStdoutLine: line) == [
            .failed(message: "crash")
        ])
    }

    @Test func realNestedTextPayloadIsRead() {
        let line = #"{"type":"text","sessionID":"ses_1","part":{"type":"text","text":"All files updated"}}"#
        #expect(OpenCodeRunParser.events(fromStdoutLine: line) == [
            .sessionIdentified("ses_1"),
            .text("All files updated")
        ])
    }

    @Test func intermediateStepFinishDoesNotEndToolUsingRun() {
        let lines = [
            #"{"type":"step_start","sessionID":"ses_1","part":{"type":"step-start"}}"#,
            #"{"type":"tool_use","sessionID":"ses_1","part":{"type":"tool","tool":"bash","state":{"status":"completed"}}}"#,
            #"{"type":"step_finish","sessionID":"ses_1","part":{"type":"step-finish","reason":"tool-calls"}}"#,
            #"{"type":"step_start","sessionID":"ses_1","part":{"type":"step-start"}}"#,
            #"{"type":"text","sessionID":"ses_1","part":{"type":"text","text":"Done after the tool"}}"#,
            #"{"type":"step_finish","sessionID":"ses_1","part":{"type":"step-finish","reason":"stop"}}"#
        ]

        let events = lines.flatMap(OpenCodeRunParser.events(fromStdoutLine:))
        #expect(events.contains(.tool(summary: "bash")))
        #expect(events.contains(.text("Done after the tool")))
        #expect(events.contains { event in
            if case .finished = event { return true }
            return false
        } == false)
    }

    @Test func vagueCompleteTypeCannotKillTheProcess() {
        let line = #"{"type":"step_complete","text":"first step complete"}"#
        #expect(OpenCodeRunParser.events(fromStdoutLine: line).isEmpty)
    }
}

@MainActor
struct ClaudeApprovalTransportRegressionTests {
    @Test func sandboxAndAttachedExecuteBothUseScopedDuplexApprovals() {
        let adapter = ClaudePrintAdapter(modelIdentifier: nil)
        for origin in [AgentRunOrigin.sandbox, .attached] {
            let spec = adapter.launchSpec(workspaceURL: URL(fileURLWithPath: "/tmp"), leg: .execute,
                                          origin: origin, title: "Fixture", sessionIdentifier: UUID().uuidString)
            #expect(spec.usesDuplexStandardInput)
            #expect(spec.arguments.contains("--permission-prompt-tool"))
            #expect(spec.arguments.contains("stdio"))
            #expect(!spec.arguments.contains("--dangerously-skip-permissions"))
        }
    }

    @Test func approvalEchoesExactCommandAndDenialDoesNotAllowIt() throws {
        let adapter = ClaudePrintAdapter(modelIdentifier: nil)
        let line = #"{"type":"control_request","request_id":"opaque","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"printf fixture","timeout":1000}}}"#
        let events = adapter.events(fromStdoutLine: line)
        guard case .approvalRequested(let id, let summary) = try #require(events.first) else {
            Issue.record("No command approval surfaced")
            return
        }
        #expect(id == "opaque")
        #expect(summary.contains("printf fixture"))
        let data = try #require(adapter.stdinPayloadForApproval(id: "opaque", approve: true))
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let envelope = try #require(payload["response"] as? [String: Any])
        let response = try #require(envelope["response"] as? [String: Any])
        #expect(response["behavior"] as? String == "allow")
        #expect((response["updatedInput"] as? [String: Any])?["command"] as? String == "printf fixture")
        _ = adapter.events(fromStdoutLine: line)
        let denied = try #require(adapter.stdinPayloadForApproval(id: "opaque", approve: false))
        #expect(String(decoding: denied, as: UTF8.self).contains("deny"))
    }
}
