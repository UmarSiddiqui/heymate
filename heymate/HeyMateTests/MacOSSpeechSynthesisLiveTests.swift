import Foundation
import Testing
@testable import HeyMate

/// Opt-in system TTS playback. No microphone, transcription, permissions,
/// credentials or external service are involved. This verifies native playback
/// state/callbacks, not whether a human heard the physical output device.
@MainActor
struct MacOSSpeechSynthesisLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEYMATE_MACOS_TTS_LIVE"] == "1"
                   || ProcessInfo.processInfo.environment["TEST_RUNNER_HEYMATE_MACOS_TTS_LIVE"] == "1"))
    func systemSpeechStartsAndCanBeStopped() async throws {
        let speaker = MacOSSpeechSynthesizerClient()
        var returned = false
        var speechError: Error?
        let startedAt = ContinuousClock.now
        let speech = Task {
            do {
                try await speaker.speakText("HeyMate voice check")
                returned = true
            } catch { speechError = error }
        }
        defer { speech.cancel(); speaker.stopPlayback() }

        let deadline = startedAt.advanced(by: .seconds(12))
        while !returned, speechError == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // Capture evidence before Stop, which itself releases any pending
        // start continuation. Cleanup cannot manufacture successful start.
        let returnedBeforeStop = returned
        let playingBeforeStop = speaker.isPlaying
        let elapsed = startedAt.duration(to: .now)
        speaker.stopPlayback()
        let stopDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while speaker.isPlaying, ContinuousClock.now < stopDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        speech.cancel()
        speaker.stopPlayback()
        await speech.value
        #expect(speechError == nil)
        #expect(returnedBeforeStop, "System speech did not report playback start within 12 seconds.")
        #expect(playingBeforeStop, "Speech returned without active playback before Stop.")
        #expect(!speaker.isPlaying, "System speech remained active after bounded Stop cleanup.")
        print("Native TTS callback evidence: returnedBeforeStop=\(returnedBeforeStop), isPlayingBeforeStop=\(playingBeforeStop), stopped=\(!speaker.isPlaying), elapsed=\(elapsed)")
    }
}
