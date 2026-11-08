import AVFoundation
import Foundation

@MainActor
final class PhononTTSClient: TTSClient {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var generation = 0
    private var task: Task<Void, Never>?
    private var synthesizing = false
    private var buffers = 0
    private var trimmer = PhononSilenceTrimmer()
    private var firstPlayback: (generation: Int, continuation: CheckedContinuation<Void, Error>)?
    private let speechEngine: PhononEngine

    init(speechEngine: PhononEngine = .shared) {
        self.speechEngine = speechEngine
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    }

    var isPlaying: Bool { synthesizing || buffers > 0 }

    func speakText(_ text: String) async throws {
        stopPlayback()
        try Task.checkCancellation()
        let sentences = Self.segments(SpeechText.sanitize(text))
        guard !sentences.isEmpty else { return }
        let current = generation
        let voice = SpeechStylePreferences.onDeviceVoice
        timePitch.rate = Float(SpeechStylePreferences.speed)
        synthesizing = true
        let began = ContinuousClock.now
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                firstPlayback = (current, continuation)
                task = Task { [weak self] in
                    guard let self else { return }
                    var sentenceIndex = 0
                    do {
                        for (index, sentence) in sentences.enumerated() {
                            sentenceIndex = index
                            try Task.checkCancellation()
                            guard current == self.generation else { throw CancellationError() }
                            self.trimmer = PhononSilenceTrimmer()
                            try await self.speechEngine.stream(sentence, voice: voice) { [weak self] samples in
                                try await self?.consume(samples, generation: current, began: began)
                            }
                            guard current == self.generation else { throw CancellationError() }
                            try self.schedule(self.trimmer.finish(), generation: current, began: began)
                        }
                        guard current == self.generation else { return }
                        if self.firstPlayback != nil { throw PhononEngine.Failure.invalidAudio }
                        self.synthesizing = false
                        HeyMateLog.log("Phonon: synthesized \(sentences.count) segments, voice \(voice), speed \(self.timePitch.rate), \(HeyMateLog.milliseconds(since: began))ms")
                    } catch {
                        guard current == self.generation else { return }
                        if Task.isCancelled || error is CancellationError {
                            self.finishFirst(throwing: CancellationError())
                            self.synthesizing = false
                            return
                        }
                        do {
                            // Finish queued audio, then repeat the failed segment and
                            // continue. Never drop the rest of a partially spoken reply.
                            while self.buffers > 0 {
                                try await Task.sleep(for: .milliseconds(20))
                                guard current == self.generation else { throw CancellationError() }
                            }
                            try Task.checkCancellation()
                            // HeyMate never speaks in the Mac system voice. The words
                            // are already on screen; the rest of this reply stays quiet.
                            HeyMateLog.log("Phonon unavailable; staying quiet (no Mac voice): \(error.localizedDescription)")
                            guard current == self.generation else { return }
                            self.finishFirst()
                        } catch {
                            if current == self.generation { self.finishFirst(throwing: error) }
                        }
                        if current == self.generation { self.synthesizing = false }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.generation == current { self?.stopPlayback() }
            }
        }
    }

    func stopPlayback() {
        generation += 1
        task?.cancel()
        task = nil
        synthesizing = false
        buffers = 0
        player.stop()
        finishFirst(throwing: CancellationError())
    }

    private func finishFirst(throwing error: Error? = nil) {
        let pending = firstPlayback
        firstPlayback = nil
        if let error { pending?.continuation.resume(throwing: error) }
        else { pending?.continuation.resume() }
    }

    private func consume(_ samples: [Float], generation current: Int, began: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard current == generation else { throw CancellationError() }
        try schedule(trimmer.append(samples), generation: current, began: began)
    }

    private func schedule(_ samples: [Float], generation current: Int, began: ContinuousClock.Instant) throws {
        guard current == generation else { throw CancellationError() }
        guard !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { throw PhononEngine.Failure.invalidAudio }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        buffers += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, current == self.generation else { return }
                self.buffers = max(0, self.buffers - 1)
            }
        }
        if !player.isPlaying { player.play() }
        if firstPlayback?.generation == current {
            HeyMateLog.log("Phonon: first playback scheduled after \(HeyMateLog.milliseconds(since: began))ms")
            finishFirst()
        }
    }

    /// Bound even unpunctuated replies below the API's 4096-character limit.
    static func segments(_ text: String) -> [String] {
        var sentences = [String]()
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { part, _, _, _ in
            if let part, !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sentences.append(part.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if sentences.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sentences = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        return sentences.flatMap { sentence -> [String] in
            var remaining = sentence[...]
            var result = [String]()
            while remaining.count > 1_000 {
                let limit = remaining.index(remaining.startIndex, offsetBy: 1_000)
                let split = remaining[..<limit].lastIndex(where: { $0.isWhitespace }) ?? limit
                let end = split == remaining.startIndex ? limit : split
                result.append(String(remaining[..<end]))
                remaining = remaining[end...].drop(while: { $0.isWhitespace })
            }
            if !remaining.isEmpty { result.append(String(remaining)) }
            return result
        }
    }
}
