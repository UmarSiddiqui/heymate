//
//  AppPresencePreferences.swift
//  leanring-buddy
//
//  Three preferences about how visible HeyMate is to the rest of the system:
//  whether it keeps a Dock icon, whether it launches at login, and whether its
//  ambient surfaces (notch tab, notch card, cursor overlay) are captured by
//  screen recordings and screenshots.
//
//  They live together because all three are "how does this app present itself"
//  rather than "how does it behave", and because Show in Dock and the desktop
//  window both drive the same activation policy and would otherwise fight.
//

import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppPresencePreferences: ObservableObject {

    static let shared = AppPresencePreferences()

    private static let showsInDockKey = "showsInDock"
    private static let launchesAtLoginKey = "launchesAtLogin"
    private static let appearsInScreenRecordingsKey = "appearsInScreenRecordings"

    /// Off by default: HeyMate ships as an `LSUIElement` app whose home is the
    /// notch. On, the Dock tile stays for the whole session instead of only
    /// while the desktop window is open.
    @Published var showsInDock: Bool {
        didSet {
            guard showsInDock != oldValue else { return }
            UserDefaults.standard.set(showsInDock, forKey: Self.showsInDockKey)
            applyActivationPolicy()
        }
    }

    /// The app used to force-register itself as a login item on every launch
    /// with no way to say no. This makes it a real preference; on by default
    /// so existing installs keep the behavior they already have.
    @Published var launchesAtLogin: Bool {
        didSet {
            guard launchesAtLogin != oldValue else { return }
            UserDefaults.standard.set(launchesAtLogin, forKey: Self.launchesAtLoginKey)
            applyLoginItemRegistration()
        }
    }

    /// On by default, which is the behavior the app already had — the notch
    /// and cursor overlay show up in QuickTime, Zoom, and screenshots. Off
    /// sets `sharingType = .none` on those panels so a demo recording or a
    /// shared screen shows the user's work without HeyMate on top of it.
    @Published var appearsInScreenRecordings: Bool {
        didSet {
            guard appearsInScreenRecordings != oldValue else { return }
            UserDefaults.standard.set(appearsInScreenRecordings, forKey: Self.appearsInScreenRecordingsKey)
            applyScreenRecordingVisibilityToRegisteredWindows()
        }
    }

    /// Weak boxes so a closed panel does not keep this object alive or crash
    /// when the preference flips after it is gone.
    private final class WeakWindowBox {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }

    private var ambientWindows: [WeakWindowBox] = []

    private init() {
        let defaults = UserDefaults.standard
        showsInDock = defaults.bool(forKey: Self.showsInDockKey)
        launchesAtLogin = defaults.object(forKey: Self.launchesAtLoginKey) == nil
            ? true
            : defaults.bool(forKey: Self.launchesAtLoginKey)
        appearsInScreenRecordings = defaults.object(forKey: Self.appearsInScreenRecordingsKey) == nil
            ? true
            : defaults.bool(forKey: Self.appearsInScreenRecordingsKey)
    }

    /// Called once on launch, after the notch surface exists.
    func applyOnLaunch() {
        applyActivationPolicy()
        applyLoginItemRegistration()
    }

    // MARK: Dock presence

    /// The policy the app should sit at when no desktop window is open.
    /// `HeyMateDesktopWindowController` reads this when it restores the
    /// policy on close, so closing the window with Show in Dock on does not
    /// yank the Dock tile away.
    var restingActivationPolicy: NSApplication.ActivationPolicy {
        showsInDock ? .regular : .accessory
    }

    private func applyActivationPolicy() {
        // Never demote while a real window is on screen — that would strip
        // the menu bar out from under a window the user is looking at.
        let hasVisibleOrdinaryWindow = NSApp.windows.contains { window in
            window.isVisible && window.styleMask.contains(.titled)
        }
        guard !hasVisibleOrdinaryWindow || showsInDock else { return }
        NSApp.setActivationPolicy(restingActivationPolicy)
    }

    // MARK: Login item

    private func applyLoginItemRegistration() {
        let loginItemService = SMAppService.mainApp
        do {
            if launchesAtLogin {
                guard loginItemService.status != .enabled else { return }
                try loginItemService.register()
            } else {
                guard loginItemService.status == .enabled else { return }
                try loginItemService.unregister()
            }
        } catch {
            print("⚠️ HeyMate: Failed to update login item registration: \(error)")
        }
    }

    // MARK: Screen recording visibility

    /// Ambient surfaces call this as they are created. Registration also
    /// applies the current preference immediately, so a panel built after the
    /// user turned recording visibility off is born hidden.
    func registerAmbientWindow(_ window: NSWindow) {
        ambientWindows.removeAll { $0.window == nil }
        guard !ambientWindows.contains(where: { $0.window === window }) else { return }
        ambientWindows.append(WeakWindowBox(window))
        window.sharingType = appearsInScreenRecordings ? .readOnly : .none
    }

    private func applyScreenRecordingVisibilityToRegisteredWindows() {
        ambientWindows.removeAll { $0.window == nil }
        let sharingType: NSWindow.SharingType = appearsInScreenRecordings ? .readOnly : .none
        for box in ambientWindows {
            box.window?.sharingType = sharingType
        }
    }
}
