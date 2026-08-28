//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
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
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    static func makeProvider(preferred: VoiceListenProvider) -> any BuddyTranscriptionProvider {
        switch preferred {
        case .apple:
            return AppleSpeechTranscriptionProvider()
        case .assemblyAI:
            let assemblyAIProvider = AssemblyAIStreamingTranscriptionProvider()
            if assemblyAIProvider.isConfigured {
                return assemblyAIProvider
            }
            print("⚠️ Transcription: AssemblyAI preferred but not configured, falling back")
            return fallbackProvider(excluding: .assemblyAI)
        case .openAI:
            let openAIProvider = OpenAIAudioTranscriptionProvider()
            if openAIProvider.isConfigured {
                return openAIProvider
            }
            print("⚠️ Transcription: OpenAI preferred but not configured, falling back")
            return fallbackProvider(excluding: .openAI)
        }
    }

    private static func fallbackProvider(
        excluding unavailable: VoiceListenProvider
    ) -> any BuddyTranscriptionProvider {
        let remaining: [VoiceListenProvider] = VoiceListenProvider.allCases.filter { $0 != unavailable }
        for candidate in remaining {
            let provider = makeProviderWithoutFallback(candidate)
            if provider.isConfigured {
                print("⚠️ Transcription: using \(provider.displayName) as fallback")
                return provider
            }
        }
        return AppleSpeechTranscriptionProvider()
    }

    private static func makeProviderWithoutFallback(
        _ preferred: VoiceListenProvider
    ) -> any BuddyTranscriptionProvider {
        switch preferred {
        case .apple:
            return AppleSpeechTranscriptionProvider()
        case .assemblyAI:
            return AssemblyAIStreamingTranscriptionProvider()
        case .openAI:
            return OpenAIAudioTranscriptionProvider()
        }
    }
}
