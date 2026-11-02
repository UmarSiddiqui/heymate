import Foundation
import FluidAudio
import AVFoundation

// The standalone probe uses production engines without launching another app
// or writing to the app's preferences/logs.
func probeLog(_ text: String) {
    try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
}

enum HeyMateLog {
    static func log(_ text: String) { probeLog(text) }
    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: .now).components
        return Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
    }
}

@main struct Probe {
    @MainActor static func main() async throws {
        if let directory = ProcessInfo.processInfo.environment["PROBE_TRANSCRIBE_DIRECTORY"] {
            let root = URL(fileURLWithPath: directory)
            let candidates: [URL]
            if ProcessInfo.processInfo.environment["PROBE_TRANSCRIBE_RECURSIVE"] == "1" {
                candidates = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
            } else {
                candidates = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            }
            let files = candidates.filter { $0.pathExtension == "wav" }.sorted { $0.path < $1.path }
            guard !files.isEmpty, ParakeetEngine.modelsAreInstalled() else { fatalError("WAV samples or cached Parakeet model missing") }
            var results: [[String: Any]] = []
            for url in files {
                let file = try AVAudioFile(forReading: url)
                guard file.processingFormat.channelCount == 1,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                    fatalError("Expected mono audio")
                }
                try file.read(into: buffer)
                guard let channel = buffer.floatChannelData?[0] else { fatalError("Expected PCM samples") }
                let ratio = file.processingFormat.sampleRate / 16_000
                let count = Int(Double(buffer.frameLength) / ratio)
                let samples = (0..<count).map { index -> Float in
                    let position = Double(index) * ratio
                    let lower = min(Int(position), Int(buffer.frameLength) - 1)
                    let upper = min(lower + 1, Int(buffer.frameLength) - 1)
                    let fraction = Float(position - Double(lower))
                    return channel[lower] * (1 - fraction) + channel[upper] * fraction
                }
                let text = try await ParakeetEngine.shared.transcribe(samples)
                let name = String(url.path.dropFirst(root.path.count + 1))
                results.append(["file": name, "text": text])
                probeLog("Transcribed \(name)")
            }
            let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: root.appendingPathComponent("transcriptions.json"))
            probeLog("PASS cached Parakeet roundtrip: \(results.count) audio samples")
            return
        }
        let rounds = Int(ProcessInfo.processInfo.environment["PROBE_ROUNDS"] ?? "400")!
        guard rounds > 0 else { fatalError("PROBE_ROUNDS must be positive") }
        var corpus: [String] = []
        if let path = ProcessInfo.processInfo.environment["PROBE_CORPUS"] {
            for reply in try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: path))) {
                let text = SpeechText.sanitize(reply.replacingOccurrences(of: #"\[[A-Z]+:[^\]]*\]"#, with: "", options: .regularExpression))
                text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sentence, _, _, _ in
                    if let sentence, !sentence.isEmpty { corpus.append(sentence) }
                }
            }
        }
        if ProcessInfo.processInfo.environment["PROBE_RUNTIME"] == "v3" {
            let manager = KokoroAneManager(version: .v3)
            try await manager.initialize()
            let start = ContinuousClock.now
            for index in 0..<rounds {
                let text = corpus.isEmpty ? "Sentence \(index). Open Settings and click Privacy." : corpus[index % corpus.count]
                probeLog("v3 synthesis \(index + 1)/\(rounds), \(text.count) chars")
                let result = try await manager.synthesizeDetailed(text: text, voice: "af_heart")
                guard !result.samples.isEmpty, result.samples.allSatisfy({ $0.isFinite }), result.sampleRate == 24000 else {
                    fatalError("Invalid candidate audio")
                }
            }
            probeLog("PASS v3: \(rounds) sentences, \(start.duration(to: .now))")
            return
        }
        let chain = KokoroEngine.cacheRootURL.appendingPathComponent("kokoro-82m-coreml/ANE")
        for name in ModelNames.KokoroAne.requiredModels {
            guard FileManager.default.fileExists(atPath: chain.appendingPathComponent(name).path) else {
                fatalError("Missing cached Kokoro model: \(name). Download using HeyMate first.")
            }
        }
        for name in ModelNames.KokoroAne.requiredCoreMLModels {
            let mil = try Data(contentsOf: chain.appendingPathComponent(name).appendingPathComponent("model.mil"))
            guard mil.range(of: Data("[FlexibleShapeInformation =".utf8)) != nil else {
                fatalError("Legacy Kokoro cache requires migration in HeyMate first.")
            }
        }
        let frontend = KokoroEngine.cacheRootURL.appendingPathComponent("kokoro")
        for name in ModelNames.G2P.requiredModels.union(["us_lexicon_cache.json"]) {
            guard FileManager.default.fileExists(atPath: frontend.appendingPathComponent(name).path) else {
                fatalError("Missing cached speech frontend: \(name)")
            }
        }
        guard SpeechText.sanitize("**Hello**.\n* Open Settings\n* Click Privacy") == "Hello. Open Settings. Click Privacy." else {
            fatalError("Speech cleanup failed")
        }
        let start = ContinuousClock.now
        try await KokoroEngine.shared.prepare()
        if ProcessInfo.processInfo.environment["PROBE_PLAYBACK"] == "1" {
            let speaker = KokoroTTSClient()
            probeLog("PLAYBACK_BEGIN")
            try await speaker.speakText("This is the local voice recovery check, which verifies that speech continues with the system voice when the inference helper stops unexpectedly.")
            guard speaker.isPlaying else { fatalError("No speech playback started") }
            probeLog("PASS production playback started; parent survived")
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while speaker.isPlaying, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
            speaker.stopPlayback()
            guard !speaker.isPlaying else { fatalError("Stop failed") }
            probeLog("PASS production playback finished and stopped")
            return
        }
        if ProcessInfo.processInfo.environment["PROBE_REPLAY"] == "1" {
            guard !corpus.isEmpty else { fatalError("PROBE_REPLAY requires PROBE_CORPUS") }
            var measurements: [[String: Any]] = []
            for index in 0..<rounds {
                let text = corpus[index % corpus.count]
                probeLog("Replay synthesis \(index): \(text.count) chars")
                do {
                    let begin = ContinuousClock.now
                    let audio = try await KokoroEngine.shared.synthesize(text)
                    let elapsed = begin.duration(to: .now).components
                    let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                    measurements.append(["index": index, "characters": text.count,
                                         "synth_seconds": seconds, "audio_seconds": Double(audio.samples.count) / Double(audio.sampleRate)])
                    if let path = ProcessInfo.processInfo.environment["PROBE_METRICS"] {
                        try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
                            .write(to: URL(fileURLWithPath: path))
                    }
                }
                catch {
                    if let path = ProcessInfo.processInfo.environment["PROBE_FAILED_SENTENCE"] {
                        try text.write(toFile: path, atomically: true, encoding: .utf8)
                    }
                    probeLog("CONTAINED: \(error.localizedDescription); parent survived")
                    return
                }
            }
            probeLog("PASS replay: \(rounds) sentences")
            return
        }
        let replayCorpus = corpus
        try await withThrowingTaskGroup(of: Void.self) { group in
            for lane in 0..<4 {
                group.addTask {
                    for index in stride(from: lane, to: rounds, by: 4) {
                        let text = replayCorpus.isEmpty
                            ? SpeechText.sanitize("**Sentence \(index)**. Open Settings and click Privacy.")
                            : replayCorpus[index % replayCorpus.count]
                        if !replayCorpus.isEmpty { probeLog("Production synthesis \(index + 1)/\(rounds), \(text.count) chars") }
                        let audio = try await KokoroEngine.shared.synthesize(text)
                        guard !audio.samples.isEmpty, audio.sampleRate == 24000 else { fatalError("Invalid audio") }
                        if index % 50 == 49 { probeLog("PASS synthesis \(index + 1)/\(rounds)") }
                    }
                }
            }
            try await group.waitForAll()
        }
        // A cancelled caller must release the gate so later speech still runs.
        let cancelled = Task { try await KokoroEngine.shared.synthesize("Cancelled reply.") }
        cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("Cancelled speech unexpectedly completed") }
        catch is CancellationError { }
        let final = try await KokoroEngine.shared.synthesize("Voice check complete.")
        guard !final.samples.isEmpty else { fatalError("Queue failed after cancellation") }
        probeLog("PASS: \(rounds) sentences, four overlapping callers, \(start.duration(to: .now))")
    }
}
