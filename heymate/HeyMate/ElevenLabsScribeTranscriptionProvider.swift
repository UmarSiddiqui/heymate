//
//  ElevenLabsScribeTranscriptionProvider.swift
//  HeyMate
//
//  Streaming speech-to-text over ElevenLabs Scribe v2 Realtime. Microphone
//  audio is resampled to 16 kHz PCM16 and streamed up a websocket; the
//  server sends partial transcripts while the user talks and a committed
//  transcript after HeyMate commits the segment on key release.
//

import AVFoundation
import Foundation

final class ElevenLabsScribeTranscriptionProvider: SpeechToTextProvider {
    let displayName = "ElevenLabs"
    let needsSpeechRecognitionPermission = false

    var isConfigured: Bool { ElevenLabsCredentials.isAvailable }

    var unavailableExplanation: String? {
        isConfigured ? nil : "Add your ElevenLabs API key in Settings to use ElevenLabs."
    }

    /// One session object for every websocket. Creating and invalidating a
    /// URLSession per press wears out the connection pool and starts failing
    /// with "Socket is not connected" after a few quick presses.
    private static let websocketURLSession = URLSession(configuration: .default)

    func openSession(
        keyterms: [String],
        handlers: TranscriptionHandlers
    ) async throws -> any LiveTranscriptionSession {
        let credential: ScribeSession.Credential
        if let apiKey = ElevenLabsCredentials.userAPIKey() {
            credential = .apiKey(apiKey)
        } else if ElevenLabsCredentials.hasWorkerAccess {
            credential = .singleUseToken(try await fetchSingleUseToken())
        } else {
            throw SpeechToTextError(message: unavailableExplanation ?? "ElevenLabs is not set up.")
        }

        let session = ScribeSession(handlers: handlers)
        try await session.connect(
            request: try ScribeSession.websocketRequest(credential: credential, keyterms: keyterms),
            using: Self.websocketURLSession
        )
        return session
    }

    /// The developer Worker trades its own key for a single-use Scribe token,
    /// so the real key never reaches the Mac.
    private func fetchSingleUseToken() async throws -> String {
        guard let url = URL(string: "\(ElevenLabsCredentials.workerBaseURLString)/v1/stt/session-token") else {
            throw SpeechToTextError(message: "The Worker URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        BackendClient.applyAuthorization(to: &request)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw SpeechToTextError(message: "Couldn't get an ElevenLabs listening token (HTTP \(status)).")
        }
        struct TokenResponse: Decodable { let token: String }
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data).token, !token.isEmpty else {
            throw SpeechToTextError(message: "Invalid token response from the Worker.")
        }
        return token
    }
}

/// One push-to-talk utterance. All mutable state lives on `queue`, except
/// the resampler, which only the audio thread touches.
private nonisolated final class ScribeSession: LiveTranscriptionSession, @unchecked Sendable {
    enum Credential {
        /// Sent as the `xi-api-key` header, so it never appears in a URL.
        case apiKey(String)
        /// Consumed on first use; travels in the `token` query parameter.
        case singleUseToken(String)
    }

    private struct ServerMessage: Decodable {
        let message_type: String
        let text: String?
        let error: String?
    }

    private static let endpoint = "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
    private static let sampleRate = 16_000
    /// How long to wait for the committed transcript after release before
    /// settling for what has been heard so far.
    private static let commitGracePeriod: TimeInterval = 1.4
    /// A connection that hasn't said hello by now is treated as failed, so
    /// the press can fall back to an offline engine instead of hanging.
    private static let connectTimeout: TimeInterval = 8

    let finalTranscriptTimeout: TimeInterval = 2.8

    private let handlers: TranscriptionHandlers
    private let queue = DispatchQueue(label: "com.heymate.elevenlabs.scribe")
    private let resampler = PCM16Resampler(sampleRate: Double(sampleRate))

    private var socket: URLSessionWebSocketTask?
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var connectResult: Result<Void, Error>?
    private var isFinishing = false
    private var isClosed = false
    /// Segments the server has committed, oldest first. Push-to-talk commits
    /// once on release, but the server may also commit by itself during a
    /// long hold, so the transcript is every commit plus the live partial.
    private var committedSegments: [String] = []
    private var partial = ""

    init(handlers: TranscriptionHandlers) {
        self.handlers = handlers
    }

    static func websocketRequest(credential: Credential, keyterms: [String]) throws -> URLRequest {
        guard var components = URLComponents(string: endpoint) else {
            throw SpeechToTextError(message: "ElevenLabs websocket URL is invalid.")
        }
        var query = [
            URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
            URLQueryItem(name: "audio_format", value: "pcm_\(sampleRate)"),
            URLQueryItem(name: "commit_strategy", value: "manual")
        ]
        // One `keyterms` item per term, as the official SDK sends them,
        // capped so a long list can't push the URL past the server's limit.
        query += keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 50 }
            .prefix(50)
            .map { URLQueryItem(name: "keyterms", value: $0) }
        if case .singleUseToken(let token) = credential {
            query.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = query
        guard let url = components.url else {
            throw SpeechToTextError(message: "ElevenLabs websocket URL could not be created.")
        }

        var request = URLRequest(url: url)
        if case .apiKey(let apiKey) = credential {
            request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        }
        return request
    }

    func connect(request: URLRequest, using urlSession: URLSession) async throws {
        let socket = urlSession.webSocketTask(with: request)
        queue.sync { self.socket = socket }
        socket.resume()
        receive(from: socket)
        queue.asyncAfter(deadline: .now() + Self.connectTimeout) { [weak self] in
            self?.resolveConnect(.failure(SpeechToTextError(message: "ElevenLabs didn't answer in time.")))
        }

        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            queue.async {
                if let result = self.connectResult {
                    waiter.resume(with: result)
                } else {
                    self.connectWaiter = waiter
                }
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let pcm = resampler.convert(buffer), !pcm.isEmpty else { return }
        send(audio: pcm, commit: false)
    }

    func finish() {
        queue.async {
            guard !self.isClosed, !self.isFinishing else { return }
            self.isFinishing = true
            self.queue.asyncAfter(deadline: .now() + Self.commitGracePeriod) { [weak self] in
                guard let self else { return }
                self.deliverFinal(self.transcript)
            }
        }
        // An empty chunk with `commit` set closes the segment and makes the
        // server send the committed transcript.
        send(audio: Data(), commit: true)
    }

    func cancel() {
        queue.async {
            self.isClosed = true
            self.socket?.cancel(with: .goingAway, reason: nil)
        }
    }

    // MARK: - Wire

    private func send(audio: Data, commit: Bool) {
        // Built by hand rather than through JSONSerialization: this runs for
        // every microphone buffer, and base64 never needs escaping.
        let json = #"{"message_type":"input_audio_chunk","audio_base_64":""#
            + audio.base64EncodedString()
            + #"","commit":\#(commit),"sample_rate":\#(Self.sampleRate)}"#
        queue.async {
            guard !self.isClosed, let socket = self.socket else { return }
            socket.send(.string(json)) { [weak self] error in
                if let error { self?.fail(error) }
            }
        }
    }

    private func receive(from socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.handle(Data(text.utf8))
                self.receive(from: socket)
            case .success(.data(let data)):
                self.handle(data)
                self.receive(from: socket)
            case .success:
                self.receive(from: socket)
            case .failure(let error):
                self.fail(error)
            }
        }
    }

    private func handle(_ data: Data) {
        guard let message = try? JSONDecoder().decode(ServerMessage.self, from: data) else { return }
        switch message.message_type {
        case "session_started":
            resolveConnect(.success(()))
        case "partial_transcript":
            update(with: message.text ?? "", committed: false)
        case "committed_transcript", "committed_transcript_with_timestamps":
            update(with: message.text ?? "", committed: true)
        case "warning", "committed_transcript_entities", "edited_transcript":
            break
        default:
            // Every other type is one of Scribe's error shapes (auth_error,
            // quota_exceeded, rate_limited, input_error, ...).
            fail(SpeechToTextError(message: message.error ?? "ElevenLabs returned \(message.message_type)."))
        }
    }

    // MARK: - State (on `queue`)

    private var transcript: String {
        (committedSegments + (partial.isEmpty ? [] : [partial])).joined(separator: " ")
    }

    private func update(with rawText: String, committed: Bool) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.async {
            guard !self.isClosed else { return }
            if committed {
                if !text.isEmpty { self.committedSegments.append(text) }
                self.partial = ""
            } else {
                self.partial = text
            }
            let transcript = self.transcript
            if !transcript.isEmpty { self.handlers.onPartial(transcript) }
            if committed && self.isFinishing { self.deliverFinal(transcript) }
        }
    }

    private func deliverFinal(_ text: String) {
        guard !isClosed else { return }
        isClosed = true
        handlers.onFinal(text.trimmingCharacters(in: .whitespacesAndNewlines))
        socket?.cancel(with: .normalClosure, reason: nil)
    }

    private func fail(_ error: Error) {
        resolveConnect(.failure(error))
        queue.async {
            guard !self.isClosed else { return }
            let transcript = self.transcript
            if self.isFinishing && !transcript.isEmpty {
                HeyMateLog.log("[ElevenLabs Scribe] ⚠️ Error while finishing, keeping what was heard: \(error.localizedDescription)")
                self.deliverFinal(transcript)
                return
            }
            HeyMateLog.log("[ElevenLabs Scribe] ❌ Session failed: \(error.localizedDescription)")
            self.isClosed = true
            self.handlers.onError(error)
        }
    }

    private func resolveConnect(_ result: Result<Void, Error>) {
        queue.async {
            guard self.connectResult == nil else { return }
            self.connectResult = result
            self.connectWaiter?.resume(with: result)
            self.connectWaiter = nil
            if case .failure = result { self.socket?.cancel(with: .goingAway, reason: nil) }
        }
    }
}

/// Converts whatever the microphone delivers into mono PCM16 at one sample
/// rate. The converter and output buffer are reused across calls and only
/// rebuilt when the input format changes (a different microphone).
private nonisolated final class PCM16Resampler {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputBuffer: AVAudioPCMBuffer?

    init(sampleRate: Double) {
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        )!
    }

    func convert(_ input: AVAudioPCMBuffer) -> Data? {
        if inputFormat != input.format {
            inputFormat = input.format
            converter = AVAudioConverter(from: input.format, to: outputFormat)
        }
        guard let converter, input.frameLength > 0 else { return nil }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32
        if outputBuffer.map({ $0.frameCapacity < capacity }) ?? true {
            outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        }
        guard let output = outputBuffer else { return nil }
        output.frameLength = 0

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let samples = output.int16ChannelData?[0], output.frameLength > 0 else {
            return nil
        }
        return Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}
