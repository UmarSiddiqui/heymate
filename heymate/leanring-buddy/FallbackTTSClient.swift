//
//  FallbackTTSClient.swift
//  leanring-buddy
//
//  Speaks with the chosen voice and, if that throws (offline, bad
//  ElevenLabs key, on-device model deleted), says the same text with the
//  Mac voice instead. A reply the user waited for should never go
//  silent because the nicer voice was unavailable.
//

import Foundation

@MainActor
final class FallbackTTSClient: TTSClient {
    private let primaryClient: any TTSClient
    private let fallbackClient: any TTSClient
    private var isUsingFallback = false

    init(primary primaryClient: any TTSClient, fallback fallbackClient: any TTSClient) {
        self.primaryClient = primaryClient
        self.fallbackClient = fallbackClient
    }

    func speakText(_ text: String) async throws {
        isUsingFallback = false
        do {
            try await primaryClient.speakText(text)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            HeyMateLog.log("⚠️ Speak: primary voice failed (\(error.localizedDescription)), using the Mac voice")
            isUsingFallback = true
            try await fallbackClient.speakText(text)
        }
    }

    var isPlaying: Bool {
        isUsingFallback ? fallbackClient.isPlaying : primaryClient.isPlaying
    }

    func stopPlayback() {
        primaryClient.stopPlayback()
        fallbackClient.stopPlayback()
    }
}
