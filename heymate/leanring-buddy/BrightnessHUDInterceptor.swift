//
//  BrightnessHUDInterceptor.swift
//  leanring-buddy
//
//  Optional brightness and keyboard-backlight key replacement. Same shape
//  as the volume HUD: an Accessibility event tap consumes only the keys it
//  can actually service, applies the change, and publishes a notch HUD in
//  place of the macOS overlay.
//

import AppKit
import Combine
import Foundation

@MainActor
final class BrightnessHUDInterceptor: ObservableObject {
    @Published private(set) var activity: NotchActivity?

    private let display = DisplayBrightnessControl()
    private let keyboard = KeyboardBacklightControl()
    private lazy var keyTap = SystemMediaKeyTap { [weak self] press in
        self?.handle(press) ?? false
    }
    private var clearTask: Task<Void, Never>?

    /// How long the HUD lingers after the last key press.
    private static let displayDuration: Duration = .milliseconds(1_300)

    func start() {
        keyTap.start()
    }

    func stop() {
        clearTask?.cancel()
        clearTask = nil
        keyTap.stop()
        activity = nil
    }

    private func handle(_ press: SystemMediaKeyPress) -> Bool {
        switch press.keyCode {
        case SystemMediaKeyPress.brightnessUp, SystemMediaKeyPress.brightnessDown:
            // No built-in panel or no private API: leave the key to macOS.
            guard display.isAvailable, !press.wantsNativeSettingsShortcut else { return false }
            if press.isKeyDown, let current = display.current() {
                let next = BrightnessStep.stepped(
                    current,
                    up: press.keyCode == SystemMediaKeyPress.brightnessUp,
                    fine: press.wantsFineAdjustment
                )
                if display.set(next) { publish(.brightness, level: next) }
            }
            return true

        case SystemMediaKeyPress.illuminationUp,
             SystemMediaKeyPress.illuminationDown,
             SystemMediaKeyPress.illuminationToggle:
            guard keyboard.isAvailable, !press.wantsNativeSettingsShortcut else { return false }
            if press.isKeyDown, let current = keyboard.current() {
                let next: Float
                if press.keyCode == SystemMediaKeyPress.illuminationToggle {
                    next = keyboard.toggledLevel(from: current)
                } else {
                    next = BrightnessStep.stepped(
                        current,
                        up: press.keyCode == SystemMediaKeyPress.illuminationUp,
                        fine: press.wantsFineAdjustment
                    )
                }
                if keyboard.set(next) { publish(.keyboardBacklight, level: next) }
            }
            return true

        default:
            return false
        }
    }

    private func publish(_ kind: NotchActivityKind, level: Float) {
        clearTask?.cancel()
        let isOff = level <= 0.001
        activity = NotchActivity(
            kind: kind,
            trailingText: isOff ? "Off" : BrightnessStep.label(for: level),
            progress: Double(level),
            expiresAt: Date().addingTimeInterval(1.3),
            symbolOverride: kind == .brightness && level < 0.5 ? "sun.min.fill" : nil
        )
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: Self.displayDuration)
            guard !Task.isCancelled else { return }
            self?.activity = nil
        }
    }
}
