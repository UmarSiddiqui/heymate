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

    init() {
        audioEngine.attach(playerNode)
    }

    func speakText(_ text: String) async throws {
        stopPlayback()

        let sentences = Self.splitIntoSentences(text)
        guard !sentences.isEmpty else { return }

        playbackGeneration += 1
        let generation = playbackGeneration

        // The first sentence is synthesized before returning so a failure
        // (model missing, synthesis error) surfaces to the caller, which
        // falls back to the Mac voice.
        let firstSentenceAudio = try await KokoroEngine.shared.synthesize(sentences[0])
        try Task.checkCancellation()
        guard generation == playbackGeneration else { return }

        try schedule(firstSentenceAudio, generation: generation)

        let remainingSentences = Array(sentences.dropFirst())
        guard !remainingSentences.isEmpty else { return }

        isSynthesizing = true
        synthesisTask = Task { [weak self] in
            for sentence in remainingSentences {
                guard !Task.isCancelled else { break }
                guard let audio = try? await KokoroEngine.shared.synthesize(sentence) else { continue }
                guard let self, generation == self.playbackGeneration else { return }
                try? self.schedule(audio, generation: generation)
            }
            if let self, generation == self.playbackGeneration {
                self.isSynthesizing = false
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

        scheduledBufferCount += 1
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.playbackGeneration else { return }
                self.scheduledBufferCount = max(0, self.scheduledBufferCount - 1)
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
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
