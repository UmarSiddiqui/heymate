//
//  SilentModeTests.swift
//  leanring-buddyTests
//
//  Silent mode must keep every spoken line quiet while it is on, pass speech
//  through untouched while it is off, and be reachable by a typed command.
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct SilentModeTests {

    private final class RecordingTTSClient: TTSClient {
        var spokenTexts: [String] = []
        var stopPlaybackCallCount = 0
        var isPlaying: Bool { false }

        func speakText(_ text: String) async throws {
            spokenTexts.append(text)
        }

        func stopPlayback() {
            stopPlaybackCallCount += 1
        }
    }

    @Test func speechIsSwallowedWhileSilentModeIsOn() async throws {
        let recordingClient = RecordingTTSClient()
        let silentClient = SilentModeAwareTTSClient(wrapping: recordingClient, isSilentModeEnabled: { true })

        try await silentClient.speakText("hello")

        #expect(recordingClient.spokenTexts.isEmpty)
    }

    @Test func speechPassesThroughWhileSilentModeIsOff() async throws {
        let recordingClient = RecordingTTSClient()
        let silentClient = SilentModeAwareTTSClient(wrapping: recordingClient, isSilentModeEnabled: { false })

        try await silentClient.speakText("hello")

        #expect(recordingClient.spokenTexts == ["hello"])
    }

    @Test func togglingTakesEffectWithoutRebuildingTheClient() async throws {
        let recordingClient = RecordingTTSClient()
        var isSilent = false
        let silentClient = SilentModeAwareTTSClient(wrapping: recordingClient, isSilentModeEnabled: { isSilent })

        try await silentClient.speakText("first")
        isSilent = true
        try await silentClient.speakText("second")

        #expect(recordingClient.spokenTexts == ["first"])
    }

    @Test func stopPlaybackAlwaysReachesTheWrappedClient() {
        let recordingClient = RecordingTTSClient()
        let silentClient = SilentModeAwareTTSClient(wrapping: recordingClient, isSilentModeEnabled: { true })

        silentClient.stopPlayback()

        #expect(recordingClient.stopPlaybackCallCount == 1)
    }

    @Test func preferenceDefaultsToOffAndPersists() {
        UserDefaults.standard.removeObject(forKey: SilentModePreferences.userDefaultsKey)
        #expect(SilentModePreferences.isEnabled == false)

        SilentModePreferences.isEnabled = true
        #expect(UserDefaults.standard.bool(forKey: SilentModePreferences.userDefaultsKey) == true)

        UserDefaults.standard.removeObject(forKey: SilentModePreferences.userDefaultsKey)
    }

    @Test func slashSilentAndQuietResolveToTheToggle() {
        #expect(CommandBarParser.parse("/silent") == .slashCommand(.silent, argument: ""))
        #expect(CommandBarParser.parse("/quiet") == .slashCommand(.silent, argument: ""))
    }
}
