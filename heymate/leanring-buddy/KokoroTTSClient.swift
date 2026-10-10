//
//  KokoroTTSClient.swift
//  leanring-buddy
//
//  On-device text-to-speech with Kokoro 82M. Replies are split into
//  sentences and synthesized one at a time into a player-node queue, so the
//  first sentence starts playing while later ones are still being made.
//  Mirrors the other TTSClients: speakText returns once playback has
//  started, isPlaying covers queued audio, stopPlayback cuts off at once.
//

import AVFoundation
import Foundation

@MainActor
final class KokoroTTSClient: TTSClient {
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var connectedFormat: AVAudioFormat?

    /// Bumped on every new request and on stop, so a synthesis task that
    /// finishes late never schedules audio for a reply that was cut off.
    private var playbackGeneration = 0
    private var synthesisTask: Task<Void, Never>?
    private var scheduledBufferCount = 0
    private var isSynthesizing = false

    /// When the queue last ran dry while sentences were still being made.
    /// The next schedule logs that silence as an audible gap.
    private var queueDrainedAt: ContinuousClock.Instant?
    private var requestStartedAt: ContinuousClock.Instant?

    init() {
        audioEngine.attach(playerNode)
    }

    func speakText(_ text: String) async throws {
        stopPlayback()

        let sentences = Self.splitIntoSentences(text)
        guard !sentences.isEmpty else { return }

        playbackGeneration += 1
        let generation = playbackGeneration
        requestStartedAt = .now
        queueDrainedAt = nil
        HeyMateLog.log("🔊 Kokoro: reply of \(sentences.count) sentence(s), \(text.count) chars")

        // The first sentence is synthesized before returning so a failure
        // (model missing, synthesis error) surfaces to the caller, which
        // falls back to the Mac voice.
        let firstSentenceAudio = try await Self.synthesizeLogged(sentences[0], index: 0)
        try Task.checkCancellation()
        guard generation == playbackGeneration else { return }

        try schedule(firstSentenceAudio, generation: generation)
        if let requestStartedAt {
            HeyMateLog.log("🔊 Kokoro: first audio after \(HeyMateLog.milliseconds(since: requestStartedAt))ms")
        }

        let remainingSentences = Array(sentences.dropFirst())
        guard !remainingSentences.isEmpty else { return }

        isSynthesizing = true
        synthesisTask = Task { [weak self] in
            for (offset, sentence) in remainingSentences.enumerated() {
                guard !Task.isCancelled else { break }
                guard let audio = try? await Self.synthesizeLogged(sentence, index: offset + 1) else { continue }
                guard let self, generation == self.playbackGeneration else { return }
                try? self.schedule(audio, generation: generation)
            }
            if let self, generation == self.playbackGeneration {
                self.isSynthesizing = false
                if let requestStartedAt = self.requestStartedAt {
                    HeyMateLog.log("🔊 Kokoro: all sentences synthesized after \(HeyMateLog.milliseconds(since: requestStartedAt))ms")
                }
            }
        }
    }

    var isPlaying: Bool {
        isSynthesizing || scheduledBufferCount > 0
    }

    func stopPlayback() {
        playbackGeneration += 1
        synthesisTask?.cancel()
        synthesisTask = nil
        isSynthesizing = false
        scheduledBufferCount = 0
        playerNode.stop()
    }

    private func schedule(_ audio: (samples: [Float], sampleRate: Int), generation: Int) throws {
        guard !audio.samples.isEmpty,
              let format = AVAudioFormat(
                  standardFormatWithSampleRate: Double(audio.sampleRate),
                  channels: 1
              ),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(audio.samples.count)
              ),
              let channelData = buffer.floatChannelData else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(audio.samples.count)
        audio.samples.withUnsafeBufferPointer { samplePointer in
            channelData[0].update(from: samplePointer.baseAddress!, count: audio.samples.count)
        }

        if connectedFormat != format {
            audioEngine.disconnectNodeOutput(playerNode)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
            connectedFormat = format
        }
        if !audioEngine.isRunning {
            audioEngine.prepare()
            try audioEngine.start()
        }

        if let queueDrainedAt {
            HeyMateLog.log("⚠️ Kokoro: playback gap \(HeyMateLog.milliseconds(since: queueDrainedAt))ms waiting on synthesis")
            self.queueDrainedAt = nil
        }

        scheduledBufferCount += 1
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.playbackGeneration else { return }
                self.scheduledBufferCount = max(0, self.scheduledBufferCount - 1)
                if self.scheduledBufferCount == 0, self.isSynthesizing {
                    self.queueDrainedAt = .now
                }
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }

    /// Synthesizes one sentence and logs how long it took against how long
    /// it plays. Synthesis slower than the previous sentence's playback is
    /// what makes the voice stutter between sentences.
    private static func synthesizeLogged(_ sentence: String, index: Int) async throws -> (samples: [Float], sampleRate: Int) {
        let startedAt = ContinuousClock.now
        let audio = try await KokoroEngine.shared.synthesize(sentence)
        let audioMilliseconds = audio.sampleRate > 0 ? audio.samples.count * 1000 / audio.sampleRate : 0
        let (leadingSilence, trailingSilence) = edgeSilenceMilliseconds(audio)
        let trimmedAudio = trimmingEdgeSilence(audio)
        let trimmedMilliseconds = audio.sampleRate > 0 ? trimmedAudio.samples.count * 1000 / audio.sampleRate : 0
        HeyMateLog.log(
            "🔊 Kokoro: sentence \(index) (\(sentence.count) chars) synth \(HeyMateLog.milliseconds(since: startedAt))ms, "
                + "audio \(audioMilliseconds)ms, edge silence \(leadingSilence)/\(trailingSilence)ms, plays \(trimmedMilliseconds)ms"
        )
        return trimmedAudio
    }

    /// Kokoro pads every clip with ~350 ms of silence in front and ~500 ms
    /// behind. Played back to back, sentences end up nearly a second apart,
    /// which is what made replies sound choppy. Keeping a short lead-in and
    /// a sentence-sized tail leaves a natural ~200 ms pause between them.
    static func trimmingEdgeSilence(
        _ audio: (samples: [Float], sampleRate: Int),
        keepLeadingMilliseconds: Int = 30,
        keepTrailingMilliseconds: Int = 170,
        threshold: Float = 0.01
    ) -> (samples: [Float], sampleRate: Int) {
        guard audio.sampleRate > 0,
              let firstLoud = audio.samples.firstIndex(where: { abs($0) > threshold }),
              let lastLoud = audio.samples.lastIndex(where: { abs($0) > threshold }) else {
            return audio
        }
        let start = max(0, firstLoud - keepLeadingMilliseconds * audio.sampleRate / 1000)
        let end = min(audio.samples.count, lastLoud + 1 + keepTrailingMilliseconds * audio.sampleRate / 1000)
        return (Array(audio.samples[start..<end]), audio.sampleRate)
    }

    /// Near-silent audio at the start and end of a clip, in milliseconds.
    static func edgeSilenceMilliseconds(_ audio: (samples: [Float], sampleRate: Int), threshold: Float = 0.01) -> (leading: Int, trailing: Int) {
        guard audio.sampleRate > 0, !audio.samples.isEmpty else { return (0, 0) }
        let firstLoud = audio.samples.firstIndex { abs($0) > threshold } ?? audio.samples.count
        let lastLoud = audio.samples.lastIndex { abs($0) > threshold } ?? -1
        let trailingCount = audio.samples.count - 1 - lastLoud
        return (firstLoud * 1000 / audio.sampleRate, max(0, trailingCount) * 1000 / audio.sampleRate)
    }

    /// Sentence-sized chunks keep the first audio fast and stay well under
    /// Kokoro's 510-phoneme limit per pass.
    static func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { substring, _, _, _ in
            guard let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !sentence.isEmpty else { return }
            sentences.append(sentence)
        }
        if sentences.isEmpty {
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty { sentences.append(trimmedText) }
        }
        return sentences
    }
}
