//
//  ElevenLabsScribeTranscriptionProvider.swift
//  HeyMate
//
//  Streaming transcription backed by ElevenLabs Scribe v2 Realtime.
//  Audio goes up as base64 PCM16 chunks over a websocket; the server answers
//  with partial transcripts while you talk and a committed transcript once
//  the app commits the segment on key release.
//

import AVFoundation
import Foundation

struct ElevenLabsScribeTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class ElevenLabsScribeTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "ElevenLabs"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool { ElevenLabsCredentials.isAvailable }

    var unavailableExplanation: String? {
        guard !isConfigured else { return nil }
        return "Add your ElevenLabs API key in Settings to use ElevenLabs."
    }

    /// Single long-lived URLSession shared across all streaming sessions.
    /// Creating and invalidating a URLSession per session corrupts the OS
    /// connection pool and causes "Socket is not connected" errors after
    /// a few rapid reconnections to the same host.
    private let sharedWebSocketURLSession = URLSession(configuration: .default)

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let authorization: ElevenLabsScribeStreamingSession.Authorization
        if let userAPIKey = ElevenLabsCredentials.userAPIKey() {
            authorization = .apiKey(userAPIKey)
        } else if ElevenLabsCredentials.hasWorkerAccess {
            authorization = .singleUseToken(try await fetchWorkerSingleUseToken())
        } else {
            throw ElevenLabsScribeTranscriptionProviderError(
                message: unavailableExplanation ?? "ElevenLabs is not set up."
            )
        }

        let session = ElevenLabsScribeStreamingSession(
            authorization: authorization,
            urlSession: sharedWebSocketURLSession,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )

        try await session.open()
        return session
    }

    /// Asks the developer Worker for a Scribe single-use token. The real key
    /// never leaves the Worker.
    private func fetchWorkerSingleUseToken() async throws -> String {
        let tokenURLString = "\(ElevenLabsCredentials.workerBaseURLString)/v1/stt/session-token"
        guard let tokenURL = URL(string: tokenURLString) else {
            throw ElevenLabsScribeTranscriptionProviderError(message: "The Worker URL is invalid.")
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        BackendClient.applyAuthorization(to: &request)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ElevenLabsScribeTranscriptionProviderError(
                message: "Couldn't get an ElevenLabs listening token (HTTP \(statusCode))."
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String,
              !token.isEmpty else {
            throw ElevenLabsScribeTranscriptionProviderError(
                message: "Invalid token response from the Worker."
            )
        }

        return token
    }
}

private final class ElevenLabsScribeStreamingSession: NSObject, BuddyStreamingTranscriptionSession {
    enum Authorization {
        /// Sent as the `xi-api-key` header, so it never lands in a URL.
        case apiKey(String)
        /// Consumed on first use; travels in the `token` query parameter.
        case singleUseToken(String)
    }

    private struct MessageEnvelope: Decodable {
        let message_type: String
    }

    private struct TranscriptMessage: Decodable {
        let message_type: String
        let text: String?
    }

    private struct ErrorMessage: Decodable {
        let message_type: String
        let error: String?
    }

    private static let websocketBaseURLString = "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
    private static let modelID = "scribe_v2_realtime"
    private static let targetSampleRate = 16_000
    private static let explicitFinalTranscriptGracePeriodSeconds = 1.4

    let finalTranscriptFallbackDelaySeconds: TimeInterval = 2.8

    private let authorization: Authorization
    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.heymate.elevenlabs.scribe.state")
    private let sendQueue = DispatchQueue(label: "com.heymate.elevenlabs.scribe.send")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )
    private let urlSession: URLSession

    private var webSocketTask: URLSessionWebSocketTask?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var hasResolvedReadyContinuation = false
    private var hasDeliveredFinalTranscript = false
    private var isAwaitingExplicitFinalTranscript = false
    /// Segments the server has committed, oldest first. Push-to-talk commits
    /// once on release, but the server may also commit on its own during a
    /// long hold, so the transcript is every commit plus the live partial.
    private var committedSegments: [String] = []
    private var partialTranscriptText = ""
    private var explicitFinalTranscriptDeadlineWorkItem: DispatchWorkItem?

    init(
        authorization: Authorization,
        urlSession: URLSession,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.authorization = authorization
        self.urlSession = urlSession
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func open() async throws {
        var websocketRequest = URLRequest(url: try makeWebsocketURL())
        if case .apiKey(let apiKey) = authorization {
            websocketRequest.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        }

        let webSocketTask = urlSession.webSocketTask(with: websocketRequest)
        self.webSocketTask = webSocketTask
        webSocketTask.resume()

        receiveNextMessage()

        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                self.readyContinuation = continuation
            }
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        sendAudioChunk(audioPCM16Data, commit: false)
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasDeliveredFinalTranscript else { return }
            self.isAwaitingExplicitFinalTranscript = true
            self.scheduleExplicitFinalTranscriptDeadline()
        }

        // An empty chunk with commit set is how the SDK commits: it closes the
        // segment and makes the server send a committed transcript.
        sendAudioChunk(Data(), commit: true)
    }

    func cancel() {
        stateQueue.async {
            self.explicitFinalTranscriptDeadlineWorkItem?.cancel()
            self.explicitFinalTranscriptDeadlineWorkItem = nil
        }

        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    private func sendAudioChunk(_ audioPCM16Data: Data, commit: Bool) {
        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": audioPCM16Data.base64EncodedString(),
            "commit": commit,
            "sample_rate": Self.targetSampleRate
        ]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        sendQueue.async { [weak self] in
            guard let self, let webSocketTask = self.webSocketTask else { return }
            webSocketTask.send(.string(jsonString)) { [weak self] error in
                if let error {
                    self?.failSession(with: error)
                }
            }
        }
    }

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncomingTextMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingTextMessage(text)
                    }
                @unknown default:
                    break
                }

                self.receiveNextMessage()
            case .failure(let error):
                self.failSession(with: error)
            }
        }
    }

    private func handleIncomingTextMessage(_ text: String) {
        guard let messageData = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(MessageEnvelope.self, from: messageData) else {
            return
        }

        switch envelope.message_type {
        case "session_started":
            resolveReadyContinuationIfNeeded(with: .success(()))
        case "partial_transcript":
            guard let transcriptMessage = try? JSONDecoder().decode(TranscriptMessage.self, from: messageData) else { return }
            handleTranscript(transcriptMessage.text ?? "", isCommitted: false)
        case "committed_transcript", "committed_transcript_with_timestamps":
            guard let transcriptMessage = try? JSONDecoder().decode(TranscriptMessage.self, from: messageData) else { return }
            handleTranscript(transcriptMessage.text ?? "", isCommitted: true)
        case "warning", "committed_transcript_entities", "edited_transcript":
            break
        default:
            // Every other message type is one of Scribe's error shapes
            // (auth_error, quota_exceeded, rate_limited, input_error, …).
            let errorMessage = try? JSONDecoder().decode(ErrorMessage.self, from: messageData)
            let messageText = errorMessage?.error ?? "ElevenLabs returned \(envelope.message_type)."
            failSession(with: ElevenLabsScribeTranscriptionProviderError(message: messageText))
        }
    }

    private func handleTranscript(_ rawText: String, isCommitted: Bool) {
        let transcriptText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        stateQueue.async {
            if isCommitted {
                if !transcriptText.isEmpty {
                    self.committedSegments.append(transcriptText)
                }
                self.partialTranscriptText = ""
            } else {
                self.partialTranscriptText = transcriptText
            }

            let fullTranscriptText = self.composeFullTranscript()
            if !fullTranscriptText.isEmpty {
                self.onTranscriptUpdate(fullTranscriptText)
            }

            if isCommitted && self.isAwaitingExplicitFinalTranscript {
                self.deliverFinalTranscriptIfNeeded(fullTranscriptText)
            }
        }
    }

    private func composeFullTranscript() -> String {
        var transcriptSegments = committedSegments
        if !partialTranscriptText.isEmpty {
            transcriptSegments.append(partialTranscriptText)
        }
        return transcriptSegments.joined(separator: " ")
    }

    private func scheduleExplicitFinalTranscriptDeadline() {
        explicitFinalTranscriptDeadlineWorkItem?.cancel()

        let deadlineWorkItem = DispatchWorkItem { [weak self] in
            self?.stateQueue.async {
                guard let self else { return }
                self.deliverFinalTranscriptIfNeeded(self.composeFullTranscript())
            }
        }

        explicitFinalTranscriptDeadlineWorkItem = deadlineWorkItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.explicitFinalTranscriptGracePeriodSeconds,
            execute: deadlineWorkItem
        )
    }

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        explicitFinalTranscriptDeadlineWorkItem?.cancel()
        explicitFinalTranscriptDeadlineWorkItem = nil
        onFinalTranscriptReady(transcriptText.trimmingCharacters(in: .whitespacesAndNewlines))
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
    }

    private func failSession(with error: Error) {
        resolveReadyContinuationIfNeeded(with: .failure(error))
        stateQueue.async {
            guard !self.hasDeliveredFinalTranscript else { return }
            let latestTranscriptText = self.composeFullTranscript()

            if self.isAwaitingExplicitFinalTranscript && !latestTranscriptText.isEmpty {
                HeyMateLog.log("[ElevenLabs Scribe] ⚠️ Session error while finishing, delivering partial transcript: \(error.localizedDescription)")
                self.deliverFinalTranscriptIfNeeded(latestTranscriptText)
                return
            }
            HeyMateLog.log("[ElevenLabs Scribe] ❌ Session failed: \(error.localizedDescription)")

            self.onError(error)
        }
    }

    private func resolveReadyContinuationIfNeeded(with result: Result<Void, Error>) {
        stateQueue.async {
            guard !self.hasResolvedReadyContinuation else { return }
            self.hasResolvedReadyContinuation = true

            switch result {
            case .success:
                self.readyContinuation?.resume()
            case .failure(let error):
                self.readyContinuation?.resume(throwing: error)
            }

            self.readyContinuation = nil
        }
    }

    private func makeWebsocketURL() throws -> URL {
        guard var websocketURLComponents = URLComponents(string: Self.websocketBaseURLString) else {
            throw ElevenLabsScribeTranscriptionProviderError(message: "ElevenLabs websocket URL is invalid.")
        }

        var queryItems = [
            URLQueryItem(name: "model_id", value: Self.modelID),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "manual")
        ]

        // Same encoding the official SDK uses: one `keyterms` item per term.
        // Capped so a long contextual list cannot push the URL past what the
        // server accepts.
        let normalizedKeyterms = keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 50 }
            .prefix(50)
        queryItems.append(contentsOf: normalizedKeyterms.map { URLQueryItem(name: "keyterms", value: $0) })

        if case .singleUseToken(let token) = authorization {
            queryItems.append(URLQueryItem(name: "token", value: token))
        }

        websocketURLComponents.queryItems = queryItems

        guard let websocketURL = websocketURLComponents.url else {
            throw ElevenLabsScribeTranscriptionProviderError(message: "ElevenLabs websocket URL could not be created.")
        }

        return websocketURL
    }
}
