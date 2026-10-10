//
//  BuddyTranscriptionProvider.swift
//  HeyMate
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {
    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = makeProvider(preferred: VoiceListenProvider.fromUserDefaults())
        HeyMateLog.log("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    /// The preferred provider when it can run, else the best one that can.
    static func makeProvider(preferred: VoiceListenProvider) -> any BuddyTranscriptionProvider {
        let preferredProvider = makeProviderWithoutFallback(preferred)
        if preferredProvider.isConfigured {
            return preferredProvider
        }
        HeyMateLog.log("⚠️ Transcription: \(preferredProvider.displayName) preferred but not set up, falling back")
        return offlineFallbackProvider()
    }

    /// What to use when the chosen provider is unavailable or fails to
    /// start: the downloaded on-device model if there is one, otherwise
    /// Apple Speech, which every Mac has.
    static func offlineFallbackProvider() -> any BuddyTranscriptionProvider {
        let onDeviceProvider = ParakeetTranscriptionProvider()
        if onDeviceProvider.isConfigured {
            return onDeviceProvider
        }
        return AppleSpeechTranscriptionProvider()
    }

    private static func makeProviderWithoutFallback(
        _ preferred: VoiceListenProvider
    ) -> any BuddyTranscriptionProvider {
        switch preferred {
        case .elevenLabs:
            return ElevenLabsScribeTranscriptionProvider()
        case .onDevice:
            return ParakeetTranscriptionProvider()
        case .apple:
            return AppleSpeechTranscriptionProvider()
        }
    }
}
