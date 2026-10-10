//
//  ElevenLabsVoiceClient.swift
//  HeyMate
//
//  Speaks replies with an ElevenLabs voice. With the user's own key it
//  calls ElevenLabs directly; otherwise a developer build goes through the
//  HeyMate Worker, which holds the key. The whole clip is fetched, then
//  played, so `speakText` returns once the voice has started.
//

import AVFoundation
import Foundation

nonisolated enum ElevenLabsVoiceError: LocalizedError, CustomNSError {
    case invalidResponse
    case http(status: Int, body: String)

    static var errorDomain: String { "ElevenLabsVoice" }

    var errorCode: Int {
        if case .http(let status, _) = self { return status }
        return -1
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response"
        case .http(let status, let body): return "TTS API error (\(status)): \(body)"
        }
    }
}

final class ElevenLabsVoiceClient: TTSClient {
    private struct SpeechRequest: Encodable {
        struct VoiceSettings: Encodable {
            let stability = 0.5
            let similarityBoost = 0.75

            enum CodingKeys: String, CodingKey {
                case stability
                case similarityBoost = "similarity_boost"
            }
        }

        let text: String
        let modelID = "eleven_flash_v2_5"
        let voiceSettings = VoiceSettings()
        /// Worker route only. The Worker validates it and uses it as the
        /// upstream voice; left out, the Worker uses its configured voice.
        let voiceID: String?

        enum CodingKeys: String, CodingKey {
            case text
            case modelID = "model_id"
            case voiceSettings = "voice_settings"
            case voiceID = "voice_id"
        }
    }

    private let workerURL: URL?
    /// Held so playback continues after `speakText` returns.
    private var player: AVAudioPlayer?

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    init(workerURL: String) {
        self.workerURL = URL(string: workerURL)
    }

    var isPlaying: Bool {
        player?.isPlaying ?? false
    }

    func speakText(_ text: String) async throws {
        let request = try makeRequest(for: text)
        let (audio, response) = try await Self.session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw ElevenLabsVoiceError.invalidResponse
        }
        guard (200...299).contains(status) else {
            throw ElevenLabsVoiceError.http(status: status, body: String(decoding: audio, as: UTF8.self))
        }
        try Task.checkCancellation()

        let player = try AVAudioPlayer(data: audio)
        self.player = player
        player.play()
        HeyMateLog.log("🔊 ElevenLabs TTS: playing \(audio.count / 1024)KB audio")
    }

    func stopPlayback() {
        player?.stop()
        player = nil
    }

    private func makeRequest(for text: String) throws -> URLRequest {
        let userKey = ElevenLabsCredentials.userAPIKey()
        let selectedVoice = SpeechVoiceCatalog.resolvedElevenLabsVoiceID()

        let url: URL
        if userKey != nil {
            guard let base = URL(string: ElevenLabsCredentials.apiBaseURLString) else {
                throw ElevenLabsVoiceError.invalidResponse
            }
            url = base
                .appendingPathComponent("v1/text-to-speech")
                .appendingPathComponent(selectedVoice ?? SpeechVoiceCatalog.defaultElevenLabsVoiceID)
        } else {
            guard let workerURL else { throw ElevenLabsVoiceError.invalidResponse }
            url = workerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        if let userKey {
            request.setValue(userKey, forHTTPHeaderField: "xi-api-key")
        } else {
            BackendClient.applyAuthorization(to: &request)
        }
        request.httpBody = try JSONEncoder().encode(
            SpeechRequest(text: text, voiceID: userKey == nil ? selectedVoice : nil)
        )
        return request
    }
}
