//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Notch-first companion app. No dock icon, no menu-bar item — the control
//  surface is the notch card (or a top-center fallback on non-notched Macs).
//

import SwiftUI

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            DesktopSettingsView(companionManager: appDelegate.companionManager)
                .frame(minWidth: 820, minHeight: 560)
                .preferredColorScheme(.dark)
        }
    }
}

/// Manages the companion lifecycle: starts the voice pipeline and the notch
/// control surface on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    let companionManager = CompanionManager()

    /// Hosted unit tests inject XCTest into the app before launch. Starting
    /// production services here can block XCTest itself (for example while
    /// Keychain waits), so leave the host idle and let the test runner drive it.
    private var isHostingUnitTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isHostingUnitTests else { return }

        print("🎯 HeyMate: Starting...")
        print("🎯 HeyMate: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        ClickyAnalytics.configure()
        ClickyAnalytics.trackAppOpened()

        companionManager.start()
        AppPresencePreferences.shared.applyOnLaunch()
        AppUpdateController.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isHostingUnitTests else { return }
        companionManager.stop()
    }

    /// macOS delivers `heymate://` URLs here: connector OAuth callbacks
    /// from the browser, and `heymate://open/<section>` links that open the
    /// desktop window straight to a page.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            companionManager.handleDeepLink(url)
        }
    }

    /// Clicking the Dock icon while the desktop window is closed should
    /// bring it back rather than doing nothing. Only reachable while the
    /// window is open, since that is the only time the app has a Dock tile.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        companionManager.openDesktopWindow()
        return true
    }

}
