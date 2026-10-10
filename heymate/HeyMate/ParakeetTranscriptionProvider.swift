//
//  ParakeetTranscriptionProvider.swift
//  HeyMate
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

struct ParakeetTranscriptionProvider: SpeechToTextProvider {
    let displayName = "On-device"
    let needsSpeechRecognitionPermission = false

    var isConfigured: Bool { ParakeetEngine.modelsAreInstalled() }

    var unavailableExplanation: String? {
        if let reason = ParakeetEngine.unsupportedReason { return reason }
        return isConfigured ? nil : "Download the on-device voice in Settings to use it."
    }

    func openSession(
        keyterms: [String],
        handlers: TranscriptionHandlers
    ) async throws -> any LiveTranscriptionSession {
        // The first load after launch takes a moment. Doing it here makes a
        // missing model fail the start, where the press can still fall back,
        // rather than after the user has finished talking.
        _ = try await ParakeetEngine.shared.loadIfNeeded()
        return ParakeetSession(handlers: handlers)
    }
}

private nonisolated final class ParakeetSession: LiveTranscriptionSession, @unchecked Sendable {
    private static let partialInterval: TimeInterval = 0.9
    /// Parakeet needs about a second of 16 kHz audio before it says anything.
    private static let minimumSamplesForPartial = 16_000

    let finalTranscriptTimeout: TimeInterval = 6.0

    private let handlers: TranscriptionHandlers
    private let resampler = AudioConverter()
    private let queue = DispatchQueue(label: "com.heymate.parakeet")

    // Owned by `queue`.
    private var samples: [Float] = []
    private var isDecodingPartial = false
    private var lastPartialStart = Date.distantPast
    private var isFinishing = false
    private var isCancelled = false

    init(handlers: TranscriptionHandlers) {
        self.handlers = handlers
        samples.reserveCapacity(16_000 * 20)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        // Resampling is stateless, so it runs right here on the audio thread.
        guard let resampled = try? resampler.resampleBuffer(buffer), !resampled.isEmpty else { return }
        queue.async {
            guard !self.isFinishing, !self.isCancelled else { return }
            self.samples.append(contentsOf: resampled)
            self.decodePartialIfDue()
        }
    }

    func finish() {
        queue.async {
            guard !self.isFinishing, !self.isCancelled else { return }
            self.isFinishing = true
            let utterance = self.samples
            guard !utterance.isEmpty else {
                self.handlers.onFinal("")
                return
            }
            Task {
                do {
                    let text = try await ParakeetEngine.shared.transcribe(utterance)
                    self.queue.async { if !self.isCancelled { self.handlers.onFinal(text) } }
                } catch {
                    self.queue.async { if !self.isCancelled { self.handlers.onError(error) } }
                }
            }
        }
    }

    func cancel() {
        queue.async {
            self.isCancelled = true
            self.samples.removeAll()
        }
    }

    /// One partial decode at a time. The final decode doesn't wait for it:
    /// the engine actor serializes them anyway.
    private func decodePartialIfDue() {
        guard !isDecodingPartial,
              samples.count >= Self.minimumSamplesForPartial,
              Date().timeIntervalSince(lastPartialStart) >= Self.partialInterval else { return }

        isDecodingPartial = true
        lastPartialStart = Date()
        let snapshot = samples
        Task {
            let text = try? await ParakeetEngine.shared.transcribe(snapshot)
            self.queue.async {
                self.isDecodingPartial = false
                guard !self.isFinishing, !self.isCancelled, let text, !text.isEmpty else { return }
                self.handlers.onPartial(text)
            }
        }
    }
}
