//
//  VoiceProviderTests.swift
//  HeyMateTests
//
//  Models settings persist Listen (STT) and Speak (TTS) independently of
//  the brain. Stored preference wins; the Info.plist value is only the
//  factory default when nothing has been chosen yet.
//

import Foundation
import Testing
@testable import HeyMate

struct VoiceProviderTests {

    @Test func listenStoredPreferenceWinsOverBundleDefault() {
        let resolved = VoiceListenProvider.resolved(
            storedRawValue: "parakeet",
            bundleRawValue: "apple"
        )
        #expect(resolved == .onDevice)
    }

    @Test func listenFallsBackToBundleWhenNothingIsStored() {
        let resolved = VoiceListenProvider.resolved(
            storedRawValue: nil,
            bundleRawValue: "elevenlabs"
        )
        #expect(resolved == .elevenLabs)
    }

    @Test func retiredCloudListenChoicesMoveToElevenLabs() {
        #expect(VoiceListenProvider.resolved(storedRawValue: "assemblyai", bundleRawValue: "apple") == .elevenLabs)
        #expect(VoiceListenProvider.resolved(storedRawValue: "openai", bundleRawValue: "apple") == .elevenLabs)
        #expect(VoiceListenProvider.resolved(storedRawValue: "AssemblyAI", bundleRawValue: nil) == .elevenLabs)
    }

    @Test func retiredMacPreferencesMigrateToLocal() {
        #expect(VoiceListenProvider.resolved(storedRawValue: "apple", bundleRawValue: "elevenlabs") == .onDevice)
        #expect(VoiceSpeakProvider.resolved(storedRawValue: "macos", bundleRawValue: "elevenlabs") == .onDevice)
    }

    @Test func speakOnDeviceRoundTrips() {
        #expect(VoiceSpeakProvider.resolved(storedRawValue: "kokoro", bundleRawValue: "macos") == .onDevice)
    }

    @Test func listenInvalidStoredValueFallsBackToLocal() {
        #expect(
            VoiceListenProvider.resolved(
                storedRawValue: "not-a-provider",
                bundleRawValue: "apple"
            ) == .onDevice
        )
        #expect(
            VoiceListenProvider.resolved(
                storedRawValue: "not-a-provider",
                bundleRawValue: nil
            ) == .onDevice
        )
    }

    @Test func speakStoredPreferenceWinsOverLocalDefault() {
        #expect(
            VoiceSpeakProvider.resolved(
                storedRawValue: "elevenlabs",
                bundleRawValue: "macos"
            ) == .elevenLabs
        )
        #expect(
            VoiceSpeakProvider.resolved(
                storedRawValue: nil,
                bundleRawValue: nil
            ) == .onDevice
        )
        #expect(
            VoiceSpeakProvider.resolved(
                storedRawValue: "nope",
                bundleRawValue: nil
            ) == .onDevice
        )
    }

    @Test func speakFallsBackToBundleWhenNothingIsStored() {
        #expect(
            VoiceSpeakProvider.resolved(
                storedRawValue: nil,
                bundleRawValue: "elevenlabs"
            ) == .elevenLabs
        )
        #expect(
            VoiceSpeakProvider.resolved(
                storedRawValue: nil,
                bundleRawValue: "macos"
            ) == .onDevice
        )
    }

    @Test func speakInvalidStoredValueFallsBackToLocal() {
        #expect(
            VoiceSpeakProvider.resolved(
                storedRawValue: "not-a-provider",
                bundleRawValue: "elevenlabs"
            ) == .elevenLabs
        )
        #expect(
            VoiceSpeakProvider.resolved(
                storedRawValue: "not-a-provider",
                bundleRawValue: nil
            ) == .onDevice
        )
    }

    @Test func listenFactoryHonorsPreferredProvider() {
        let apple = SpeechToTextProviders.resolve(.apple)
        #expect(apple.displayName == "On-device")
    }

    @Test func listenFactoryFallsBackWhenOnDeviceIsMissing() {
        // Missing local models must never silently select Apple Speech.
        let provider = SpeechToTextProviders.resolve(.onDevice)
        #expect(provider.displayName == "On-device")
        #expect(SpeechToTextProviders.fallback(after: provider) == nil)
    }
}

@MainActor
struct VoiceProviderPersistenceTests {

    @Test func retiredMacSpeakingChoiceUsesKokoro() {
        #expect(CompanionManager.makeSpeakingClient(for: .macOS, workerBaseURL: "http://localhost") is KokoroTTSClient)
        #expect(CompanionManager.makeSpeakingClient(for: .onDevice, workerBaseURL: "http://localhost") is KokoroTTSClient)
    }

    @Test func kokoroStaysOffWhereAppleBNNSCrashesIt() {
        func reason(_ major: Int, _ minor: Int) -> String? {
            KokoroEngine.unsupportedReason(for: OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0))
        }
        #expect(reason(26, 3) == nil)
        #expect(reason(26, 4) != nil)
        #expect(reason(26, 5) != nil)
        #expect(reason(26, 6) == nil)
        #expect(reason(27, 0) == nil)
        #expect(reason(27, 1) == nil)
    }

    @Test func companionDefaultsSpeakToLocalWhenNothingStored() {
        UserDefaults.standard.removeObject(forKey: CompanionManager.speakPreferenceKey)
        let manager = CompanionManager()
        #expect(manager.selectedSpeakProvider == .onDevice)
        UserDefaults.standard.removeObject(forKey: CompanionManager.speakPreferenceKey)
    }

    @Test func companionPersistsListenAndSpeakChoices() {
        UserDefaults.standard.removeObject(forKey: CompanionManager.listenPreferenceKey)
        UserDefaults.standard.removeObject(forKey: CompanionManager.speakPreferenceKey)
        let manager = CompanionManager()

        manager.setSelectedListenProvider(.apple)
        manager.setSelectedSpeakProvider(.elevenLabs)

        #expect(UserDefaults.standard.string(forKey: CompanionManager.listenPreferenceKey) == "parakeet")
        #expect(UserDefaults.standard.string(forKey: CompanionManager.speakPreferenceKey) == "elevenlabs")
        #expect(manager.selectedListenProvider == .onDevice)
        #expect(manager.selectedSpeakProvider == .elevenLabs)
        #expect(manager.voiceDictation.transcriptionProviderDisplayName == "On-device")

        UserDefaults.standard.removeObject(forKey: CompanionManager.listenPreferenceKey)
        UserDefaults.standard.removeObject(forKey: CompanionManager.speakPreferenceKey)
    }
}
