//
//  AppThemeTests.swift
//  leanring-buddyTests
//
//  Theme color persists, unknown values fall back to Signal blue, and
//  notch chrome remains solid black regardless of old rim preferences.
//

import CoreGraphics
import Foundation
import Testing
@testable import HeyMate

struct AppThemeTests {

    @Test func unknownHexFallsBackToSignalBlue() {
        #expect(AppTheme.resolvedHex(storedRawValue: nil) == AppTheme.defaultHex)
        #expect(AppTheme.resolvedHex(storedRawValue: "not-a-color") == AppTheme.defaultHex)
        #expect(AppTheme.resolvedHex(storedRawValue: "#3380FF") == "3380FF")
        #expect(AppTheme.resolvedHex(storedRawValue: "ff6b5a") == "FF6B5A")
    }

    @Test func outlineStaysDisabledForOldPreferences() {
        #expect(AppTheme.outlineEnabled(storedObject: nil) == false)
        #expect(AppTheme.outlineEnabled(storedObject: false) == false)
        #expect(AppTheme.outlineEnabled(storedObject: true) == false)
    }

    @Test func outlinePaddingHugsHardwareWithoutMovingOffTheScreenTop() {
        let hardware = CGRect(x: 665, y: 950, width: 185, height: 32)
        let off = NotchLayoutMath.outlinePaddedFrame(hardware: hardware, isOutlineEnabled: false)
        #expect(off == hardware)

        let on = NotchLayoutMath.outlinePaddedFrame(hardware: hardware, isOutlineEnabled: true)
        #expect(on.maxY == hardware.maxY)
        #expect(on.minX == hardware.minX - NotchLayoutMath.outlinePad)
        #expect(on.maxX == hardware.maxX + NotchLayoutMath.outlinePad)
        #expect(on.minY == hardware.minY - NotchLayoutMath.outlinePad)
        #expect(on.height == hardware.height + NotchLayoutMath.outlinePad)
        #expect(on.midX == hardware.midX)
    }
}

@MainActor
struct AppThemePersistenceTests {

    @Test func companionPersistsThemeAndRejectsOldOutlineToggle() {
        UserDefaults.standard.removeObject(forKey: CompanionManager.themeColorPreferenceKey)
        UserDefaults.standard.removeObject(forKey: CompanionManager.notchOutlinePreferenceKey)
        let manager = CompanionManager()

        #expect(manager.themeColorHex == AppTheme.defaultHex)
        #expect(manager.isNotchOutlineEnabled == false)

        manager.setThemeColorHex("FF6B5A")
        manager.setNotchOutlineEnabled(true)

        #expect(UserDefaults.standard.string(forKey: CompanionManager.themeColorPreferenceKey) == "FF6B5A")
        #expect(UserDefaults.standard.object(forKey: CompanionManager.notchOutlinePreferenceKey) == nil)
        #expect(manager.themeColorHex == "FF6B5A")
        #expect(manager.isNotchOutlineEnabled == false)

        UserDefaults.standard.removeObject(forKey: CompanionManager.themeColorPreferenceKey)
        UserDefaults.standard.removeObject(forKey: CompanionManager.notchOutlinePreferenceKey)
    }
}
