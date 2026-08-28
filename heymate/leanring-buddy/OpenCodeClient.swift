//
//  OpenCodeClient.swift
//  leanring-buddy
//
//  VisionConversationClient backed by a locally running `opencode serve`
//  HTTP server (https://opencode.ai/docs/server). Lets any model configured
//  in opencode power the companion while keeping the exact same call shape
//  as ClaudeAPI, so CompanionManager needs no per-provider branching.
//
//  Request flow per turn:
//    1. POST /session                 → create a scratch session
//    2. POST /session/:id/message     → send system prompt + images + prompt,
//                                       wait for the finished response
//    3. DELETE /session/:id           → best-effort cleanup
//
//  The DELETE matters for privacy: the app promises screenshots are never
//  stored, and opencode persists session parts (including image attachments)
//  to disk. Deleting the scratch session keeps that promise.
//
//  Conversation history is replayed inline in the prompt text because each
//  request uses a fresh session; this mirrors how the protocol already hands
//  history to every provider explicitly.
//

import Foundation

final class OpenCodeClient: VisionConversationClient {

    /// Base URL of the opencode server, e.g. "http://127.0.0.1:4096".
    private let serverBaseURL: URL

    /// Provider owning `model` (e.g. "anthropic"). Nil only until the user
    /// picks a model; requests fail with a clear error in that state.
    var providerID: String?

    /// The model identifier used for requests (e.g. "claude-sonnet-4-6").
    var model: String

    /// Optional HTTP basic auth matching OPENCODE_SERVER_USERNAME /
    /// OPENCODE_SERVER_PASSWORD on the server. Password nil/empty = no auth.
    private let basicAuthUsername: String?
    private let basicAuthPassword: String?

    private let session: URLSession

    init(
        serverBaseURL: URL,
        providerID: String?,
        modelID: String,
        basicAuthUsername: String? = nil,
        basicAuthPassword: String? = nil
    ) {
        self.serverBaseURL = serverBaseURL
        self.providerID = providerID
        self.model = modelID
        self.basicAuthUsername = basicAuthUsername
        self.basicAuthPassword = basicAuthPassword

        // Same tuning as ClaudeAPI: default config so keep-alive connections
        // are reused across turns, no on-disk cache or cookies.
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - VisionConversationClient

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        guard let providerID, !model.isEmpty else {
            throw NSError(
                domain: "OpenCodeClient",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey:
                    "No OpenCode model selected. Open Models and pick one."]
            )
        }

        // 1. Scratch session for this single exchange.
        let createdSessionID = try await createScratchSession()
        defer { deleteScratchSession(id: createdSessionID) }

        // 2. Send the full turn and wait for the completed response.
        let responseText = try await sendMessage(
            sessionID: createdSessionID,
            providerID: providerID,
            modelID: model,
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )

        // The synchronous message endpoint returns the whole answer at once;
        // every current call site treats chunks as optional progressive UI.
        await onTextChunk(responseText)

        let duration = Date().timeIntervalSince(startTime)
        return (text: responseText, duration: duration)
    }

    // MARK: - Server Introspection (used by the settings screen)

    /// GET /global/health — returns the server version when reachable.
    static func fetchServerVersion(
        baseURL: URL,
        basicAuthUsername: String?,
        basicAuthPassword: String?
    ) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("global/health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        applyBasicAuth(to: &request, username: basicAuthUsername, password: basicAuthPassword)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "OpenCodeClient",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Health check failed"]
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["healthy"] as? Bool == true else {
            throw NSError(
                domain: "OpenCodeClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Server reported unhealthy"]
            )
        }
        return json["version"] as? String ?? "unknown"
    }

    /// GET /config/providers — every model the server can serve right now.
    /// Parsed defensively because the shape varies slightly between versions.
    static func fetchAvailableModels(
        baseURL: URL,
        basicAuthUsername: String?,
        basicAuthPassword: String?
    ) async throws -> [OpenCodeModelOption] {
        var request = URLRequest(url: baseURL.appendingPathComponent("config/providers"))
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        applyBasicAuth(to: &request, username: basicAuthUsername, password: basicAuthPassword)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "OpenCodeClient",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not list models"]
            )
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = json["providers"] as? [[String: Any]] else {
            return []
        }

        var models: [OpenCodeModelOption] = []
        for provider in providers {
            guard let currentProviderID = provider["id"] as? String else { continue }
            let providerName = provider["name"] as? String ?? currentProviderID

            if let modelsDictionary = provider["models"] as? [String: Any] {
                // Shape A: models keyed by model ID → { id?, name?, ... }
                for (dictionaryKey, modelValue) in modelsDictionary {
                    let modelDictionary = modelValue as? [String: Any]
                    let modelID = modelDictionary?["id"] as? String ?? dictionaryKey
                    let modelName = modelDictionary?["name"] as? String ?? modelID
                    models.append(OpenCodeModelOption(
                        providerID: currentProviderID,
                        providerName: providerName,
                        modelID: modelID,
                        modelName: modelName.isEmpty ? "\(providerName) · \(modelID)" : modelName
                    ))
                }
            } else if let modelsArray = provider["models"] as? [[String: Any]] {
                // Shape B: models as a plain array of { id, name?, ... }
                for modelDictionary in modelsArray {
                    guard let modelID = modelDictionary["id"] as? String else { continue }
                    let modelName = modelDictionary["name"] as? String ?? modelID
                    models.append(OpenCodeModelOption(
                        providerID: currentProviderID,
                        providerName: providerName,
                        modelID: modelID,
                        modelName: modelName.isEmpty ? "\(providerName) · \(modelID)" : modelName
                    ))
                }
            }
        }
        return models
    }

    // MARK: - Private Request Helpers

    private func makeJSONRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        Self.applyBasicAuth(to: &request, username: basicAuthUsername, password: basicAuthPassword)
        return request
    }

    private func createScratchSession() async throws -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let body: [String: Any] = ["title": "HeyMate \(formatter.string(from: Date()))"]

        var request = makeJSONRequest(url: serverBaseURL.appendingPathComponent("session"), method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = json["id"] as? String, !sessionID.isEmpty else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "OpenCodeClient",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Could not create OpenCode session (\(bodyText.prefix(200)))"]
            )
        }
        return sessionID
    }

    /// Best-effort cleanup — failures are logged and swallowed because the
    /// response has already been delivered at that point.
    private func deleteScratchSession(id: String) {
        var request = makeJSONRequest(url: serverBaseURL.appendingPathComponent("session/\(id)"), method: "DELETE")
        request.httpBody = nil
        session.dataTask(with: request) { _, response, error in
            if let error {
                print("⚠️ OpenCode: scratch session cleanup failed: \(error.localizedDescription)")
            } else if let httpResponse = response as? HTTPURLResponse,
                      !(200...299).contains(httpResponse.statusCode) {
                print("⚠️ OpenCode: scratch session cleanup returned \(httpResponse.statusCode)")
            }
        }.resume()
    }

    private func sendMessage(
        sessionID: String,
        providerID: String,
        modelID: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) async throws -> String {
        var parts: [[String: Any]] = []
        for image in images {
            let mimeType = Self.detectImageMediaType(for: image.data)
            parts.append([
                "type": "file",
                "mime": mimeType,
                "url": "data:\(mimeType);base64,\(image.data.base64EncodedString())"
            ])
            parts.append(["type": "text", "text": image.label])
        }
        parts.append(["type": "text", "text": Self.composedUserPrompt(userPrompt, history: conversationHistory)])

        let body: [String: Any] = [
            "model": ["providerID": providerID, "modelID": modelID],
            "system": systemPrompt,
            "parts": parts
        ]

        var request = makeJSONRequest(
            url: serverBaseURL.appendingPathComponent("session/\(sessionID)/message"),
            method: "POST"
        )
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 OpenCode request to \(providerID)/\(modelID): \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "OpenCodeClient",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(bodyText.prefix(400))"]
            )
        }

        return try Self.extractTextFromMessageResponse(data)
    }

    // MARK: - Parsing Helpers

    /// Pulls assistant text out of the /message response. The documented shape
    /// is { info, parts }; older builds may return a bare parts array.
    static func extractTextFromMessageResponse(_ data: Data) throws -> String {
        let json = try? JSONSerialization.jsonObject(with: data)
        var partList: [[String: Any]] = []

        if let dictionary = json as? [String: Any], let parts = dictionary["parts"] as? [[String: Any]] {
            partList = parts
        } else if let parts = json as? [[String: Any]] {
            partList = parts
        }

        let textParts = partList.compactMap { part -> String? in
            guard part["type"] as? String == "text" else { return nil }
            return part["text"] as? String
        }

        let joinedText = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joinedText.isEmpty else {
            throw NSError(
                domain: "OpenCodeClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenCode response contained no text"]
            )
        }
        return joinedText
    }

    /// Builds the single user prompt sent to opencode: prior exchanges are
    /// replayed inline above the live question because each request runs in
    /// a fresh scratch session.
    static func composedUserPrompt(
        _ userPrompt: String,
        history: [(userPlaceholder: String, assistantResponse: String)]
    ) -> String {
        guard !history.isEmpty else { return userPrompt }

        let transcriptLines = history.suffix(10).map { entry in
            """
            user said: \(entry.userPlaceholder)
            you replied: \(entry.assistantResponse)
            """
        }
        return """
        earlier in this same conversation (for context only, do not respond to these):
        ---
        \(transcriptLines.joined(separator: "\n---\n"))
        ---

        (the current request follows)

        \(userPrompt)
        """
    }

    /// Detects image MIME from magic bytes — screen captures are JPEG, but
    /// defensive PNG detection keeps the data-URI mime honest.
    static func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            if [UInt8](imageData.prefix(4)) == pngSignature {
                return "image/png"
            }
        }
        return "image/jpeg"
    }

    static func applyBasicAuth(
        to request: inout URLRequest,
        username: String?,
        password: String?
    ) {
        guard let password, !password.isEmpty else { return }
        let credential = "\(username?.isEmpty == false ? username! : "opencode"):\(password)"
        let encoded = Data(credential.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
    }
}
