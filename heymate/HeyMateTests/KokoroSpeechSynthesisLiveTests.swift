import Foundation
import FluidAudio
import Testing
@testable import HeyMate

/// Actual production on-device synthesis/playback, using existing assets only.
/// No microphone or speech-recognition authorization; physical audibility is
/// not asserted. Cache checks deliberately precede any initializing API.
@MainActor
struct KokoroSpeechSynthesisLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TEST_RUNNER_HEYMATE_KOKORO_TTS_LIVE"] == "1"
                   || ProcessInfo.processInfo.environment["HEYMATE_KOKORO_TTS_LIVE"] == "1"))
    func cachedProductionSpeechStartsAndStops() async throws {
        try #require(KokoroEngine.unsupportedReason == nil)
        let root = KokoroEngine.cacheRootURL
        let chain = root.appendingPathComponent("kokoro-82m-coreml/ANE")
        let frontend = root.appendingPathComponent("kokoro")
        for name in ModelNames.KokoroAne.requiredModels {
            try #require(FileManager.default.fileExists(atPath: chain.appendingPathComponent(name).path), "Missing cached asset: \(name); never download in this test.")
        }
        for name in ModelNames.KokoroAne.requiredCoreMLModels {
            let mil = try Data(contentsOf: chain.appendingPathComponent(name).appendingPathComponent("model.mil"))
            try #require(mil.range(of: Data("[FlexibleShapeInformation =".utf8)) != nil,
                         "Legacy cache would trigger a download migration: \(name)")
        }
        for name in ModelNames.G2P.requiredModels.union(["us_lexicon_cache.json"]) {
            try #require(FileManager.default.fileExists(atPath: frontend.appendingPathComponent(name).path), "Missing cached frontend: \(name)")
        }
        let bundleFiles = ["coremldata.bin", "model.mil", "metadata.json", "weights/weight.bin", "analytics/coremldata.bin"]
        for name in [ModelNames.G2P.encoderFile, ModelNames.G2P.decoderFile] {
            for file in bundleFiles {
                try #require(FileManager.default.fileExists(atPath: frontend.appendingPathComponent(name).appendingPathComponent(file).path))
            }
        }
        let defaults = UserDefaults.standard
        let keys = [KokoroEngine.installedMarkerKey, SpeechStylePreferences.onDeviceVoiceKey, SpeechStylePreferences.speedKey]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        // Only the isolated hosted test application's preferences change.
        defaults.set(true, forKey: KokoroEngine.installedMarkerKey)
        SpeechStylePreferences.onDeviceVoice = "af_heart"
        SpeechStylePreferences.speed = 1
        let speaker = KokoroTTSClient()
        var returned = false
        var speechError: Error?
        let startedAt = ContinuousClock.now
        let speech = Task {
            do { try await speaker.speakText("HeyMate voice check."); returned = true }
            catch { speechError = error }
        }
        defer { speech.cancel(); speaker.stopPlayback() }
        let deadline = startedAt.advanced(by: .seconds(45))
        while !returned, speechError == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let playingBeforeStop = speaker.isPlaying
        let elapsed = startedAt.duration(to: .now)
        speaker.stopPlayback()
        #expect(speechError == nil, "Kokoro failed: \(String(describing: speechError))")
        #expect(returned, "Cached Kokoro synthesis exceeded 45 seconds.")
        #expect(playingBeforeStop)
        #expect(!speaker.isPlaying)
        print("Production Kokoro TTS evidence: returned=\(returned), isPlayingBeforeStop=\(playingBeforeStop), stopped=\(!speaker.isPlaying), elapsed=\(elapsed)")
        print("Cached Parakeet readiness: \(ParakeetEngine.modelsAreInstalled())")
        if ProcessInfo.processInfo.environment["TEST_RUNNER_HEYMATE_LOCAL_VOICE_ROUNDTRIP_LIVE"] == "1"
            || ProcessInfo.processInfo.environment["HEYMATE_LOCAL_VOICE_ROUNDTRIP_LIVE"] == "1" {
            try #require(ParakeetEngine.modelsAreInstalled(), "Local STT assets absent; never download in this test.")
            var transcript: String?
            var roundtripError: Error?
            let roundtripStarted = ContinuousClock.now
            let roundtrip = Task {
                do {
                    let audio = try await KokoroEngine.shared.synthesize("The quick brown fox jumps over the lazy dog.")
                    guard audio.sampleRate > 0, !audio.samples.isEmpty else {
                        throw OnDeviceVoiceError.modelNotDownloaded
                    }
                    // Offline sample-rate conversion only; no audio input or
                    // output device participates in this synthetic roundtrip.
                    let ratio = Double(audio.sampleRate) / 16_000
                    let count = Int(Double(audio.samples.count) / ratio)
                    let samples = (0..<count).map { index -> Float in
                        let position = Double(index) * ratio
                        let lower = min(Int(position), audio.samples.count - 1)
                        let upper = min(lower + 1, audio.samples.count - 1)
                        let fraction = Float(position - Double(lower))
                        return audio.samples[lower] * (1 - fraction) + audio.samples[upper] * fraction
                    }
                    transcript = try await ParakeetEngine.shared.transcribe(samples)
                } catch { roundtripError = error }
            }
            defer { roundtrip.cancel() }
            let roundtripDeadline = roundtripStarted.advanced(by: .seconds(60))
            while transcript == nil, roundtripError == nil, ContinuousClock.now < roundtripDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(roundtripError == nil, "Synthetic local roundtrip failed: \(String(describing: roundtripError))")
            let text = try #require(transcript, "Synthetic local roundtrip exceeded 60 seconds.")
            #expect(text.lowercased().contains("fox"))
            #expect(text.lowercased().contains("dog"))
            print("Synthetic cached Kokoro→Parakeet evidence: transcript=\(text), elapsed=\(roundtripStarted.duration(to: .now))")
        }
    }
}
