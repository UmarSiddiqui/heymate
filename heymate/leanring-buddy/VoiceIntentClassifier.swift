//
//  VoiceIntentClassifier.swift
//  leanring-buddy
//
//  Decides whether a spoken sentence is a question, a job, or a shortcut.
//
//  This replaces a hand-written list of eleven nouns ("landing page",
//  "website", "html", …) that decided whether "make me a …" was coding work.
//  Anything outside that list — "clean up my Downloads folder", "draft the
//  reply to Sam" — fell through to Talk, which has no filesystem, refused,
//  and left the user believing the agent did not exist.
//
//  It is deliberately ONE call with three answers, not a cascade of guards.
//  `VoiceRouter` still answers everything it can answer for free first; this
//  runs only on what is genuinely ambiguous.
//

import Foundation

nonisolated struct VoiceIntentDecision: Equatable, Sendable {

    enum Route: String, Equatable, Sendable {
        /// Answer now, from the screen. The overwhelming majority of turns.
        case talk
        /// Durable work in a folder, through the plan-then-approve gate.
        case agent
        /// A macOS shortcut HeyMate performs itself (open an app, volume).
        case local
    }

    var route: Route
    /// For `.agent`, the instruction with filler stripped. Empty otherwise.
    var task: String

    static let talk = VoiceIntentDecision(route: .talk, task: "")
}

/// Turns a transcript into a route using one small-model call.
///
/// `@MainActor` because the cache is shared mutable state and every caller is
/// already on the main actor; the network wait is an `await`, not a block.
@MainActor
final class VoiceIntentClassifier {

    /// Haiku is the right size for a three-way choice, and the round trip is
    /// what the user is waiting through — a larger model would be worse at the
    /// only thing that matters here, which is answering quickly.
    nonisolated static let classifierModel = "claude-haiku-4-5-20251001"

    /// Past this, fall back to the local heuristics rather than keep the user
    /// waiting. A slow classifier is worse than a blunt one.
    static let timeout: TimeInterval = 2.0

    private var endpointURL: URL
    private var apiKey: String?
    private let session: URLSession
    private var cachedDecisions: [String: VoiceIntentDecision] = [:]

    /// Tests replace this so no unit test reaches the network.
    var performRequest: (URLRequest) async throws -> (Data, URLResponse)

    init(proxyURL: String, apiKey: String? = nil) {
        self.endpointURL = URL(string: proxyURL)!
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = VoiceIntentClassifier.timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        self.session = session
        self.performRequest = { try await session.data(for: $0) }
    }

    func configure(proxyURL: String, apiKey: String?) {
        if let url = URL(string: proxyURL) {
            endpointURL = url
        }
        self.apiKey = apiKey
    }

    /// Nil means "could not decide" — the caller falls back to the local
    /// heuristics rather than guessing. A classifier that is down must never
    /// stop the app from answering.
    func classify(_ transcript: String) async -> VoiceIntentDecision? {
        let cacheKey = Self.cacheKey(for: transcript)
        guard !cacheKey.isEmpty else { return nil }
        if let cached = cachedDecisions[cacheKey] { return cached }

        guard let requestBody = try? JSONSerialization.data(
            withJSONObject: Self.requestBody(for: transcript)
        ) else { return nil }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        request.httpBody = requestBody

        do {
            let (data, response) = try await performRequest(request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return nil }
            guard let replyText = Self.replyText(fromResponseData: data),
                  let decision = Self.decision(fromPrefilledReply: replyText) else { return nil }

            rememberDecision(decision, forKey: cacheKey)
            return decision
        } catch {
            return nil
        }
    }

    /// Bounded so a long session cannot grow this without limit. Voice
    /// transcripts repeat far more than they vary, so even a small cache
    /// removes the round trip from most repeated phrasings.
    private func rememberDecision(_ decision: VoiceIntentDecision, forKey cacheKey: String) {
        if cachedDecisions.count >= 200 {
            cachedDecisions.removeAll(keepingCapacity: true)
        }
        cachedDecisions[cacheKey] = decision
    }

    // MARK: - Pure

    nonisolated static func cacheKey(for transcript: String) -> String {
        SpokenText.normalizedSpokenCommandText(transcript)
    }

    /// What the classifier is told.
    ///
    /// The "you are not the assistant" paragraph is not filler. Without it,
    /// an under-specified sentence — "draft the reply to Sam", "summarise this
    /// pdf" — gets answered rather than routed: the model replies "I don't
    /// have the context of Sam's message" and no JSON comes back at all.
    /// Observed on every such phrasing before this line existed.
    nonisolated static let systemPrompt = """
    You route one spoken sentence for a Mac assistant. You are not the \
    assistant. You never answer the sentence, never ask for clarification, and \
    never mention missing context. A vague or under-specified sentence still \
    has a route — pick it.

    Reply with a single JSON object and nothing else.

    Shape: {"route":"talk"|"agent"|"local","task":"…"}

    talk — the person wants an answer now, usually about what is on their \
    screen. Questions, explanations, opinions, reading something aloud, \
    anything referring to "this", "that", or what is visible. When torn \
    between talk and agent, choose talk.

    agent — the person wants work done over time in files or folders: build, \
    fix, refactor, organise, clean up, research and write something down, \
    draft a document or a message. Missing details are not your problem; the \
    agent will ask. Set "task" to the instruction with filler removed and \
    nothing added — do not expand it, do not guess at details, do not turn a \
    short request into a specification.

    local — a plain Mac shortcut the assistant performs itself: opening an \
    application, changing the volume, locking the screen.

    Set "task" to "" for talk and local.
    """

    /// The reply is prefilled with an opening brace so the model has no room
    /// to preface the JSON with prose. Whatever comes back is therefore the
    /// *rest* of the object — see `decision(fromPrefilledReply:)`.
    nonisolated static let assistantPrefill = "{"

    nonisolated static func requestBody(for transcript: String) -> [String: Any] {
        [
            "model": classifierModel,
            "max_tokens": 200,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": transcript],
                ["role": "assistant", "content": assistantPrefill]
            ]
        ]
    }

    nonisolated static func replyText(fromResponseData data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
              let text = textBlock["text"] as? String else { return nil }
        return text
    }

    /// The model continues from `assistantPrefill`, so the opening brace has
    /// to be put back before the text is a JSON object again.
    nonisolated static func decision(fromPrefilledReply reply: String) -> VoiceIntentDecision? {
        decision(fromModelReply: assistantPrefill + reply)
    }

    /// Pulls the decision out of a reply that may have prose or a code fence
    /// wrapped around it. A model that answered in the wrong shape returns nil
    /// rather than a wrong route.
    nonisolated static func decision(fromModelReply reply: String) -> VoiceIntentDecision? {
        guard let jsonText = firstJSONObject(in: reply),
              let jsonData = jsonText.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let rawRoute = json["route"] as? String,
              let route = VoiceIntentDecision.Route(
                  rawValue: rawRoute.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
              ) else { return nil }

        let rawTask = (json["task"] as? String) ?? ""
        let task = SpokenText.cleanedAgentTaskInstruction(rawTask)

        // An agent route with nothing to do is not a route. Falling back to
        // Talk is safe; spawning a job with an empty prompt is not.
        if route == .agent, task.isEmpty { return nil }

        return VoiceIntentDecision(route: route, task: route == .agent ? task : "")
    }

    /// The first balanced `{ … }` span, so a fenced or chatty reply still
    /// parses. Braces inside strings are skipped so a task containing one
    /// cannot truncate the object.
    nonisolated static func firstJSONObject(in text: String) -> String? {
        var depth = 0
        var startIndex: String.Index?
        var isInsideString = false
        var isEscaped = false

        for index in text.indices {
            let character = text[index]

            if isEscaped {
                isEscaped = false
                continue
            }
            if character == "\\" , isInsideString {
                isEscaped = true
                continue
            }
            if character == "\"" {
                isInsideString.toggle()
                continue
            }
            guard !isInsideString else { continue }

            if character == "{" {
                if depth == 0 { startIndex = index }
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let startIndex {
                    return String(text[startIndex...index])
                }
                if depth < 0 { return nil }
            }
        }
        return nil
    }
}
