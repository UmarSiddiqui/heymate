//
//  ClaudeAPI.swift
//  Claude API Implementation with streaming support
//

import Foundation

/// Claude API helper with streaming for progressive text display.
/// Conforms to VisionConversationClient so it can be swapped behind the protocol.
class ClaudeAPI: VisionConversationClient, ToolCallingConversationClient {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    private let apiURL: URL
    var model: String
    private let session: URLSession

    /// Sent as `x-api-key` when the endpoint is the user's own rather than a
    /// proxy that already holds the key. Nil for a proxy — the whole point of
    /// one is that the client never carries the credential.
    private let apiKey: String?

    init(proxyURL: String, model: String = "claude-sonnet-4-6", apiKey: String? = nil) {
        self.apiURL = URL(string: proxyURL)!
        self.model = model
        self.apiKey = apiKey

        // Use .default instead of .ephemeral so TLS session tickets are cached.
        // Ephemeral sessions do a full TLS handshake on every request, which causes
        // transient -1200 (errSSLPeerHandshakeFail) errors with large image payloads.
        // Disable URL/cookie caching to avoid storing responses or credentials on disk.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        // Fire a lightweight HEAD request in the background to pre-establish the TLS
        // connection. This caches the TLS session ticket so the first real API call
        // (which carries a large image payload) doesn't need a cold TLS handshake.
        warmUpTLSConnectionIfNeeded()
    }

    private func makeAPIRequest() -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return request
    }

    /// Detects the MIME type of image data by inspecting the first bytes.
    /// Screen captures from ScreenCaptureKit are JPEG, but pasted images from the
    /// clipboard are PNG. The API rejects requests where the declared media_type
    /// doesn't match the actual image format.
    private func detectImageMediaType(for imageData: Data) -> String {
        // PNG files start with the 8-byte signature: 89 50 4E 47 0D 0A 1A 0A
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        // Default to JPEG — screen captures use JPEG compression
        return "image/jpeg"
    }

    /// Sends a no-op HEAD request to the API host to establish and cache a TLS session.
    /// Failures are silently ignored — this is purely an optimization.
    private func warmUpTLSConnectionIfNeeded() {
        Self.tlsWarmupLock.lock()
        let shouldStartTLSWarmup = !Self.hasStartedTLSWarmup
        if shouldStartTLSWarmup {
            Self.hasStartedTLSWarmup = true
        }
        Self.tlsWarmupLock.unlock()

        guard shouldStartTLSWarmup else { return }

        guard var warmupURLComponents = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            return
        }

        // The TLS session ticket is host-scoped, so warming the root host is enough.
        // Hitting the host instead of `/v1/messages` avoids extra endpoint-specific noise.
        warmupURLComponents.path = "/"
        warmupURLComponents.query = nil
        warmupURLComponents.fragment = nil

        guard let warmupURL = warmupURLComponents.url else {
            return
        }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Response doesn't matter — the TLS handshake is the goal
        }.resume()
    }

    /// Send a vision request to Claude with streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total duration when the stream completes.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeAPIRequest()

        // Build messages array
        var messages: [[String: Any]] = []

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "stream": true,
            "system": systemPrompt,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        // Use bytes streaming for SSE (Server-Sent Events)
        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        // If non-2xx status, read the full body as error text
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "ClaudeAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        // Parse SSE stream — each event is "data: {json}\n\n"
        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            // SSE lines look like: "data: {...}"
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6)) // Drop "data: " prefix

            // End of stream marker
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let eventType = eventPayload["type"] as? String else {
                continue
            }

            // We care about content_block_delta events that contain text chunks
            if eventType == "content_block_delta",
               let delta = eventPayload["delta"] as? [String: Any],
               let deltaType = delta["type"] as? String,
               deltaType == "text_delta",
               let textChunk = delta["text"] as? String {
                accumulatedResponseText += textChunk
                // Send the accumulated text so far to the UI for progressive rendering
                let currentAccumulatedText = accumulatedResponseText
                await onTextChunk(currentAccumulatedText)
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    /// Accumulates the pieces of one streamed content block while its
    /// deltas arrive, so a `tool_use` block's arguments (which stream in as
    /// fragments of a JSON string via `input_json_delta`) can be reassembled
    /// once the block closes.
    private struct StreamingContentBlockAccumulator {
        var blockType: String = ""
        var accumulatedText: String = ""
        var toolUseIdentifier: String = ""
        var toolName: String = ""
        var accumulatedToolArgumentsJSON: String = ""
    }

    /// Runs a full tool-use turn against the Anthropic Messages API: streams
    /// text as it arrives, and whenever the model's `stop_reason` comes back
    /// `tool_use`, executes every requested call through
    /// `onToolCallRequested`, appends the results as `tool_result` blocks,
    /// and re-sends the request so the model can continue. Stops once a
    /// response comes back with no tool calls, or after
    /// `maximumToolCallRoundTrips` round trips — a runaway tool-call loop
    /// should end the turn with whatever text exists rather than hang.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        availableTools: [AssistantToolDefinition],
        onTextChunk: @MainActor @Sendable (String) -> Void,
        onToolCallRequested: @MainActor @Sendable (AssistantToolCall) async -> (text: String, isError: Bool)
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        let maximumToolCallRoundTrips = 5

        var messages: [[String: Any]] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append(["type": "text", "text": image.label])
        }
        contentBlocks.append(["type": "text", "text": userPrompt])
        messages.append(["role": "user", "content": contentBlocks])

        let toolsPayload: [[String: Any]] = availableTools.map { tool in
            let schemaObject = (try? JSONSerialization.jsonObject(
                with: Data(tool.inputSchemaJSON.utf8)
            )) as? [String: Any]
            return [
                "name": tool.name,
                "description": tool.description,
                "input_schema": schemaObject ?? ["type": "object", "properties": [String: Any]()]
            ]
        }

        var accumulatedSpokenText = ""

        for _ in 0..<maximumToolCallRoundTrips {
            var request = makeAPIRequest()
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 2048,
                "stream": true,
                "system": systemPrompt,
                "messages": messages,
                "tools": toolsPayload
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (byteStream, response) = try await session.bytes(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(
                    domain: "ClaudeAPI",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
                )
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                var errorBodyChunks: [String] = []
                for try await line in byteStream.lines {
                    errorBodyChunks.append(line)
                }
                let errorBody = errorBodyChunks.joined(separator: "\n")
                throw NSError(
                    domain: "ClaudeAPI",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
                )
            }

            var contentBlocksByIndex: [Int: StreamingContentBlockAccumulator] = [:]
            var stopReason: String?

            for try await line in byteStream.lines {
                guard line.hasPrefix("data: ") else { continue }
                let jsonString = String(line.dropFirst(6))
                guard jsonString != "[DONE]" else { break }

                guard let jsonData = jsonString.data(using: .utf8),
                      let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let eventType = eventPayload["type"] as? String else {
                    continue
                }

                switch eventType {
                case "content_block_start":
                    guard let index = eventPayload["index"] as? Int,
                          let contentBlock = eventPayload["content_block"] as? [String: Any],
                          let blockType = contentBlock["type"] as? String else { continue }
                    var accumulator = StreamingContentBlockAccumulator()
                    accumulator.blockType = blockType
                    if blockType == "tool_use" {
                        accumulator.toolUseIdentifier = contentBlock["id"] as? String ?? ""
                        accumulator.toolName = contentBlock["name"] as? String ?? ""
                    }
                    contentBlocksByIndex[index] = accumulator

                case "content_block_delta":
                    guard let index = eventPayload["index"] as? Int,
                          let delta = eventPayload["delta"] as? [String: Any],
                          let deltaType = delta["type"] as? String else { continue }
                    if deltaType == "text_delta", let textChunk = delta["text"] as? String {
                        contentBlocksByIndex[index]?.accumulatedText += textChunk
                        accumulatedSpokenText += textChunk
                        let currentAccumulatedText = accumulatedSpokenText
                        await onTextChunk(currentAccumulatedText)
                    } else if deltaType == "input_json_delta", let partialJSON = delta["partial_json"] as? String {
                        contentBlocksByIndex[index]?.accumulatedToolArgumentsJSON += partialJSON
                    }

                case "message_delta":
                    if let delta = eventPayload["delta"] as? [String: Any] {
                        stopReason = delta["stop_reason"] as? String
                    }

                default:
                    break
                }
            }

            guard stopReason == "tool_use" else {
                let duration = Date().timeIntervalSince(startTime)
                return (text: accumulatedSpokenText, duration: duration)
            }

            let orderedBlocks = contentBlocksByIndex.sorted { $0.key < $1.key }.map(\.value)

            var assistantContentBlocks: [[String: Any]] = []
            var toolCallsToExecute: [(identifier: String, name: String, argumentsJSON: String)] = []
            for block in orderedBlocks {
                if block.blockType == "text", !block.accumulatedText.isEmpty {
                    assistantContentBlocks.append(["type": "text", "text": block.accumulatedText])
                } else if block.blockType == "tool_use" {
                    let argumentsJSON = block.accumulatedToolArgumentsJSON.isEmpty ? "{}" : block.accumulatedToolArgumentsJSON
                    let parsedArguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any]
                    assistantContentBlocks.append([
                        "type": "tool_use",
                        "id": block.toolUseIdentifier,
                        "name": block.toolName,
                        "input": parsedArguments ?? [String: Any]()
                    ])
                    toolCallsToExecute.append((block.toolUseIdentifier, block.toolName, argumentsJSON))
                }
            }
            messages.append(["role": "assistant", "content": assistantContentBlocks])

            var toolResultBlocks: [[String: Any]] = []
            for pendingCall in toolCallsToExecute {
                let (resultText, isError) = await onToolCallRequested(
                    AssistantToolCall(
                        toolUseIdentifier: pendingCall.identifier,
                        toolName: pendingCall.name,
                        inputArgumentsJSON: pendingCall.argumentsJSON
                    )
                )
                var toolResultBlock: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": pendingCall.identifier,
                    "content": resultText
                ]
                if isError {
                    toolResultBlock["is_error"] = true
                }
                toolResultBlocks.append(toolResultBlock)
            }
            messages.append(["role": "user", "content": toolResultBlocks])
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedSpokenText, duration: duration)
    }

    /// Non-streaming fallback for validation requests where we don't need progressive display.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeAPIRequest()

        var messages: [[String: Any]] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "system": systemPrompt,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "ClaudeAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = json?["content"] as? [[String: Any]],
              let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
              let text = textBlock["text"] as? String else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }
}
