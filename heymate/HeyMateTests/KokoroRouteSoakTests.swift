//
//  KokoroRouteSoakTests.swift
//  HeyMateTests
//
//  Synthesizes many sentences on one Core ML route to find a route Apple's
//  libBNNS does not crash. Opt-in, cached models only, no audio output.
//  A crash ends the test host, which is the failure signal.
//
//  TEST_RUNNER_HEYMATE_KOKORO_SOAK=default|aneTailGpu|aneTailCpu
//  TEST_RUNNER_HEYMATE_KOKORO_SOAK_ROUNDS=<sentences, default 300>
//

import Foundation
import FluidAudio
import Testing
@testable import HeyMate

struct KokoroRouteSoakTests {
    private static var route: String? {
        environment("HEYMATE_KOKORO_SOAK")
    }

    private static func environment(_ key: String) -> String? {
        let values = ProcessInfo.processInfo.environment
        return values[key] ?? values["TEST_RUNNER_" + key]
    }

    @Test(.enabled(if: KokoroRouteSoakTests.route != nil), .timeLimit(.minutes(60)))
    func routeSurvivesLongSynthesis() async throws {
        let units: KokoroAneComputeUnits = switch Self.route {
        case "aneTailGpu": .aneTailGpu
        case "aneTailCpu": .aneTailCpu
        default: .default
        }
        let rounds = Int(Self.environment("HEYMATE_KOKORO_SOAK_ROUNDS") ?? "") ?? 300
        let manager = KokoroAneManager(defaultVoice: KokoroEngine.defaultVoice, computeUnits: units)
        try await manager.initialize()

        let sentences = [
            "Hi.",
            "Open Settings, then click Privacy and Security.",
            "Here are three shortcuts: Command Space opens Spotlight, Command Tab switches apps, and Command Q quits.",
            "That error means the build cache is stale, so clean the build folder and try again.",
            "Sure.",
            "The file you want is in your Downloads folder, about halfway down the list, called report final two.",
        ]
        // How many callers synthesize at once: the app's warm-up, an
        // interrupted reply and the next one can overlap like this.
        let parallel = Int(Self.environment("HEYMATE_KOKORO_SOAK_PARALLEL") ?? "") ?? 1
        let startedAt = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for lane in 0..<parallel {
                group.addTask {
                    for index in stride(from: lane, to: rounds, by: parallel) {
                        let result = try await manager.synthesizeDetailed(
                            text: sentences[index % sentences.count], voice: KokoroEngine.defaultVoice, speed: 1)
                        #expect(!result.samples.isEmpty)
                        if index % 50 == 49 {
                            print("Kokoro soak \(Self.route ?? "default") x\(parallel): \(index + 1)/\(rounds), \(startedAt.duration(to: .now))")
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        print("Kokoro soak \(Self.route ?? "default") x\(parallel) survived: \(rounds) sentences in \(startedAt.duration(to: .now))")
    }

    /// The production path: many callers at once through KokoroEngine, which
    /// must run them one at a time.
    @Test(.enabled(if: KokoroRouteSoakTests.environment("HEYMATE_KOKORO_ENGINE_SOAK") == "1"), .timeLimit(.minutes(60)))
    func engineSerializesOverlappingCallers() async throws {
        try await KokoroEngine.shared.prepare()
        let rounds = Int(Self.environment("HEYMATE_KOKORO_SOAK_ROUNDS") ?? "") ?? 300
        let startedAt = ContinuousClock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for lane in 0..<4 {
                group.addTask {
                    for index in stride(from: lane, to: rounds, by: 4) {
                        let audio = try await KokoroEngine.shared.synthesize("Sentence \(index), open Settings and click Privacy.")
                        #expect(!audio.samples.isEmpty)
                    }
                }
            }
            try await group.waitForAll()
        }
        print("Kokoro engine soak x4 survived: \(rounds) sentences in \(startedAt.duration(to: .now))")
    }
}
