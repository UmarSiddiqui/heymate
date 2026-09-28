//
//  SystemBrightnessControls.swift
//  leanring-buddy
//
//  Built-in display brightness and keyboard backlight, for the notch HUD.
//
//  macOS has no public API for either. The system's own brightness keys go
//  through DisplayServices (display) and CoreBrightness's
//  KeyboardBrightnessClient (keyboard), both private frameworks. Every
//  symbol is looked up at runtime and every lookup can fail: a missing
//  symbol makes `isAvailable` false, and the HUD then leaves the key to
//  macOS instead of swallowing it. A point release can remove these APIs;
//  it can never leave the user without working brightness keys.
//

import CoreGraphics
import Foundation
import ObjectiveC

/// Pure step math shared by both controls, so the rules are testable.
enum BrightnessStep {
    /// macOS moves brightness in 16 steps, or 64 with Option-Shift.
    static func stepped(_ current: Float, up: Bool, fine: Bool) -> Float {
        let step: Float = fine ? 1 / 64 : 1 / 16
        return clamped(current + (up ? step : -step))
    }

    static func clamped(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    /// Short label for the pill, e.g. "63%".
    static func label(for value: Float) -> String {
        "\(Int((clamped(value) * 100).rounded()))%"
    }
}

/// The built-in display's brightness via DisplayServices.
@MainActor
final class DisplayBrightnessControl {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getBrightness: GetBrightness?
    private let setBrightness: SetBrightness?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        getBrightness = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }
            .map { unsafeBitCast($0, to: GetBrightness.self) }
        setBrightness = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }
            .map { unsafeBitCast($0, to: SetBrightness.self) }
    }

    /// The built-in panel, or nil on a desktop Mac or a closed-lid setup,
    /// where the keys belong to an external display we don't drive.
    private var builtInDisplay: CGDirectDisplayID? {
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetOnlineDisplayList(displayCount, &displays, &displayCount) == .success else { return nil }
        return displays.first { CGDisplayIsBuiltin($0) != 0 }
    }

    var isAvailable: Bool {
        getBrightness != nil && setBrightness != nil && builtInDisplay != nil
    }

    func current() -> Float? {
        guard let getBrightness, let display = builtInDisplay else { return nil }
        var value: Float = 0
        guard getBrightness(display, &value) == 0 else { return nil }
        return value
    }

    @discardableResult
    func set(_ value: Float) -> Bool {
        guard let setBrightness, let display = builtInDisplay else { return false }
        return setBrightness(display, BrightnessStep.clamped(value)) == 0
    }
}

/// The keyboard backlight via CoreBrightness's KeyboardBrightnessClient.
/// Apple silicon MacBooks dropped the dedicated keys, but external Apple
/// keyboards and older MacBooks still send them.
@MainActor
final class KeyboardBacklightControl {
    private typealias GetLevel = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias SetLevel = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool

    private static let getSelector = NSSelectorFromString("brightnessForKeyboard:")
    private static let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")
    private static let identifiersSelector = NSSelectorFromString("copyKeyboardBacklightIDs")

    private let client: NSObject?
    private let getLevel: GetLevel?
    private let setLevel: SetLevel?
    private let keyboardID: UInt64?
    /// Level to restore when the toggle key turns the light back on.
    private var levelBeforeOff: Float = 0.5

    init() {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        guard let clientClass = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            client = nil; getLevel = nil; setLevel = nil; keyboardID = nil
            return
        }
        let instance = clientClass.init()
        guard instance.responds(to: Self.getSelector),
              instance.responds(to: Self.setSelector),
              instance.responds(to: Self.identifiersSelector),
              let getIMP = class_getMethodImplementation(clientClass, Self.getSelector),
              let setIMP = class_getMethodImplementation(clientClass, Self.setSelector) else {
            client = nil; getLevel = nil; setLevel = nil; keyboardID = nil
            return
        }
        let identifiers = instance.perform(Self.identifiersSelector)?.takeRetainedValue() as? [NSNumber]
        client = instance
        getLevel = unsafeBitCast(getIMP, to: GetLevel.self)
        setLevel = unsafeBitCast(setIMP, to: SetLevel.self)
        keyboardID = identifiers?.first?.uint64Value
    }

    var isAvailable: Bool {
        client != nil && getLevel != nil && setLevel != nil && keyboardID != nil
    }

    func current() -> Float? {
        guard let client, let getLevel, let keyboardID else { return nil }
        return getLevel(client, Self.getSelector, keyboardID)
    }

    @discardableResult
    func set(_ value: Float) -> Bool {
        guard let client, let setLevel, let keyboardID else { return false }
        return setLevel(client, Self.setSelector, BrightnessStep.clamped(value), keyboardID)
    }

    /// Off if lit, otherwise back to the last lit level.
    func toggledLevel(from current: Float) -> Float {
        if current > 0.001 {
            levelBeforeOff = current
            return 0
        }
        return max(levelBeforeOff, 1 / 16)
    }
}
