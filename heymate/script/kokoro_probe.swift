import Foundation
import FluidAudio

// The standalone probe uses production engines without launching another app
// or writing to the app's preferences/logs.
enum HeyMateLog { static func log(_ text: String) { print(text) } }

@main struct Probe {
    static func main() async throws {
        let rounds = Int(ProcessInfo.processInfo.environment["PROBE_ROUNDS"] ?? "400")!
        guard rounds > 0 else { fatalError("PROBE_ROUNDS must be positive") }
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
        try await withThrowingTaskGroup(of: Void.self) { group in
            for lane in 0..<4 {
                group.addTask {
                    for index in stride(from: lane, to: rounds, by: 4) {
                        let text = SpeechText.sanitize("**Sentence \(index)**. Open Settings and click Privacy.")
                        let audio = try await KokoroEngine.shared.synthesize(text)
                        guard !audio.samples.isEmpty, audio.sampleRate == 24000 else { fatalError("Invalid audio") }
                        if index % 50 == 49 { print("PASS synthesis \(index + 1)/\(rounds)") }
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
        print("PASS: \(rounds) sentences, four overlapping callers, \(start.duration(to: .now))")
    }
}
