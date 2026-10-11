//
//  SystemOverlayYield.swift
//  HeyMate
//
//  Steps HeyMate's full-screen transparent overlays aside while macOS's
//  screenshot tools are up. The overlays sit above every app, so without
//  this ⌘⇧4 then Space picks HeyMate's invisible window instead of the one
//  under the pointer, and ⌘⇧5's window picker lists it.
//
//  Watching the window list all the time would cost a little on every tick
//  for something that happens rarely, so the watch only starts when one of
//  the screenshot shortcuts is pressed and stops once the tool closes.
//

import AppKit
import CoreGraphics

@MainActor
final class SystemOverlayYield: SharedKeyboardTapListener {

    /// Called with true when overlays should step aside, false to return.
    var onYieldChange: ((Bool) -> Void)?

    private(set) var isYielding = false {
        didSet {
            guard isYielding != oldValue else { return }
            HeyMateLog.log(isYielding ? "📸 Screenshot tool open, overlays stepping aside" : "📸 Screenshot tool closed, overlays back")
            onYieldChange?(isYielding)
        }
    }

    private var watchTask: Task<Void, Never>?
    private var isListening = false

    /// ANSI key codes for 3, 4 and 5: ⌘⇧3, ⌘⇧4 and ⌘⇧5.
    nonisolated static let screenshotKeyCodes: Set<UInt16> = [20, 21, 23]
    /// Process names that own the screenshot UI windows.
    nonisolated static let screenshotProcessNames: Set<String> = ["screencaptureui", "screencapture"]

    private static let pollInterval: Duration = .milliseconds(150)
    /// The tool takes a moment to put up its windows after the shortcut.
    private static let appearanceGrace: Duration = .milliseconds(900)
    private static let maximumWatch: Duration = .seconds(120)

    func start() {
        guard !isListening else { return }
        isListening = true
        SharedKeyboardTap.shared.add(self)
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        SharedKeyboardTap.shared.remove(self)
        watchTask?.cancel()
        watchTask = nil
        isYielding = false
    }

    nonisolated static func isScreenshotShortcut(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        flags.contains(.maskCommand) && flags.contains(.maskShift) && screenshotKeyCodes.contains(keyCode)
    }

    // MARK: SharedKeyboardTapListener

    nonisolated func keyboardTapReceived(_ type: CGEventType, keyCode: UInt16, flags: CGEventFlags) {
        guard type == .keyDown, Self.isScreenshotShortcut(keyCode: keyCode, flags: flags) else { return }
        MainActor.assumeIsolated { beginWatch() }
    }

    nonisolated func keyboardTapResumed() {}

    // MARK: Watch

    private func beginWatch() {
        watchTask?.cancel()
        isYielding = true
        watchTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            let startedAt = clock.now
            var hasSeenTool = false
            while !Task.isCancelled, clock.now - startedAt < Self.maximumWatch {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                let toolIsUp = Self.screenshotToolHasWindows()
                if toolIsUp {
                    hasSeenTool = true
                } else if hasSeenTool || clock.now - startedAt > Self.appearanceGrace {
                    break
                }
            }
            guard !Task.isCancelled else { return }
            self?.isYielding = false
            self?.watchTask = nil
        }
    }

    private static func screenshotToolHasWindows() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return windows.contains { window in
            guard let owner = window[kCGWindowOwnerName as String] as? String else { return false }
            return screenshotProcessNames.contains(owner)
        }
    }
}
