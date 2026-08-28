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
}
