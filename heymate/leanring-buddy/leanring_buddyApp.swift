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
        // The app lives entirely in the notch card managed by CompanionManager.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: starts the voice pipeline and the notch
/// control surface on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private let companionManager = CompanionManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
