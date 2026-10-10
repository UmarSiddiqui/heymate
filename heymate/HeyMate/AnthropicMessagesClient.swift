//
//  AnthropicMessagesClient.swift
//  HeyMate
//
//  Answers screen questions through the Anthropic Messages API: directly
//  with the user's own key, or through a proxy that holds the key for them.
//  Streams the reply as it is written and runs tool calls in between.
//
//  Encoding (screenshots become multi-megabyte base64) and stream parsing
//  run off the main thread; only caption updates and tool calls hop back.
//

import Foundation

nonisolated enum AnthropicMessagesError: LocalizedError, CustomNSError {
    case invalidEndpoint(String)
    case invalidResponse
    case http(status: Int, body: String)

    static var errorDomain: String { "AnthropicMessagesClient" }

    /// The HTTP status, so `SpokenFailure` can tell 402 (out of credits).
    var errorCode: Int {
        switch self {
        case .invalidEndpoint, .invalidResponse: return -1
        case .http(let status, _): return status
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let text): return "The API endpoint isn't a valid URL: \(text)"
        case .invalidResponse: return "Invalid HTTP response"
        case .http(let status, let body): return "API Error (\(status)): \(body)"
        }
    }
}

final class AnthropicMessagesClient: ToolCallingConversationClient {
    var model: String
    private let endpoint: URL?
    private let endpointText: String
    /// Sent as `x-api-key` for the user's own endpoint. Nil for a proxy,
    /// which exists precisely so the app never carries the key.
    private let apiKey: String?

    /// A runaway tool loop ends the turn with what was said, not a hang.
    private static let maximumToolRoundTrips = 5

    /// One session for every client. Settings changes create a new client
    /// per question, and sharing keeps the warm connection between them.
    /// The default configuration caches TLS session tickets (an ephemeral
    /// one handshakes from scratch each time, which large image uploads
    /// make flaky); nothing is cached to disk.
    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    private static var warmedHosts: Set<String> = []

    init(endpoint: String, model: String = "claude-sonnet-4-6", apiKey: String? = nil) {
        self.endpointText = endpoint
        self.endpoint = URL(string: endpoint)
        self.model = model
        self.apiKey = apiKey?.isEmpty == true ? nil : apiKey
        warmUpConnection()
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let started = Date()
        let request = AnthropicWire.Request(
            model: model,
            maxTokens: 1024,
            stream: true,
            system: systemPrompt,
            messages: AnthropicWire.messages(history: conversationHistory, images: images, prompt: userPrompt),
            tools: nil
        )
        let turn = try await Self.stream(request, to: try resolvedEndpoint(), apiKey: apiKey, onText: onTextChunk)
        return (turn.spokenText, Date().timeIntervalSince(started))
    }

    /// Streams the answer, and each time the model stops to call tools,
    /// runs them through `onToolCallRequested`, sends the results back and
    /// lets it continue, until it answers without asking for a tool.
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
        let tools = availableTools.map {
            AnthropicWire.Tool(name: $0.name, description: $0.description, inputSchemaJSON: $0.inputSchemaJSON)
        }
        var request = AnthropicWire.Request(
            model: model,
            maxTokens: 2048,
            stream: true,
            system: systemPrompt,
            messages: AnthropicWire.messages(history: conversationHistory, images: images, prompt: userPrompt),
            tools: tools
        )
        var spoken = ""

        for _ in 0..<Self.maximumToolRoundTrips {
            let turn = try await Self.stream(request, to: endpoint, apiKey: apiKey, spokenSoFar: spoken, onText: onTextChunk)
            spoken = turn.spokenText
            guard turn.wantsTools else { break }

            var results: [AnthropicWire.Block] = []
            for call in turn.toolCalls {
                let outcome = await onToolCallRequested(AssistantToolCall(
                    toolUseIdentifier: call.id,
                    toolName: call.name,
                    inputArgumentsJSON: call.argumentsJSON
                ))
                results.append(.toolResult(toolUseID: call.id, content: outcome.text, isError: outcome.isError))
            }
            request.messages.append(.assistant(turn.assistantContent))
            request.messages.append(.user(results))
        }
        return (spoken, Date().timeIntervalSince(started))
    }

    // MARK: - Transport

    private func resolvedEndpoint() throws -> URL {
        guard let endpoint else { throw AnthropicMessagesError.invalidEndpoint(endpointText) }
        return endpoint
    }

    /// Sends one request and assembles the streamed reply, off the main thread.
    @concurrent
    private nonisolated static func stream(
        _ body: AnthropicWire.Request,
        to endpoint: URL,
        apiKey: String?,
        spokenSoFar: String = "",
        onText: @MainActor @Sendable (String) -> Void
    ) async throws -> AnthropicWire.TurnAssembler {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        let payload = try JSONEncoder().encode(body)
        request.httpBody = payload
        let imageCount = body.messages.last.map(Self.imageCount) ?? 0
        HeyMateLog.log("🌐 Claude request: \(String(format: "%.1f", Double(payload.count) / 1_048_576))MB, \(imageCount) image(s)")

        let (lines, response) = try await session.bytes(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw AnthropicMessagesError.invalidResponse
        }
        guard (200...299).contains(status) else {
            var errorLines: [String] = []
            for try await line in lines.lines { errorLines.append(line) }
            throw AnthropicMessagesError.http(status: status, body: errorLines.joined(separator: "\n"))
        }

        var turn = AnthropicWire.TurnAssembler(spokenSoFar: spokenSoFar)
        for try await line in lines.lines {
            switch AnthropicWire.parse(streamLine: line) {
            case .done:
                return turn
            case .ignored:
                continue
            case .event(let event):
                if let spoken = turn.apply(event) { await onText(spoken) }
            }
        }
        return turn
    }

    private nonisolated static func imageCount(_ message: AnthropicWire.Message) -> Int {
        guard case .blocks(let blocks) = message.content else { return 0 }
        return blocks.reduce(0) { count, block in
            if case .image = block { return count + 1 }
            return count
        }
    }

    /// Opens the connection to the endpoint's host ahead of the first real
    /// question, so its large screenshot upload skips the cold handshake.
    /// Once per host per launch; the response is irrelevant.
    private func warmUpConnection() {
        guard let endpoint, var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let host = components.host, Self.warmedHosts.insert(host).inserted
        else { return }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        Self.session.dataTask(with: request).resume()
    }
}
