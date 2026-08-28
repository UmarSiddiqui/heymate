//
//  MacOSSpeechSynthesizerClient.swift
//  leanring-buddy
//
//  Local text-to-speech backed by the macOS system synthesizer
//  (AVSpeechSynthesizer). Needs zero API keys, so spoken replies work even
//  when the Cloudflare Worker / ElevenLabs account is unavailable. Mirrors
//  the ElevenLabsTTSClient contract: speakText returns once playback has
//  started, isPlaying tracks active speech, stopPlayback interrupts at once.
//

import AVFoundation
import Foundation

@MainActor
final class MacOSSpeechSynthesizerClient: NSObject, TTSClient {

    /// Underlying system synthesizer. Kept alive for the client's lifetime
    /// because AVSpeechSynthesizer drops in-flight speech when deallocated.
    private let synthesizer = AVSpeechSynthesizer()

    /// Resumed exactly once per speakText call — when the utterance starts
    /// playing (the TTSClient "return once playback started" contract) or
    /// when speech is stopped/cancelled before that, so callers never hang.
    private var playbackStartedContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speakText(_ text: String) async throws {
        // A fresh request interrupts any utterance still queued or speaking,
        // matching how push-to-talk re-presses cut off the previous reply.
        stopPlayback()

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let utterance = AVSpeechUtterance(string: text)
        // Voice picked in Settings; nil resolution keeps the previous
        // behavior of speaking in the system language's default voice.
        utterance.voice = SpeechVoiceCatalog.resolvedSystemVoice()
            ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        try Task.checkCancellation()
        await withCheckedContinuation { continuation in
            playbackStartedContinuation = continuation
            synthesizer.speak(utterance)
        }
    }

    var isPlaying: Bool {
        synthesizer.isSpeaking
    }

    func stopPlayback() {
        resumePlaybackStartedContinuationIfNeeded()
        synthesizer.stopSpeaking(at: .immediate)
    }

    @MainActor
    private func resumePlaybackStartedContinuationIfNeeded() {
        guard let continuation = playbackStartedContinuation else { return }
        playbackStartedContinuation = nil
        continuation.resume()
    }
}

extension MacOSSpeechSynthesizerClient: AVSpeechSynthesizerDelegate {

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.resumePlaybackStartedContinuationIfNeeded() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.resumePlaybackStartedContinuationIfNeeded() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.resumePlaybackStartedContinuationIfNeeded() }
    }
}
