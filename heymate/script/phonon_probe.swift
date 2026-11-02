import AVFoundation
import Darwin
import Foundation

func probeOutput(_ text: String) {
    try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
}

enum HeyMateLog {
    static func log(_ text: String) { probeOutput(text) }
    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: .now).components
        return Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
    }
}

actor AudioMeasure {
    let start = ContinuousClock.now
    var first: Int?
    var samples = 0
    var loud = false
    func append(_ chunk: [Float]) {
        precondition(!chunk.isEmpty && chunk.allSatisfy { $0.isFinite && abs($0) <= 1 })
        if first == nil { first = HeyMateLog.milliseconds(since: start) }
        samples += chunk.count
        loud = loud || chunk.contains { abs($0) > 0.01 }
    }
    func result() -> (Int, Int, Int) {
        precondition(loud && samples > 0, "Empty/silent synthesis")
        return (first!, HeyMateLog.milliseconds(since: start), samples)
    }
}

@main struct PhononProbe {
    @MainActor static func main() async throws {
        try pureChecks()
        guard ProcessInfo.processInfo.environment["PROBE_PURE_ONLY"] != "1" else { return }
        let environment = ProcessInfo.processInfo.environment
        let speechEngine: PhononEngine
        if let bundlePath = environment["PROBE_APP_BUNDLE"] {
            let bundle = URL(fileURLWithPath: bundlePath)
            speechEngine = PhononEngine(resources: bundle.appendingPathComponent("Contents/Resources/PhononRuntime"),
                                        helperExecutable: bundle.appendingPathComponent("Contents/Helpers/HeyMateSpeechRunner"))
        } else {
            guard PhononEngine.modelsAreInstalled() else { fatalError("Install canonical signed app first") }
            speechEngine = .shared
        }
        if environment["PROBE_LONG_ONLY"] == "1" {
            let text = String(repeating: "The river flows beside the bridge ", count: 30)
            let measurement = AudioMeasure()
            try await speechEngine.stream(text, voice: "Zoey") { await measurement.append($0) }
            let (_, _, samples) = await measurement.result()
            precondition(samples > 24_000 * 20)
            probeOutput("PASS long segment: \(text.count) characters, \(samples / 24_000) seconds of valid audio")
            let speaker = PhononTTSClient(speechEngine: speechEngine)
            try await speaker.speakText(String(repeating: text, count: 6))
            precondition(speaker.isPlaying)
            try await Task.sleep(for: .milliseconds(80))
            speaker.stopPlayback()
            try await Task.sleep(for: .milliseconds(250))
            precondition(!speaker.isPlaying, "Long reply resumed after stop")
            let recovery = AudioMeasure()
            try await speechEngine.stream("Recovered after the long interrupted reply.", voice: "Zoey") { await recovery.append($0) }
            _ = await recovery.result()
            await speechEngine.removeFromDisk()
            probeOutput("PASS \(text.count * 6)-character production reply interrupted; no stale playback; synthesis recovers")
            return
        }
        let rounds = Int(environment["PROBE_ROUNDS"] ?? "1_000".replacingOccurrences(of: "_", with: ""))!
        var corpus = ["Open Settings and select Privacy.", "The meeting starts at three thirty tomorrow.",
                      "I can see the blue button near the bottom of your screen."]
        if let path = environment["PROBE_CORPUS"] {
            corpus = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                .flatMap { PhononTTSClient.segments(SpeechText.sanitize($0)) }
        }
        guard !corpus.isEmpty, rounds > 0 else { fatalError("Empty corpus") }
        let begin = ContinuousClock.now
        var measurements = [[String: Int]]()
        for index in 0..<rounds {
            let measurement = AudioMeasure()
            try await speechEngine.stream(corpus[index % corpus.count], voice: "Zoey") {
                await measurement.append($0)
            }
            let (first, full, samples) = await measurement.result()
            measurements.append(["first_ms": first, "full_ms": full, "samples": samples])
            if index % 100 == 99 { probeOutput("PASS production replay \(index + 1)/\(rounds)") }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for voice in OnDeviceVoiceOption.all {
                group.addTask {
                    for _ in 0..<4 {
                        let measurement = AudioMeasure()
                        try await speechEngine.stream("This is the overlapping caller check.", voice: voice.id) {
                            await measurement.append($0)
                        }
                        _ = await measurement.result()
                    }
                }
            }
            try await group.waitForAll()
        }
        probeOutput("PASS 40 overlapping calls, all 10 curated voices")
        for index in 0..<40 {
            let cancelled = Task {
                try await speechEngine.stream(String(repeating: "Long interrupted speech. ", count: 50), voice: "Zoey") { _ in }
            }
            if index % 2 == 0 { try await Task.sleep(for: .milliseconds(5)) }
            cancelled.cancel()
            do { try await cancelled.value; fatalError("Cancellation did not interrupt") }
            catch is CancellationError { }
            let measurement = AudioMeasure()
            try await speechEngine.stream("Recovered after interruption.", voice: "Zoey") { await measurement.append($0) }
            _ = await measurement.result()
        }
        probeOutput("PASS 40 cancellations and 40 immediate recovery calls")
        if environment["PROBE_PLAYBACK"] == "1" {
            let speaker = PhononTTSClient(speechEngine: speechEngine)
            var durations = [Int]()
            for speed in [0.75, 1.0, 1.5] {
                SpeechStylePreferences.speed = speed
                let startedAt = ContinuousClock.now
                try await speaker.speakText("Phonon playback check. The river runs beside the old stone bridge.")
                precondition(speaker.isPlaying)
                let deadline = ContinuousClock.now.advanced(by: .seconds(20))
                while speaker.isPlaying, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
                precondition(!speaker.isPlaying, "Playback did not finish")
                durations.append(HeyMateLog.milliseconds(since: startedAt))
            }
            precondition(durations[0] > durations[1] && durations[1] > durations[2], "Speed did not change playback duration")
            probeOutput("PASS identical-text playback durations at 0.75/1/1.5: \(durations)ms")
            for _ in 0..<20 {
                let started = Task { try await speaker.speakText("This reply should stop immediately when interrupted.") }
                try await Task.sleep(for: .milliseconds(10))
                speaker.stopPlayback()
                _ = try? await started.value
                try await Task.sleep(for: .milliseconds(30))
                precondition(!speaker.isPlaying, "Stop left stale playback")
            }
            try await speaker.speakText("Final recovery playback.")
            precondition(speaker.isPlaying)
            speaker.stopPlayback()
            precondition(!speaker.isPlaying)
            probeOutput("PASS real audio playback at 3 speeds, 20 rapid stops, final recovery")
        }
        if let path = environment["PROBE_METRICS"] {
            try JSONSerialization.data(withJSONObject: measurements, options: [.sortedKeys, .prettyPrinted])
                .write(to: URL(fileURLWithPath: path))
        }
        await speechEngine.removeFromDisk()
        probeOutput("PASS production Phonon: \(rounds) replay + 40 overlap + 40 recovery; \(HeyMateLog.milliseconds(since: begin))ms")
    }

    @MainActor static func pureChecks() throws {
        let raw: [UInt8] = [0, 0, 0, 128, 255, 127, 0, 64]
        let decoded = PhononEngine.decodePCM(raw)
        precondition(decoded == [0, -1, Float(32767) / 32768, 0.5], "PCM endianness/scaling")
        var trim = PhononSilenceTrimmer()
        precondition(trim.append([Float](repeating: 0, count: 10_000)).isEmpty)
        var output = trim.append([0.5, 0.5] + [Float](repeating: 0, count: 6_000))
        output += trim.append([0.5] + [Float](repeating: 0, count: 6_000))
        output += trim.finish()
        precondition(output.count == 720 + 2 + 6_000 + 1 + 4_080, "Interior pause lost or edge padding wrong")
        var silent = PhononSilenceTrimmer()
        precondition(silent.append([Float](repeating: 0, count: 10_000)).isEmpty && silent.finish().isEmpty)
        let long = String(repeating: "word ", count: 2_000)
        let segments = PhononTTSClient.segments(long)
        precondition(segments.allSatisfy { !$0.isEmpty && $0.count <= 3500 })
        precondition(segments.joined(separator: " ").split(separator: " ").count == 2_000, "Chunking lost words")
        precondition(PhononTTSClient.segments("Hi there. Ready?") == ["Hi there.", "Ready?"])
        SpeechStylePreferences.onDeviceVoice = "af_heart"
        precondition(SpeechStylePreferences.onDeviceVoice == "Zoey", "Legacy voice did not migrate")
        SpeechStylePreferences.onDeviceVoice = "Freya"
        precondition(SpeechStylePreferences.onDeviceVoice == "Freya")
        SpeechStylePreferences.onDeviceVoice = "Zoey"
        probeOutput("PASS PCM, streaming silence, sentence boundaries, long input, voice migration")
    }
}
