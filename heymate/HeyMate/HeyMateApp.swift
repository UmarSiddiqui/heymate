//
//  HeyMateApp.swift
//  HeyMate
//
//  Notch-first companion app. No dock icon, no menu-bar item — the control
//  surface is the notch card (or a top-center fallback on non-notched Macs).
//

import SwiftUI

struct HeyMateApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            DesktopSettingsView(companionManager: appDelegate.companionManager)
                .frame(minWidth: 820, minHeight: 560)
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
        guard !surrenderToRunningInstance() else { return }

        HeyMateLog.log("🎯 HeyMate: Starting...")
        HeyMateLog.log("🎯 HeyMate: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        HeyMateAnalytics.configure()
        HeyMateAnalytics.trackAppOpened()

        DispatchQueue.global(qos: .utility).async {
            let removedCount = DetachedAgentRunnerDiagnosticLogs.pruneStaleLogs()
            if removedCount > 0 {
                HeyMateLog.log("🎯 HeyMate: Pruned \(removedCount) stale agent-runner logs")
            }
        }

        companionManager.start()
        AppPresencePreferences.shared.applyOnLaunch()
        AppUpdateController.shared.start()
    }

    /// Every copy of HeyMate carries the same bundle identifier — a stale build
    /// on the Desktop, an older one in /Applications, the Debug product in
    /// DerivedData — and Launch Services will happily run each of them at once,
    /// leaving the user with two notch cards fighting over the same hotkeys and
    /// the same on-disk state. Whichever copy launched first keeps the session;
    /// any later copy hands over and exits before starting a single service.
    ///
    /// Returns `true` when this process is bowing out.
    private func surrenderToRunningInstance() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }

        let ownProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        let incumbent = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .first { other in
                guard other.processIdentifier != ownProcessIdentifier else { return false }
                // Two copies launched together each see the other, so pick a
                // stable winner instead of letting both quit: the earlier launch
                // date wins, and identical dates fall back to the lower pid.
                guard let otherLaunch = other.launchDate else { return false }
                guard let ownLaunch = NSRunningApplication.current.launchDate else { return true }
                if otherLaunch != ownLaunch { return otherLaunch < ownLaunch }
                return other.processIdentifier < ownProcessIdentifier
            }

        guard let incumbent else { return false }

        HeyMateLog.log("🎯 HeyMate: Already running as pid \(incumbent.processIdentifier) from \(incumbent.bundleURL?.path ?? "an unknown path") — this copy is quitting.")
        incumbent.activate()
        // Nothing has been started yet, so leave immediately rather than going
        // through NSApp.terminate and the teardown path for a live session.
        exit(0)
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isHostingUnitTests else { return }
        companionManager.stop()
    }

    /// Verified detached execute legs survive Cmd-Q. Planning, legacy work, and
    /// launch races still stay attached to HeyMate and must finish or cancel.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isHostingUnitTests else { return .terminateNow }
        let activeCount = companionManager.activeProcessBackedAgentRunCount
        guard activeCount > 0 else { return .terminateNow }

        companionManager.openDesktopWindow(section: .agents)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = activeCount == 1
            ? "A job is still running"
            : "\(activeCount) jobs are still running"
        alert.informativeText = "HeyMate must stay open while a job is planning or still starting. Cancel that job from Jobs if you need to quit now. Work already underway can keep running after HeyMate closes."
        alert.addButton(withTitle: "Show Jobs")
        alert.runModal()
        return .terminateCancel
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
