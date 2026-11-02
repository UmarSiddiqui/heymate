import Foundation
import Testing
@testable import HeyMate

@MainActor struct PhononSpeechTests {
    @Test func pcmUsesSignedLittleEndianSamples() {
        #expect(PhononEngine.decodePCM([0, 128, 255, 127, 0, 64]) == [-1, Float(32767) / 32768, 0.5])
    }

    @Test func streamingTrimPreservesAnInteriorPauseAcrossChunks() {
        var trim = PhononSilenceTrimmer()
        #expect(trim.append([Float](repeating: 0, count: 10_000)).isEmpty)
        var output = trim.append([0.5] + [Float](repeating: 0, count: 6_000))
        output += trim.append([0.5] + [Float](repeating: 0, count: 6_000))
        output += trim.finish()
        #expect(output.count == 720 + 1 + 6_000 + 1 + 4_080)
    }

    @Test func longUnpunctuatedInputKeepsEveryWordWithinSegmentLimit() {
        let text = String(repeating: "word ", count: 2_000)
        let parts = PhononTTSClient.segments(text)
        #expect(parts.allSatisfy { !$0.isEmpty && $0.count <= 1_000 })
        #expect(parts.joined(separator: " ").split(separator: " ").count == 2_000)
        #expect(PhononTTSClient.segments("Hi there. Ready?") == ["Hi there.", "Ready?"])
        #expect(PhononTTSClient.segments("   ").isEmpty)
    }
}
