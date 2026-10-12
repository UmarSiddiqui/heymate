//
//  MemoryExtractor.swift
//  HeyMate
//
//  After a Talk exchange, proposes zero or more preference / projectFact
//  records. It does not answer the person and it does not write the store —
//  the caller decides whether to append. Session summaries stay on the
//  rolling path they already have; this only keeps facts worth seeing again.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One durable fact pulled out of a Talk exchange, before it is given an id.
nonisolated struct ExtractedMemory: Equatable, Sendable {
    var kind: MemoryKind
    var text: String
}

/// Turns one finished Talk exchange into preference and project-fact proposals.
///
/// `@MainActor` because every caller is already there, same as
/// `VoiceIntentClassifier`. The network wait is an `await`, not a block.
/// A classifier that is down returns nothing — Talk must still finish.
@MainActor
final class MemoryExtractor {

    /// Same small model the intent classifier uses when the configured model
    /// is a Claude model. A non-Claude endpoint is asked for whatever model
    /// the user actually configured, because that proxy may not have Haiku.
    nonisolated static let classifierModel = VoiceIntentClassifier.classifierModel

    /// Past this, propose nothing. A slow memory pass is worse than none.
    nonisolated static let timeout: TimeInterval = 2.0

    nonisolated static let maxTokens = 200

    /// The reply is prefilled with an opening brace so the model has no room
    /// to preface the JSON with prose.
    nonisolated static let assistantPrefill = "{"

    private let endpointURL: URL?
    private let apiKey: String?
    /// When false, the endpoint and key are read from `CustomAPIConfiguration`
    /// at call time, so a settings change applies to the next exchange.
    private let usesCallerEndpoint: Bool
    private let session: URLSession

    /// Tests replace this so no unit test reaches the network.
    var performRequest: (URLRequest) async throws -> (Data, URLResponse)

    /// Tests replace the on-device reply. Nil means "ask Foundation Models
    /// if this Mac has them." `OnDeviceLanguageClient` only speaks as Talk,
    /// so the extractor does not send the exchange through that client.
    var performOnDeviceExtraction: ((String) async -> String?)?

    /// Tests force the cheap path on or off without touching the keychain.
    /// Nil reads `CustomAPIConfiguration.isUsableForTalk`.
    var customAPIUsableOverride: Bool?

    init(endpoint: String? = nil, apiKey: String? = nil) {
        if let endpoint {
            self.endpointURL = URL(string: endpoint)
            self.usesCallerEndpoint = true
            self.apiKey = apiKey
        } else {
            self.endpointURL = nil
            self.usesCallerEndpoint = false
            self.apiKey = nil
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        self.session = session
        self.performRequest = { try await session.data(for: $0) }
        self.performOnDeviceExtraction = nil
        self.customAPIUsableOverride = nil
    }

    /// Proposals only. `ownerMateID` is stamped on every new item; Talk passes
    /// `MemoryContext.heyMateTalkOwnerID`. Existing rows are the dedupe set.
    func extract(
        user: String,
        assistant: String,
        existing: [MemoryItem],
        ownerMateID: UUID?
    ) async -> [MemoryItem] {
        let exchange = Self.exchangeText(user: user, assistant: assistant)
        guard !exchange.isEmpty else { return [] }

        let extracted: [ExtractedMemory]
        if usesCustomAPI() {
            extracted = await extractThroughCustomAPI(exchange: exchange)
        } else {
            extracted = await extractOnDevice(exchange: exchange)
        }

        let now = Date()
        let candidates = extracted.map { memory in
            MemoryItem(
                id: UUID(),
                kind: memory.kind,
                text: memory.text,
                createdAt: now,
                mateID: ownerMateID
            )
        }
        return FileMemoryRepository.proposedAppends(candidates, existing: existing)
    }

    private func usesCustomAPI() -> Bool {
        customAPIUsableOverride
            ?? (CustomAPIConfiguration.isUsableForTalk && CustomAPIConfiguration.format == .anthropic)
    }

    // MARK: - Cheap path

    private func extractThroughCustomAPI(exchange: String) async -> [ExtractedMemory] {
        guard let target = resolvedRequestTarget(),
              let requestBody = try? JSONSerialization.data(
                withJSONObject: Self.requestBody(exchange: exchange, model: resolvedModel())
              ) else { return [] }

        var request = URLRequest(url: target.url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = target.apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.httpBody = requestBody

        do {
            let (data, response) = try await performRequest(request)
            guard let httpResponse = response as? HTTPURLResponse else { return [] }
            guard (200...299).contains(httpResponse.statusCode) else { return [] }
            guard let replyText = VoiceIntentClassifier.replyText(fromResponseData: data) else { return [] }
            return Self.items(fromClassifierReply: replyText) ?? []
        } catch {
            return []
        }
    }

    private func resolvedRequestTarget() -> (url: URL, apiKey: String?)? {
        if usesCallerEndpoint {
            guard let endpointURL else { return nil }
            return (endpointURL, apiKey)
        }
        let trimmed = CustomAPIConfiguration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return (url, CustomAPIConfiguration.apiKey())
    }

    private func resolvedModel() -> String {
        let configured = usesCallerEndpoint ? "" : CustomAPIConfiguration.model
        return Self.classifierModel(configured: configured)
    }

    // MARK: - On-device fallback

    /// Used only when the custom endpoint is not usable. There is no invented
    /// call to Anthropic's default URL.
    private func extractOnDevice(exchange: String) async -> [ExtractedMemory] {
        let reply: String?
        if let performOnDeviceExtraction {
            reply = await performOnDeviceExtraction(exchange)
        } else {
            reply = await foundationModelReply(exchange: exchange)
        }
        guard let reply, let items = Self.items(fromClassifierReply: reply) else { return [] }
        return items
    }

    private func foundationModelReply(exchange: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { return nil }
            return await withTaskGroup(of: String?.self) { group in
                group.addTask { @MainActor in
                    await MemoryExtractor.generateOnDevice(exchange: exchange)
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(MemoryExtractor.timeout * 1_000_000_000))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func generateOnDevice(exchange: String) async -> String? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }
        let session = LanguageModelSession(model: model, instructions: systemPrompt)
        do {
            let response = try await session.respond(
                to: String(exchange.suffix(2_000)),
                options: GenerationOptions(maximumResponseTokens: maxTokens)
            )
            return response.content
        } catch {
            return nil
        }
    }
    #endif

    // MARK: - Pure

    nonisolated static func classifierModel(configured: String) -> String {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased().hasPrefix("claude") {
            return classifierModel
        }
        return trimmed
    }

    nonisolated static let systemPrompt = """
    You read one finished Talk exchange and pull out durable memory for \
    HeyMate. You are not the assistant. You never answer the person, never \
    continue the conversation, and never ask a question.

    Reply with a single JSON object and nothing else.

    Shape: {"items":[{"kind":"preference"|"projectFact","text":"…"}]}

    preference — a stable way this person wants things done, in their words, \
    that they stated or clearly agreed to.

    projectFact — a lasting fact about a named project, person, or place that \
    they stated or clearly agreed to.

    Use an empty items array when nothing should be kept. Skip one-off tasks, \
    questions, small talk, and anything that is only a recap of this \
    conversation. Never record passwords, API keys, tokens, or other secrets. \
    One short sentence per item. Do not invent anything they did not say or \
    confirm.
    """

    nonisolated static func exchangeText(user: String, assistant: String) -> String {
        let userText = clipped(user)
        let assistantText = clipped(assistant)
        guard !userText.isEmpty || !assistantText.isEmpty else { return "" }
        return "User:\n\(userText)\n\nAssistant:\n\(assistantText)"
    }

    nonisolated static func requestBody(exchange: String, model: String) -> [String: Any] {
        [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": exchange],
                ["role": "assistant", "content": assistantPrefill]
            ]
        ]
    }

    /// Accepts either a full JSON object or the tail that follows the prefilled brace.
    /// A nested `{...}` inside the tail is not the decision; the object that
    /// actually has an `items` array is.
    nonisolated static func items(fromClassifierReply reply: String) -> [ExtractedMemory]? {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            if let parsed = items(fromModelReply: trimmed) { return parsed }
            return items(fromPrefilledReply: trimmed)
        }
        if let parsed = items(fromPrefilledReply: trimmed) { return parsed }
        return items(fromModelReply: trimmed)
    }

    nonisolated static func items(fromPrefilledReply reply: String) -> [ExtractedMemory]? {
        items(fromModelReply: assistantPrefill + reply)
    }

    /// Nil when the reply is not the expected object. An empty `items` array
    /// is a successful "nothing durable" answer, not a parse failure.
    nonisolated static func items(fromModelReply reply: String) -> [ExtractedMemory]? {
        guard let jsonText = VoiceIntentClassifier.firstJSONObject(in: reply),
              let jsonData = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let rawItems = json["items"] as? [Any] else { return nil }

        var extracted: [ExtractedMemory] = []
        for rawItem in rawItems {
            guard let fields = rawItem as? [String: Any],
                  let memory = item(from: fields) else { continue }
            extracted.append(memory)
        }
        return extracted
    }

    nonisolated static func item(from fields: [String: Any]) -> ExtractedMemory? {
        guard let rawKind = fields["kind"] as? String,
              let rawText = fields["text"] as? String else { return nil }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !textContainsCredential(text) else { return nil }
        guard let kind = durableKind(named: rawKind) else { return nil }
        return ExtractedMemory(kind: kind, text: text)
    }

    /// Session summaries are not proposals. Unknown kinds are ignored.
    nonisolated static func durableKind(named rawKind: String) -> MemoryKind? {
        let key = rawKind
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        switch key {
        case "preference":
            return .preference
        case "projectfact":
            return .projectFact
        case "sessionsummary":
            return nil
        default:
            return nil
        }
    }

    /// A stored sentence that is itself a secret. Mentioning the word
    /// "password" in a preference is fine; "password is hunter2" is not.
    nonisolated static func textContainsCredential(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.range(
            of: #"(^|[^a-z0-9])(sk-ant-|sk-proj-|sk-|ghp_|github_pat_|xox[baprs]-|akia)"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        let pattern = #"(?i)\b(password|passcode|api[-_ ]?key|access token|refresh token|private key|client secret)\b\s*(is|=|:)\s*([^\s,;]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 4,
              let valueRange = Range(match.range(at: 3), in: text) else { return false }
        return credentialValue(String(text[valueRange]))
    }

    nonisolated private static func credentialValue(_ value: String) -> Bool {
        let token = value.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
        guard token.count >= 6 else { return false }
        let ordinaryWords: Set<String> = ["nothing", "manager", "keychain", "stored", "secret", "hidden", "private", "enabled", "disabled"]
        if ordinaryWords.contains(token.lowercased()) { return false }
        if token.contains(where: { $0.isNumber }) { return true }
        return token.count >= 12
    }

    nonisolated private static func clipped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 1_500
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.suffix(limit))
    }
}
