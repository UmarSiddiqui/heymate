//
//  NotchFullScreenMonitor.swift
//  HeyMate
//
//  Tells the notch when the frontmost app has a window covering the whole
//  display (a full-screen app, a slideshow, a game), so the character can
//  step out of the way. Event driven: it checks on app activation and on
//  Space changes, never on a timer. Window bounds and owner PIDs are
//  readable without Screen Recording; no titles or pixels are touched.
//

import AppKit
import CoreGraphics

@MainActor
final class NotchFullScreenMonitor {
    private var observers: [NSObjectProtocol] = []
    private var pendingCheck: DispatchWorkItem?
    private var onChange: ((Bool) -> Void)?
    private var screenProvider: (() -> NSScreen?)?
    private(set) var isFrontmostFullScreen = false

    /// Space switches animate for about half a second; the new space's
    /// windows are only in the window list once that settles.
    private static let settleDelay: TimeInterval = 0.6

    func start(screen: @escaping () -> NSScreen?, onChange: @escaping (Bool) -> Void) {
        stop()
        self.screenProvider = screen
        self.onChange = onChange
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleCheck() }
            })
        }
        check()
    }

    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        pendingCheck?.cancel()
        pendingCheck = nil
        onChange = nil
        screenProvider = nil
    }

    private func scheduleCheck() {
        check()
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.check() }
        }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func check() {
        let value = Self.frontmostAppCoversScreen(screenProvider?())
        guard value != isFrontmostFullScreen else { return }
        isFrontmostFullScreen = value
        onChange?(value)
    }

    private static func frontmostAppCoversScreen(_ screen: NSScreen?) -> Bool {
        guard let screen,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let pid = app.processIdentifier
        let bounds = info.compactMap { window -> CGRect? in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let raw = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: raw) else { return nil }
            return rect
        }
        return coversScreen(windowBounds: bounds, screenFrame: displayBounds(for: screen))
    }

    /// The screen in the window list's coordinates (top-left origin).
    private static func displayBounds(for screen: NSScreen) -> CGRect {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                      width: screen.frame.width, height: screen.frame.height)
    }

    /// True when any window fills the display edge to edge. A maximised
    /// window stops at the menu bar, so it does not count.
    nonisolated static func coversScreen(windowBounds: [CGRect], screenFrame: CGRect) -> Bool {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return false }
        return windowBounds.contains { rect in
            abs(rect.minX - screenFrame.minX) <= 1 && abs(rect.minY - screenFrame.minY) <= 1
                && rect.width >= screenFrame.width - 1 && rect.height >= screenFrame.height - 1
        }
    }
}
