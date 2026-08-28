//
//  UISoundPreferenceTests.swift
//  leanring-buddyTests
//
//  The interaction-sounds preference must default to on and persist through
//  the same UserDefaults key the player reads (CompanionManager.uiSoundPreferenceKey).
//

import AppKit
import Foundation
import Testing
@testable import HeyMate

@MainActor
struct UISoundPreferenceTests {

    @Test func defaultsToEnabledWhenPreferenceUnset() {
        UserDefaults.standard.removeObject(forKey: CompanionManager.uiSoundPreferenceKey)

        let manager = CompanionManager()

        #expect(manager.isUISoundEnabled == true)
    }

    @Test func setterPersistsToSharedUserDefaultsKey() {
        UserDefaults.standard.removeObject(forKey: CompanionManager.uiSoundPreferenceKey)
        let manager = CompanionManager()

        manager.isUISoundEnabled = false
        #expect(UserDefaults.standard.bool(forKey: CompanionManager.uiSoundPreferenceKey) == false)

        manager.isUISoundEnabled = true
        #expect(UserDefaults.standard.bool(forKey: CompanionManager.uiSoundPreferenceKey) == true)

        // Leave a clean slate for other tests.
        UserDefaults.standard.removeObject(forKey: CompanionManager.uiSoundPreferenceKey)
    }

    /// The bundled sound assets must exist in the app's asset catalog — a
    /// renamed data set would otherwise fail silently at play time.
    @Test func soundDataSetsExistInAssetCatalog() {
        for sound in [UISoundPlayer.Sound.listenStart, .responseReady] {
            #expect(NSDataAsset(name: sound.rawValue) != nil, "missing data set \(sound.rawValue)")
        }
    }
}
