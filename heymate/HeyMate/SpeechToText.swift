//
//  SpeechToText.swift
//  HeyMate
//
//  The seam between voice capture and the engines that turn speech into
//  text. `VoiceDictation` owns the microphone and talks only to these two
//  protocols, so ElevenLabs, the on-device model and Apple Speech are
//  interchangeable and a failing engine can be swapped mid-press.
//

import AVFoundation
import Foundation

/// What a live session reports back. Handlers may be called from any thread;
/// the receiver hops to its own actor.
nonisolated struct TranscriptionHandlers {
    /// The best transcript so far, in full (not a delta).
    let onPartial: (String) -> Void
    /// The finished transcript. Called at most once per session.
    let onFinal: (String) -> Void
    let onError: (Error) -> Void
}

nonisolated protocol LiveTranscriptionSession: AnyObject {
    /// How long to wait for `onFinal` after `finish()` before giving up and
    /// using the latest partial instead.
    var finalTranscriptTimeout: TimeInterval { get }
    /// Called on the audio thread, in capture order.
    func append(_ buffer: AVAudioPCMBuffer)
    /// No more audio is coming; produce the final transcript.
    func finish()
    func cancel()
}

protocol SpeechToTextProvider {
    var displayName: String { get }
    var needsSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    /// Why the provider cannot run right now, phrased for Settings.
    var unavailableExplanation: String? { get }

    /// Opens a session that is ready to take audio. Throws if the engine
    /// cannot start, so the caller can fall back before the user speaks.
    func openSession(
        keyterms: [String],
        handlers: TranscriptionHandlers
    ) async throws -> any LiveTranscriptionSession
}

nonisolated struct SpeechToTextError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum SpeechToTextProviders {
    static func preferred() -> any SpeechToTextProvider {
        let provider = resolve(VoiceListenProvider.fromUserDefaults())
        HeyMateLog.log("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    /// The chosen provider when it is set up, otherwise the best offline one.
    static func resolve(_ choice: VoiceListenProvider) -> any SpeechToTextProvider {
        let provider = make(choice)
        guard !provider.isConfigured else { return provider }
        HeyMateLog.log("⚠️ Transcription: \(provider.displayName) preferred but not set up, falling back")
        return offlineFallback()
    }

    /// The downloaded on-device model if there is one, else Apple Speech,
    /// which every Mac has.
    static func offlineFallback() -> any SpeechToTextProvider {
        let onDevice = ParakeetTranscriptionProvider()
        return onDevice.isConfigured ? onDevice : AppleSpeechTranscriptionProvider()
    }

    /// A different engine to try when `provider` failed to start, or nil
    /// when there is nothing left to fall back to.
    static func fallback(after provider: any SpeechToTextProvider) -> (any SpeechToTextProvider)? {
        let candidates: [any SpeechToTextProvider] = [offlineFallback(), AppleSpeechTranscriptionProvider()]
        return candidates.first { $0.displayName != provider.displayName }
    }

    private static func make(_ choice: VoiceListenProvider) -> any SpeechToTextProvider {
        switch choice {
        case .elevenLabs: return ElevenLabsScribeTranscriptionProvider()
        case .onDevice: return ParakeetTranscriptionProvider()
        case .apple: return AppleSpeechTranscriptionProvider()
        }
    }
}
