//
//  OpenAIChatClientTests.swift
//  HeyMateTests
//

import Foundation
import Testing
@testable import HeyMate

struct OpenAIChatClientTests {

    @Test func acceptsABaseURLOrTheFullEndpoint() {
        #expect(OpenAIChatClient.chatCompletionsURL("https://api.openai.com/v1") == "https://api.openai.com/v1/chat/completions")
        #expect(OpenAIChatClient.chatCompletionsURL("http://localhost:11434/v1/") == "http://localhost:11434/v1/chat/completions")
        #expect(OpenAIChatClient.chatCompletionsURL("https://openrouter.ai/api/v1/chat/completions") == "https://openrouter.ai/api/v1/chat/completions")
    }

    @Test func guessesTheFormatFromTheURL() {
        #expect(CustomAPIFormat.guess(from: "https://api.anthropic.com/v1/messages") == .anthropic)
        #expect(CustomAPIFormat.guess(from: "https://my-proxy.example/v1/messages") == .anthropic)
        #expect(CustomAPIFormat.guess(from: "https://api.openai.com/v1") == .openAI)
        #expect(CustomAPIFormat.guess(from: "http://localhost:11434/v1") == .openAI)
        #expect(CustomAPIFormat.guess(from: "https://openrouter.ai/api/v1/chat/completions") == .openAI)
        #expect(CustomAPIFormat.guess(from: "https://worker.example.dev") == .anthropic)
    }

    @Test func screenshotsTravelAsDataURLsAfterTheSystemPrompt() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
        let messages = OpenAIChatWire.messages(
            system: "Be brief.", history: [("Earlier", "Answer")],
            images: [(png, "Screen 1")], prompt: "What is this?"
        )
        let request = OpenAIChatWire.Request(model: "gpt-4o", maxTokens: 64, messages: messages, tools: [
            OpenAIChatWire.Tool(function: .init(name: "start_timer", description: "Timer",
                                                parameters: OpenAIChatWire.schema(#"{"type":"object","properties":{"seconds":{"type":"number"}}}"#)))
        ])
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let sent = try #require(json["messages"] as? [[String: Any]])
        #expect(sent.map { $0["role"] as? String } == ["system", "user", "assistant", "user"])
        let parts = try #require(sent[3]["content"] as? [[String: Any]])
        let image = try #require(parts.first?["image_url"] as? [String: String])
        #expect(image["url"]?.hasPrefix("data:image/png;base64,") == true)
        #expect(json["max_tokens"] as? Int == 64)
        let tools = try #require(json["tools"] as? [[String: Any]])
        let parameters = try #require((tools[0]["function"] as? [String: Any])?["parameters"] as? [String: Any])
        #expect(parameters["type"] as? String == "object")
    }

    @Test func streamedTextAndToolCallsAssemble() {
        var turn = OpenAIChatWire.TurnAssembler()
        let lines = [
            #"data: {"choices":[{"delta":{"content":"Setting "}}]}"#,
            #"data: {"choices":[{"delta":{"content":"a timer."}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"start_timer","arguments":"{\"sec"}}]}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"onds\":60}"}}]},"finish_reason":"tool_calls"}]}"#,
            ": keep-alive",
            "data: [DONE]"
        ]
        var sawDone = false
        for line in lines {
            let parsed = OpenAIChatWire.decode(streamLine: line)
            if parsed.done { sawDone = true; break }
            if let chunk = parsed.chunk { _ = turn.apply(chunk) }
        }
        #expect(sawDone)
        #expect(turn.spokenText == "Setting a timer.")
        #expect(turn.wantsTools)
        #expect(turn.toolCalls == [OpenAIChatWire.ToolCall(id: "call_1", function: .init(name: "start_timer", arguments: #"{"seconds":60}"#))])
    }

    @Test func toolOnlyTurnsSendNullContent() throws {
        let message = OpenAIChatWire.Message.assistant("", toolCalls: [
            OpenAIChatWire.ToolCall(id: "c", function: .init(name: "t", arguments: "{}"))
        ])
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        #expect(json["content"] is NSNull)
        #expect((json["tool_calls"] as? [[String: Any]])?.first?["id"] as? String == "c")
    }
}
