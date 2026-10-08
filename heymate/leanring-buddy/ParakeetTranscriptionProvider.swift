//
//  ParakeetTranscriptionProvider.swift
//  leanring-buddy
//
//  On-device transcription with Parakeet. Push-to-talk utterances are short,
//  so instead of a sliding window this keeps the whole utterance and re-runs
//  the model on it about once a second for live partials, then once more on
//  release for the final text. At ~120× real time a 15-second utterance
//  decodes in well under 200 ms.
//

import AVFoundation
import FluidAudio
import Foundation

final class ParakeetTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "On-device"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool { ParakeetEngine.modelsAreInstalled() }

    var unavailableExplanation: String? {
        if let reason = ParakeetEngine.unsupportedReason { return reason }
        guard !isConfigured else { return nil }
        return "Download the on-device voice in Settings to use it."
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        // Loading takes a moment the first time after launch; doing it here
        // means a missing model fails the start (and falls back) instead of
        // failing after the user has finished talking.
        _ = try await ParakeetEngine.shared.loadIfNeeded()

        return ParakeetTranscriptionSession(
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class ParakeetTranscriptionSession: BuddyStreamingTranscriptionSession {
    private static let partialTranscriptIntervalSeconds: TimeInterval = 0.9
    /// Parakeet needs about a second of audio before a decode says anything.
    private static let minimumSamplesForPartial = 16_000

    let finalTranscriptFallbackDelaySeconds: TimeInterval = 6.0

    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let audioConverter = AudioConverter()
    private let stateQueue = DispatchQueue(label: "com.heymate.parakeet.state")

    private var bufferedSamples: [Float] = []
    private var isDecodingPartial = false
    private var lastPartialStartedAt = Date.distantPast
    private var hasRequestedFinalTranscript = false
    private var isCancelled = false

    init(
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        // Resampling is stateless, so it is safe on the audio thread.
        guard let samples = try? audioConverter.resampleBuffer(audioBuffer), !samples.isEmpty else { return }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedSamples.append(contentsOf: samples)
            self.startPartialDecodeIfDue()
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true
            let utteranceSamples = self.bufferedSamples

            guard !utteranceSamples.isEmpty else {
                self.onFinalTranscriptReady("")
                return
            }

            Task {
                do {
                    let finalText = try await ParakeetEngine.shared.transcribe(utteranceSamples)
                    self.stateQueue.async {
                        guard !self.isCancelled else { return }
                        self.onFinalTranscriptReady(finalText)
                    }
                } catch {
                    self.stateQueue.async {
                        guard !self.isCancelled else { return }
                        self.onError(error)
                    }
                }
            }
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.bufferedSamples.removeAll()
        }
    }

    /// Runs on `stateQueue`. One partial decode at a time; the final decode
    /// does not wait for it because the actor serializes them anyway.
    private func startPartialDecodeIfDue() {
        guard !isDecodingPartial,
              bufferedSamples.count >= Self.minimumSamplesForPartial,
              Date().timeIntervalSince(lastPartialStartedAt) >= Self.partialTranscriptIntervalSeconds else {
            return
        }

        isDecodingPartial = true
        lastPartialStartedAt = Date()
        let snapshotSamples = bufferedSamples

        Task {
            let partialText = try? await ParakeetEngine.shared.transcribe(snapshotSamples)
            self.stateQueue.async {
                self.isDecodingPartial = false
                guard !self.hasRequestedFinalTranscript, !self.isCancelled,
                      let partialText, !partialText.isEmpty else { return }
                self.onTranscriptUpdate(partialText)
            }
        }
    }
}
