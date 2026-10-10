//
//  AnthropicWireTests.swift
//  HeyMateTests
//
//  The request HeyMate sends to the Messages API and how it reads the
//  streamed reply back, including tool calls that arrive in fragments.
//

import Foundation
import Testing
@testable import HeyMate

struct AnthropicWireTests {

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func events(_ lines: [String]) -> [AnthropicWire.StreamEvent] {
        lines.compactMap {
            if case .event(let event) = AnthropicWire.parse(streamLine: $0) { return event }
            return nil
        }
    }

    @Test func requestCarriesHistoryThenLabelledScreenshotsThenPrompt() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        let jpeg = Data([0xFF, 0xD8, 0xFF])
        let request = AnthropicWire.Request(
            model: "m",
            maxTokens: 1024,
            stream: true,
            system: "sys",
            messages: AnthropicWire.messages(
                history: [(userPlaceholder: "q1", assistantResponse: "a1")],
                images: [(data: png, label: "screen 1"), (data: jpeg, label: "screen 2")],
                prompt: "what is this?"
            ),
            tools: nil
        )
        let body = try json(request)
        #expect(body["max_tokens"] as? Int == 1024)
        #expect(body["tools"] == nil)

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        #expect(messages[0]["content"] as? String == "q1")
        #expect(messages[1]["role"] as? String == "assistant")

        let blocks = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == ["image", "text", "image", "text", "text"])
        let firstSource = try #require(blocks[0]["source"] as? [String: Any])
        #expect(firstSource["media_type"] as? String == "image/png")
        #expect(firstSource["data"] as? String == png.base64EncodedString())
        let secondSource = try #require(blocks[2]["source"] as? [String: Any])
        #expect(secondSource["media_type"] as? String == "image/jpeg")
        #expect(blocks[4]["text"] as? String == "what is this?")
    }

    @Test func toolSchemasPassThroughAndBadOnesTakeNoArguments() throws {
        let good = AnthropicWire.Tool(
            name: "open_app",
            description: "Opens an app",
            inputSchemaJSON: #"{"type":"object","properties":{"bundle_id":{"type":"string"}},"required":["bundle_id"]}"#
        )
        let goodSchema = try #require(try json(good)["input_schema"] as? [String: Any])
        #expect(goodSchema["required"] as? [String] == ["bundle_id"])
        #expect((goodSchema["properties"] as? [String: Any])?["bundle_id"] != nil)

        let broken = AnthropicWire.Tool(name: "x", description: "", inputSchemaJSON: "not json")
        #expect(broken.inputSchema == .object(["type": .string("object"), "properties": .emptyObject]))
    }

    @Test func streamParserSkipsNoiseAndStopsAtDone() {
        #expect(AnthropicWire.parse(streamLine: "event: ping") == .ignored)
        #expect(AnthropicWire.parse(streamLine: "") == .ignored)
        #expect(AnthropicWire.parse(streamLine: "data: {broken") == .ignored)
        #expect(AnthropicWire.parse(streamLine: "data: [DONE]") == .done)
    }

    @Test func textDeltasAccumulateIntoTheCaption() {
        var turn = AnthropicWire.TurnAssembler()
        var captions: [String] = []
        for event in events([
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" there"}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
        ]) {
            if let caption = turn.apply(event) { captions.append(caption) }
        }
        #expect(captions == ["Hello", "Hello there"])
        #expect(turn.spokenText == "Hello there")
        #expect(!turn.wantsTools)
        #expect(turn.toolCalls.isEmpty)
    }

    @Test func fragmentedToolCallIsReassembledAndEchoedBack() throws {
        var turn = AnthropicWire.TurnAssembler(spokenSoFar: "Earlier. ")
        for event in events([
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Opening it."}}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu_1","name":"open_app","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"bundle_"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"id\":\"com.apple.Notes\"}"}}"#,
            #"data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"tu_2","name":"noop","input":{}}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        ]) {
            _ = turn.apply(event)
        }

        #expect(turn.wantsTools)
        #expect(turn.spokenText == "Earlier. Opening it.")
        #expect(turn.toolCalls == [
            AnthropicWire.PendingToolCall(id: "tu_1", name: "open_app", argumentsJSON: #"{"bundle_id":"com.apple.Notes"}"#),
            AnthropicWire.PendingToolCall(id: "tu_2", name: "noop", argumentsJSON: "{}"),
        ])

        let echoed = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AnthropicWire.Message.assistant(turn.assistantContent))
        ) as? [String: Any]
        let blocks = try #require(echoed?["content"] as? [[String: Any]])
        #expect(blocks.map { $0["type"] as? String } == ["text", "tool_use", "tool_use"])
        #expect((blocks[1]["input"] as? [String: Any])?["bundle_id"] as? String == "com.apple.Notes")
        #expect((blocks[2]["input"] as? [String: Any])?.isEmpty == true)
    }

    @Test func toolResultMarksErrorsOnly() throws {
        let failed = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            AnthropicWire.Block.toolResult(toolUseID: "tu_1", content: "denied", isError: true)
        )) as? [String: Any]
        #expect(failed?["tool_use_id"] as? String == "tu_1")
        #expect(failed?["is_error"] as? Bool == true)

        let succeeded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            AnthropicWire.Block.toolResult(toolUseID: "tu_2", content: "ok", isError: false)
        )) as? [String: Any]
        #expect(succeeded?["is_error"] == nil)
    }

    @Test func httpErrorsKeepTheirStatusForSpokenFailure() {
        let paymentRequired = AnthropicMessagesError.http(status: 402, body: "payment required")
        #expect((paymentRequired as NSError).code == 402)
        #expect(SpokenFailure.classify(paymentRequired) == .outOfCredits)
        #expect(paymentRequired.localizedDescription == "API Error (402): payment required")
    }
}
