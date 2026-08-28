//
//  ClaudeStreamJSONParserTests.swift
//  leanring-buddyTests
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
