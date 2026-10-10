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

    @Test func speakOnDeviceRoundTrips() {
        #expect(VoiceSpeakProvider.resolved(storedRawValue: "kokoro", bundleRawValue: "macos") == .onDevice)
    }

    @Test func listenInvalidStoredValueFallsBackToBundleThenApple() {
        #expect(
            VoiceListenProvider.resolved(
                storedRawValue: "not-a-provider",
                bundleRawValue: "apple"
            ) == .apple
        )
        #expect(
            VoiceListenProvider.resolved(
                storedRawValue: "not-a-provider",
                bundleRawValue: nil
            ) == .apple
        )
    }

    @Test func speakStoredPreferenceWinsOverDefaultMac() {
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
            ) == .macOS
        )
        #expect(
            VoiceSpeakProvider.resolved(
                storedRawValue: "nope",
                bundleRawValue: nil
            ) == .macOS
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
            ) == .macOS
        )
    }

    @Test func speakInvalidStoredValueFallsBackToBundleThenMac() {
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
            ) == .macOS
        )
    }

    @Test func listenFactoryHonorsPreferredProvider() {
        let apple = BuddyTranscriptionProviderFactory.makeProvider(preferred: .apple)
        #expect(apple.displayName == "Apple Speech")
    }

    @Test func listenFactoryFallsBackWhenOnDeviceIsMissing() {
        // Never pretends a missing model is usable: without the download the
        // factory hands back something that can actually run.
        let provider = BuddyTranscriptionProviderFactory.makeProvider(preferred: .onDevice)
        #expect(provider.isConfigured)
    }
}

@MainActor
struct VoiceProviderPersistenceTests {

    @Test func companionDefaultsSpeakToMacWhenNothingStored() {
        UserDefaults.standard.removeObject(forKey: CompanionManager.speakPreferenceKey)
        let manager = CompanionManager()
        #expect(manager.selectedSpeakProvider == .macOS)
        UserDefaults.standard.removeObject(forKey: CompanionManager.speakPreferenceKey)
    }

    @Test func companionPersistsListenAndSpeakChoices() {
        UserDefaults.standard.removeObject(forKey: CompanionManager.listenPreferenceKey)
        UserDefaults.standard.removeObject(forKey: CompanionManager.speakPreferenceKey)
        let manager = CompanionManager()

        manager.setSelectedListenProvider(.apple)
        manager.setSelectedSpeakProvider(.elevenLabs)

        #expect(UserDefaults.standard.string(forKey: CompanionManager.listenPreferenceKey) == "apple")
        #expect(UserDefaults.standard.string(forKey: CompanionManager.speakPreferenceKey) == "elevenlabs")
        #expect(manager.selectedListenProvider == .apple)
        #expect(manager.selectedSpeakProvider == .elevenLabs)
        #expect(manager.buddyDictationManager.transcriptionProviderDisplayName == "Apple Speech")

        UserDefaults.standard.removeObject(forKey: CompanionManager.listenPreferenceKey)
        UserDefaults.standard.removeObject(forKey: CompanionManager.speakPreferenceKey)
    }
}
