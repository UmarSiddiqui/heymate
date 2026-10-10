//
//  AnthropicWire.swift
//  HeyMate
//
//  The Anthropic Messages API on the wire: the request body HeyMate sends,
//  the server-sent events it streams back, and the assembler that turns
//  those events into spoken text and tool calls. Pure value types with no
//  networking, all Sendable, so encoding and parsing can run off the main
//  thread and be unit-tested directly.
//

import Foundation

// MARK: - JSON

/// Any JSON value. Carries tool schemas and tool arguments, whose shape
/// only the tool knows.
nonisolated enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Parses JSON text; nil when it isn't valid JSON.
    init?(jsonText: String) {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(jsonText.utf8)) else { return nil }
        self = value
    }

    static let emptyObject = JSONValue.object([:])

    var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Request

nonisolated enum AnthropicWire {
    struct Request: Encodable, Sendable {
        var model: String
        var maxTokens: Int
        var stream: Bool
        var system: String
        var messages: [Message]
        var tools: [Tool]?

        enum CodingKeys: String, CodingKey {
            case model, stream, system, messages, tools
            case maxTokens = "max_tokens"
        }
    }

    struct Message: Encodable, Sendable {
        enum Content: Sendable {
            case text(String)
            case blocks([Block])
        }

        var role: String
        var content: Content

        static func user(_ text: String) -> Message { Message(role: "user", content: .text(text)) }
        static func assistant(_ text: String) -> Message { Message(role: "assistant", content: .text(text)) }
        static func user(_ blocks: [Block]) -> Message { Message(role: "user", content: .blocks(blocks)) }
        static func assistant(_ blocks: [Block]) -> Message { Message(role: "assistant", content: .blocks(blocks)) }

        enum CodingKeys: String, CodingKey { case role, content }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            switch content {
            case .text(let text): try container.encode(text, forKey: .content)
            case .blocks(let blocks): try container.encode(blocks, forKey: .content)
            }
        }
    }

    enum Block: Encodable, Sendable {
        case text(String)
        /// Base64-encoded only when the request is encoded, off the main thread.
        case image(Data)
        case toolUse(id: String, name: String, input: JSONValue)
        case toolResult(toolUseID: String, content: String, isError: Bool)

        private enum Key: String, CodingKey {
            case type, text, source, id, name, input, content
            case mediaType = "media_type"
            case data
            case toolUseID = "tool_use_id"
            case isError = "is_error"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .image(let data):
                try container.encode("image", forKey: .type)
                var source = container.nestedContainer(keyedBy: Key.self, forKey: .source)
                try source.encode("base64", forKey: .type)
                try source.encode(AnthropicWire.mediaType(of: data), forKey: .mediaType)
                try source.encode(data.base64EncodedString(), forKey: .data)
            case .toolUse(let id, let name, let input):
                try container.encode("tool_use", forKey: .type)
                try container.encode(id, forKey: .id)
                try container.encode(name, forKey: .name)
                try container.encode(input, forKey: .input)
            case .toolResult(let toolUseID, let content, let isError):
                try container.encode("tool_result", forKey: .type)
                try container.encode(toolUseID, forKey: .toolUseID)
                try container.encode(content, forKey: .content)
                if isError { try container.encode(true, forKey: .isError) }
            }
        }
    }

    struct Tool: Encodable, Sendable {
        var name: String
        var description: String
        var inputSchema: JSONValue

        enum CodingKeys: String, CodingKey {
            case name, description
            case inputSchema = "input_schema"
        }

        /// A schema that isn't a JSON object becomes "takes no arguments",
        /// which the API accepts, instead of failing the whole request.
        init(name: String, description: String, inputSchemaJSON: String) {
            self.name = name
            self.description = description
            let schema = JSONValue(jsonText: inputSchemaJSON)
            inputSchema = schema?.isObject == true
                ? schema!
                : .object(["type": .string("object"), "properties": .emptyObject])
        }
    }

    /// The API rejects an image whose declared type doesn't match its bytes.
    /// Screen captures are JPEG; pasted images are often PNG.
    static func mediaType(of data: Data) -> String {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }

    /// The text of earlier turns, then the new question with its labelled
    /// screenshots.
    static func messages(
        history: [(userPlaceholder: String, assistantResponse: String)],
        images: [(data: Data, label: String)],
        prompt: String
    ) -> [Message] {
        var messages: [Message] = []
        messages.reserveCapacity(history.count * 2 + 1)
        for turn in history {
            messages.append(.user(turn.userPlaceholder))
            messages.append(.assistant(turn.assistantResponse))
        }
        var blocks: [Block] = []
        for image in images {
            blocks.append(.image(image.data))
            blocks.append(.text(image.label))
        }
        blocks.append(.text(prompt))
        messages.append(.user(blocks))
        return messages
    }
}

// MARK: - Streamed response

extension AnthropicWire {
    /// One server-sent event. Only the fields HeyMate reads are decoded.
    struct StreamEvent: Decodable, Sendable, Equatable {
        struct Delta: Decodable, Sendable, Equatable {
            var type: String?
            var text: String?
            var partialJSON: String?
            var stopReason: String?

            enum CodingKeys: String, CodingKey {
                case type, text
                case partialJSON = "partial_json"
                case stopReason = "stop_reason"
            }
        }

        struct ContentBlock: Decodable, Sendable, Equatable {
            var type: String
            var id: String?
            var name: String?
        }

        var type: String
        var index: Int?
        var delta: Delta?
        var contentBlock: ContentBlock?

        enum CodingKeys: String, CodingKey {
            case type, index, delta
            case contentBlock = "content_block"
        }
    }

    enum StreamLine: Equatable {
        case event(StreamEvent)
        case done
        case ignored
    }

    /// Reads one line of the event stream. Only `data:` lines carry events.
    static func parse(streamLine line: String) -> StreamLine {
        guard line.hasPrefix("data: ") else { return .ignored }
        let payload = line.dropFirst(6)
        if payload == "[DONE]" { return .done }
        guard let event = try? JSONDecoder().decode(StreamEvent.self, from: Data(payload.utf8)) else {
            return .ignored
        }
        return .event(event)
    }

    struct PendingToolCall: Sendable, Equatable {
        var id: String
        var name: String
        var argumentsJSON: String
    }

    /// Builds one streamed response out of its events.
    struct TurnAssembler: Sendable {
        private struct ContentBlock: Sendable {
            var type: String
            var text = ""
            var toolID = ""
            var toolName = ""
            var argumentsJSON = ""
        }

        /// Everything said so far in this question, across tool round trips.
        private(set) var spokenText: String
        private(set) var stopReason: String?
        private var blocks: [Int: ContentBlock] = [:]

        init(spokenSoFar: String = "") {
            spokenText = spokenSoFar
        }

        /// Applies one event. Returns the full spoken text when it grew, so
        /// the caller can update the caption.
        mutating func apply(_ event: StreamEvent) -> String? {
            switch event.type {
            case "content_block_start":
                guard let index = event.index, let block = event.contentBlock else { return nil }
                blocks[index] = ContentBlock(type: block.type, toolID: block.id ?? "", toolName: block.name ?? "")
                return nil
            case "content_block_delta":
                guard let delta = event.delta else { return nil }
                if delta.type == "text_delta", let text = delta.text {
                    if let index = event.index { blocks[index]?.text += text }
                    spokenText += text
                    return spokenText
                }
                if delta.type == "input_json_delta", let fragment = delta.partialJSON, let index = event.index {
                    blocks[index]?.argumentsJSON += fragment
                }
                return nil
            case "message_delta":
                if let reason = event.delta?.stopReason { stopReason = reason }
                return nil
            default:
                return nil
            }
        }

        var wantsTools: Bool { stopReason == "tool_use" }

        private var orderedBlocks: [ContentBlock] {
            blocks.sorted { $0.key < $1.key }.map(\.value)
        }

        /// The calls the model asked for, in the order it made them.
        var toolCalls: [PendingToolCall] {
            orderedBlocks.filter { $0.type == "tool_use" }.map {
                PendingToolCall(id: $0.toolID, name: $0.toolName, argumentsJSON: $0.argumentsJSON.isEmpty ? "{}" : $0.argumentsJSON)
            }
        }

        /// The assistant turn to send back alongside the tool results.
        var assistantContent: [Block] {
            orderedBlocks.compactMap { block in
                switch block.type {
                case "text" where !block.text.isEmpty:
                    return .text(block.text)
                case "tool_use":
                    let arguments = block.argumentsJSON.isEmpty ? "{}" : block.argumentsJSON
                    let input = JSONValue(jsonText: arguments).flatMap { $0.isObject ? $0 : nil } ?? .emptyObject
                    return .toolUse(id: block.toolID, name: block.toolName, input: input)
                default:
                    return nil
                }
            }
        }
    }
}
