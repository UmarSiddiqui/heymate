//
//  NotchHUDAndDeviceTests.swift
//  leanring-buddyTests
//
//  Pure rules behind the brightness/backlight HUD, the Bluetooth activity,
//  and Now Playing artwork: media-key decoding, step math, device labels,
//  and which artwork URLs are ever fetched.
//

import AppKit
import Foundation
import Testing
@testable import HeyMate

@MainActor
struct NotchHUDAndDeviceTests {

    /// NX_SYSDEFINED data1 layout: key code in the high 16 bits, key state
    /// (0xA down, 0xB up) in bits 8–15, repeat flag in bit 0.
    private func data1(keyCode: Int, down: Bool, repeat isRepeat: Bool = false) -> Int {
        (keyCode << 16) | ((down ? 0xA : 0xB) << 8) | (isRepeat ? 1 : 0)
    }

    // MARK: Media keys

    @Test func decodesBrightnessKeyDownAndUp() {
        let down = SystemMediaKeyPress(data1: data1(keyCode: 2, down: true), modifierFlags: [])
        #expect(down.keyCode == SystemMediaKeyPress.brightnessUp)
        #expect(down.isKeyDown)
        #expect(!down.isRepeat)

        let up = SystemMediaKeyPress(data1: data1(keyCode: 3, down: false), modifierFlags: [])
        #expect(up.keyCode == SystemMediaKeyPress.brightnessDown)
        #expect(!up.isKeyDown)
    }

    @Test func decodesKeyboardIlluminationAndRepeat() {
        let press = SystemMediaKeyPress(data1: data1(keyCode: 21, down: true, repeat: true), modifierFlags: [])
        #expect(press.keyCode == SystemMediaKeyPress.illuminationUp)
        #expect(press.isRepeat)
    }

    @Test func optionAloneKeepsTheNativeSettingsShortcut() {
        let optionOnly = SystemMediaKeyPress(data1: data1(keyCode: 2, down: true), modifierFlags: [.option])
        #expect(optionOnly.wantsNativeSettingsShortcut)
        #expect(!optionOnly.wantsFineAdjustment)

        let optionShift = SystemMediaKeyPress(data1: data1(keyCode: 2, down: true), modifierFlags: [.option, .shift])
        #expect(!optionShift.wantsNativeSettingsShortcut)
        #expect(optionShift.wantsFineAdjustment)
    }

    // MARK: Brightness steps

    @Test func stepsMatchMacOSSixteenAndSixtyFourSteps() {
        #expect(BrightnessStep.stepped(0.5, up: true, fine: false) == 0.5 + 1 / 16)
        #expect(BrightnessStep.stepped(0.5, up: false, fine: true) == 0.5 - 1 / 64)
    }

    @Test func stepsClampAtBothEnds() {
        #expect(BrightnessStep.stepped(0.98, up: true, fine: false) == 1)
        #expect(BrightnessStep.stepped(0.02, up: false, fine: false) == 0)
    }

    @Test func levelLabelIsAWholePercentage() {
        #expect(BrightnessStep.label(for: 0.625) == "63%")
        #expect(BrightnessStep.label(for: 1.4) == "100%")
    }

    // MARK: Bluetooth

    @Test func dropsThePossessiveOwnerFromDeviceNames() {
        #expect(BluetoothActivityMonitor.displayName(forDeviceName: "Umar's AirPods Pro") == "AirPods Pro")
        #expect(BluetoothActivityMonitor.displayName(forDeviceName: "Umar’s Magic Keyboard") == "Magic Keyboard")
        #expect(BluetoothActivityMonitor.displayName(forDeviceName: "MX Master 3S") == "MX Master 3S")
    }

    @Test func symbolFollowsTheBluetoothDeviceClass() {
        #expect(BluetoothActivityMonitor.symbolName(majorClass: 0x04, minorClass: 0x06) == "headphones")
        #expect(BluetoothActivityMonitor.symbolName(majorClass: 0x04, minorClass: 0x05) == "hifispeaker.fill")
        #expect(BluetoothActivityMonitor.symbolName(majorClass: 0x05, minorClass: 0x10) == "keyboard")
        #expect(BluetoothActivityMonitor.symbolName(majorClass: 0x05, minorClass: 0x20) == "computermouse")
        #expect(BluetoothActivityMonitor.symbolName(majorClass: 0x05, minorClass: 0x02) == "gamecontroller")
        #expect(BluetoothActivityMonitor.symbolName(majorClass: 0x05, minorClass: 0x00) == "dot.radiowaves.left.and.right")
        #expect(BluetoothActivityMonitor.symbolName(majorClass: 0x01, minorClass: 0x00) == "dot.radiowaves.left.and.right")
    }

    // MARK: Activity rules

    @Test func symbolOverrideReplacesTheKindSymbol() {
        let keyboard = NotchActivity(kind: .bluetooth, trailingText: "Keyboard", symbolOverride: "keyboard")
        #expect(keyboard.symbolName == "keyboard")
        #expect(NotchActivity(kind: .bluetooth, trailingText: "AirPods").symbolName == "headphones")
    }

    @Test func aKeyPressHUDOutranksNowPlaying() {
        let media = NotchActivity(kind: .media, trailingText: "Song")
        let brightness = NotchActivity(kind: .brightness, trailingText: "50%")
        let winner = NotchActivityArbiter.frontmostActivity(among: [media, brightness])
        #expect(winner?.kind == .brightness)
    }

    @Test func pillTextTruncatesOnAWordBoundary() {
        #expect(NotchActivity.pillText("AirPods Pro") == "AirPods Pro")
        #expect(NotchActivity.pillText("Everything In Its Right Place") == "Everything In…")
    }

    @Test func newMicroAppsAreOptInWithDisclosedPermissions() {
        #expect(!NotchMicroApp.defaultEnabled.contains(.brightnessHUD))
        #expect(!NotchMicroApp.defaultEnabled.contains(.bluetooth))
        #expect(NotchMicroApp.brightnessHUD.requiredPermissionDescription == "Accessibility access")
        #expect(NotchMicroApp.bluetooth.requiredPermissionDescription == "Bluetooth access")
    }

    // MARK: Artwork

    @Test func onlyHTTPSSpotifyArtworkURLsAreFetched() {
        let url = NowPlayingMonitor.spotifyArtworkURL(fromScriptOutput: "\"https://i.scdn.co/image/ab67616d0000b273\"")
        #expect(url?.host == "i.scdn.co")
        #expect(NowPlayingMonitor.spotifyArtworkURL(fromScriptOutput: "\"http://i.scdn.co/image/x\"") == nil)
        #expect(NowPlayingMonitor.spotifyArtworkURL(fromScriptOutput: "\"\"") == nil)
        #expect(NowPlayingMonitor.spotifyArtworkURL(fromScriptOutput: "missing value") == nil)
    }

    @Test func artworkIsOnlyRequestedFromKnownPlayers() {
        #expect(NowPlayingMonitor.bundleIdentifier(forPlayerNamed: "Music") == "com.apple.Music")
        #expect(NowPlayingMonitor.bundleIdentifier(forPlayerNamed: "Spotify") == "com.spotify.client")
        #expect(NowPlayingMonitor.bundleIdentifier(forPlayerNamed: "VLC") == nil)
    }

    @Test func artworkKeyChangesWithTheTrack() {
        let first = NowPlayingMonitor.NowPlayingSnapshot(appName: "Music", title: "A", artist: "X", isPlaying: true)
        let second = NowPlayingMonitor.NowPlayingSnapshot(appName: "Music", title: "B", artist: "X", isPlaying: true)
        #expect(NowPlayingMonitor.artworkKey(for: first) != NowPlayingMonitor.artworkKey(for: second))
    }
}
