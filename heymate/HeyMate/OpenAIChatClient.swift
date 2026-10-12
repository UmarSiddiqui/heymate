//
//  OpenAIChatClient.swift
//  HeyMate
//
//  Answers through any OpenAI-compatible Chat Completions endpoint: OpenAI
//  itself, OpenRouter, Groq, Together, LM Studio, Ollama, vLLM and the
//  rest. Streams the reply and runs tool calls in between, the same way
//  `AnthropicMessagesClient` does for Anthropic-compatible servers.
//

import Foundation

nonisolated enum OpenAIChatWire {
    struct Request: Encodable, Sendable {
        var model: String
        var stream = true
        var maxTokens: Int
        var messages: [Message]
        var tools: [Tool]?

        enum CodingKeys: String, CodingKey {
            case model, stream, messages, tools
            case maxTokens = "max_tokens"
        }
    }

    struct Tool: Encodable, Sendable {
        struct Function: Encodable, Sendable {
            var name: String
            var description: String
            var parameters: JSONBox
        }
        var type = "function"
        var function: Function
    }

    /// A tool's input schema, passed through as written.
    static func schema(_ text: String) -> JSONBox {
        JSONBox((try? JSONSerialization.jsonObject(with: Data(text.utf8))) ?? [String: Any]())
    }

    struct ToolCall: Encodable, Sendable, Equatable {
        struct Function: Encodable, Sendable, Equatable {
            var name: String
            var arguments: String
        }
        var id: String
        var type = "function"
        var function: Function
    }

    enum Part: Encodable, Sendable {
        case text(String)
        case image(Data)

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .image(let data):
                try container.encode("image_url", forKey: .type)
                let url = "data:\(AnthropicWire.mediaType(of: data));base64,\(data.base64EncodedString())"
                try container.encode(["url": url], forKey: .imageURL)
            }
        }

        enum Keys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }
    }

    enum Content: Encodable, Sendable {
        case text(String)
        case parts([Part])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text): try container.encode(text)
            case .parts(let parts): try container.encode(parts)
            }
        }
    }

    struct Message: Encodable, Sendable {
        var role: String
        var content: Content?
        var toolCalls: [ToolCall]?
        var toolCallID: String?

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
            case toolCallID = "tool_call_id"
        }

        static func system(_ text: String) -> Message { Message(role: "system", content: .text(text)) }
        static func user(_ text: String) -> Message { Message(role: "user", content: .text(text)) }
        static func user(_ parts: [Part]) -> Message { Message(role: "user", content: .parts(parts)) }
        static func assistant(_ text: String) -> Message { Message(role: "assistant", content: .text(text)) }
        static func assistant(_ text: String, toolCalls: [ToolCall]) -> Message {
            Message(role: "assistant", content: text.isEmpty ? nil : .text(text), toolCalls: toolCalls)
        }
        static func tool(id: String, content: String) -> Message {
            Message(role: "tool", content: .text(content), toolCallID: id)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            // Assistant turns that only call tools send `content: null`.
            if let content { try container.encode(content, forKey: .content) } else { try container.encodeNil(forKey: .content) }
            try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
            try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        }
    }

    static func messages(
        system: String,
        history: [(userPlaceholder: String, assistantResponse: String)],
        images: [(data: Data, label: String)],
        prompt: String
    ) -> [Message] {
        var messages: [Message] = [.system(system)]
        for turn in history {
            messages.append(.user(turn.userPlaceholder))
            messages.append(.assistant(turn.assistantResponse))
        }
        if images.isEmpty {
            messages.append(.user(prompt))
        } else {
            var parts: [Part] = []
            for image in images {
                parts.append(.image(image.data))
                parts.append(.text(image.label))
            }
            parts.append(.text(prompt))
            messages.append(.user(parts))
        }
        return messages
    }

    // MARK: Stream

    struct Chunk: Decodable, Sendable {
        struct Choice: Decodable, Sendable {
            struct Delta: Decodable, Sendable {
                struct ToolCallDelta: Decodable, Sendable {
                    struct Function: Decodable, Sendable {
                        var name: String?
                        var arguments: String?
                    }
                    var index: Int?
                    var id: String?
                    var function: Function?
                }
                var content: String?
                var toolCalls: [ToolCallDelta]?

                enum CodingKeys: String, CodingKey {
                    case content
                    case toolCalls = "tool_calls"
                }
            }
            var delta: Delta?
            var finishReason: String?

            enum CodingKeys: String, CodingKey {
                case delta
                case finishReason = "finish_reason"
            }
        }
        var choices: [Choice]
    }

    /// Parses one server-sent line: the end marker, a chunk, or neither.
    static func decode(streamLine line: String) -> (done: Bool, chunk: Chunk?) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return (false, nil) }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return (true, nil) }
        return (false, try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)))
    }

    /// Builds one assistant turn from streamed chunks.
    struct TurnAssembler: Sendable {
        var spokenText: String
        private(set) var text = ""
        private(set) var calls: [Int: ToolCall] = [:]
        private(set) var finishReason: String?

        init(spokenSoFar: String = "") { spokenText = spokenSoFar }

        var toolCalls: [ToolCall] { calls.keys.sorted().compactMap { calls[$0] } }
        var wantsTools: Bool { !calls.isEmpty }

        /// Applies a chunk. Returns the spoken text when it changed.
        mutating func apply(_ chunk: Chunk) -> String? {
            guard let choice = chunk.choices.first else { return nil }
            if let reason = choice.finishReason { finishReason = reason }
            var changed: String?
            if let piece = choice.delta?.content, !piece.isEmpty {
                text += piece
                spokenText += piece
                changed = spokenText
            }
            for delta in choice.delta?.toolCalls ?? [] {
                let index = delta.index ?? 0
                var call = calls[index] ?? ToolCall(id: "", function: .init(name: "", arguments: ""))
                if let id = delta.id, !id.isEmpty { call.id = id }
                if let name = delta.function?.name { call.function.name += name }
                if let arguments = delta.function?.arguments { call.function.arguments += arguments }
                calls[index] = call
            }
            return changed
        }
    }
}

/// Wraps an arbitrary JSON object so it can sit inside an Encodable request.
nonisolated struct JSONBox: Encodable, @unchecked Sendable {
    let object: Any
    init(_ object: Any) { self.object = object }

    func encode(to encoder: Encoder) throws {
        switch object {
        case let dictionary as [String: Any]:
            var container = encoder.container(keyedBy: AnyKey.self)
            for (key, value) in dictionary { try container.encode(JSONBox(value), forKey: AnyKey(key)) }
        case let array as [Any]:
            var container = encoder.unkeyedContainer()
            for value in array { try container.encode(JSONBox(value)) }
        case let number as NSNumber:
            var container = encoder.singleValueContainer()
            if CFGetTypeID(number) == CFBooleanGetTypeID() { try container.encode(number.boolValue) }
            else if number.doubleValue.rounded() == number.doubleValue { try container.encode(number.int64Value) }
            else { try container.encode(number.doubleValue) }
        case let string as String:
            var container = encoder.singleValueContainer()
            try container.encode(string)
        default:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

final class OpenAIChatClient: ToolCallingConversationClient {
    var model: String
    private let endpoint: URL?
    private let endpointText: String
    /// Sent as a Bearer token. Nil for a local server or a proxy with the key.
    private let apiKey: String?

    private static let maximumToolRoundTrips = 5

    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    init(endpoint: String, model: String, apiKey: String? = nil) {
        self.endpointText = endpoint
        self.endpoint = URL(string: Self.chatCompletionsURL(endpoint))
        self.model = model
        self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
    }

    /// Accepts a base URL ("https://api.openai.com/v1") or the full
    /// "/chat/completions" URL, since people paste either.
    nonisolated static func chatCompletionsURL(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/chat/completions") { return trimmed }
        return trimmed + "/chat/completions"
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let started = Date()
        let request = OpenAIChatWire.Request(
            model: model,
            maxTokens: 1024,
            messages: OpenAIChatWire.messages(system: systemPrompt, history: conversationHistory, images: images, prompt: userPrompt),
            tools: nil
        )
        let turn = try await Self.stream(request, to: try resolvedEndpoint(), apiKey: apiKey, onText: onTextChunk)
        return (turn.spokenText, Date().timeIntervalSince(started))
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        availableTools: [AssistantToolDefinition],
        onTextChunk: @MainActor @Sendable (String) -> Void,
        onToolCallRequested: @MainActor @Sendable (AssistantToolCall) async -> (text: String, isError: Bool)
    ) async throws -> (text: String, duration: TimeInterval) {
        let started = Date()
        let endpoint = try resolvedEndpoint()
        var request = OpenAIChatWire.Request(
            model: model,
            maxTokens: 2048,
            messages: OpenAIChatWire.messages(system: systemPrompt, history: conversationHistory, images: images, prompt: userPrompt),
            tools: availableTools.isEmpty ? nil : availableTools.map {
                OpenAIChatWire.Tool(function: .init(
                    name: $0.name, description: $0.description, parameters: OpenAIChatWire.schema($0.inputSchemaJSON)
                ))
            }
        )
        var spoken = ""
        for _ in 0..<Self.maximumToolRoundTrips {
            let turn = try await Self.stream(request, to: endpoint, apiKey: apiKey, spokenSoFar: spoken, onText: onTextChunk)
            spoken = turn.spokenText
            guard turn.wantsTools else { break }
            let calls = turn.toolCalls
            request.messages.append(.assistant(turn.text, toolCalls: calls))
            for call in calls {
                let outcome = await onToolCallRequested(AssistantToolCall(
                    toolUseIdentifier: call.id,
                    toolName: call.function.name,
                    inputArgumentsJSON: call.function.arguments.isEmpty ? "{}" : call.function.arguments
                ))
                request.messages.append(.tool(id: call.id, content: outcome.isError ? "Error: \(outcome.text)" : outcome.text))
            }
        }
        return (spoken, Date().timeIntervalSince(started))
    }

    private func resolvedEndpoint() throws -> URL {
        guard let endpoint else { throw AnthropicMessagesError.invalidEndpoint(endpointText) }
        return endpoint
    }

    @concurrent
    private nonisolated static func stream(
        _ body: OpenAIChatWire.Request,
        to endpoint: URL,
        apiKey: String?,
        spokenSoFar: String = "",
        onText: @MainActor @Sendable (String) -> Void
    ) async throws -> OpenAIChatWire.TurnAssembler {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let payload = try JSONEncoder().encode(body)
        request.httpBody = payload
        HeyMateLog.log("🌐 OpenAI-compatible request: \(String(format: "%.1f", Double(payload.count) / 1_048_576))MB")

        let (lines, response) = try await session.bytes(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw AnthropicMessagesError.invalidResponse
        }
        guard (200...299).contains(status) else {
            var errorLines: [String] = []
            for try await line in lines.lines { errorLines.append(line) }
            throw AnthropicMessagesError.http(status: status, body: errorLines.joined(separator: "\n"))
        }
        var turn = OpenAIChatWire.TurnAssembler(spokenSoFar: spokenSoFar)
        for try await line in lines.lines {
            let parsed = OpenAIChatWire.decode(streamLine: line)
            if parsed.done { return turn }
            if let chunk = parsed.chunk, let spoken = turn.apply(chunk) { await onText(spoken) }
        }
        return turn
    }
}
