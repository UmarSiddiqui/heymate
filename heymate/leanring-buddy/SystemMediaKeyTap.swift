//
//  SystemMediaKeyTap.swift
//  leanring-buddy
//
//  Shared Accessibility event tap for the hardware media keys (volume,
//  brightness, keyboard backlight). Each HUD owns one tap and decides per
//  key whether to consume it; anything it doesn't claim passes straight
//  through to macOS, so two HUDs never fight over the same key.
//

import AppKit
import ApplicationServices
import Foundation

/// One decoded NX_SYSDEFINED media-key press. Pure value, so the decoding
/// rules are testable without a live event tap.
struct SystemMediaKeyPress: Equatable, Sendable {
    /// NX_KEYTYPE_* code from IOKit's ev_keymap.h.
    let keyCode: Int
    let isKeyDown: Bool
    let isRepeat: Bool
    let modifierFlags: NSEvent.ModifierFlags

    static let volumeUp = 0
    static let volumeDown = 1
    static let brightnessUp = 2
    static let brightnessDown = 3
    static let mute = 7
    static let illuminationUp = 21
    static let illuminationDown = 22
    static let illuminationToggle = 23

    /// Decodes `NSEvent.data1` of an `.systemDefined` event with subtype 8.
    init(data1: Int, modifierFlags: NSEvent.ModifierFlags) {
        keyCode = (data1 & 0xFFFF_0000) >> 16
        let keyFlags = data1 & 0xFFFF
        isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0xA
        isRepeat = (keyFlags & 0x1) == 0x1
        self.modifierFlags = modifierFlags
    }

    /// Option alone keeps the native shortcut (it opens the matching pane
    /// of System Settings). Option-Shift is the native "fine step".
    var wantsNativeSettingsShortcut: Bool {
        modifierFlags.contains(.option) && !modifierFlags.contains(.shift)
    }

    var wantsFineAdjustment: Bool {
        modifierFlags.contains([.option, .shift])
    }
}

@MainActor
final class SystemMediaKeyTap {
    /// Return true to consume the key (both its down and up events).
    typealias Handler = @MainActor (SystemMediaKeyPress) -> Bool

    private static let systemDefinedEventType = CGEventType(rawValue: 14)!
    private let handler: Handler
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var isRunning: Bool { eventTap != nil }

    /// Needs Accessibility. Returns without doing anything when the grant is
    /// missing, so enabling a HUD never opens a permission panel by itself.
    func start() {
        guard eventTap == nil, AXIsProcessTrusted() else { return }

        let mask = CGEventMask(1 << Self.systemDefinedEventType.rawValue)
        let pointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, eventType, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let keyTap = Unmanaged<SystemMediaKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    keyTap.handle(eventType: eventType, event: event)
                }
            },
            userInfo: pointer
        ) else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func handle(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard eventType == Self.systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }

        let press = SystemMediaKeyPress(data1: nsEvent.data1, modifierFlags: nsEvent.modifierFlags)
        return handler(press) ? nil : Unmanaged.passUnretained(event)
    }
}
