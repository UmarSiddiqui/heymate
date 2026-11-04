//
//  AppUpdateController.swift
//  HeyMate
//
//  Owns the Sparkle updater for the whole app so a settings row can drive it.
//  Sparkle is linked in every build, but only release archives receive a feed
//  URL and public signing key. Source and Debug builds deliberately stay inert.
//

import AppKit
import Combine
import Foundation
import Sparkle

nonisolated enum AppUpdateAvailability: Equatable, Sendable {
    case sourceBuild
    case notStarted
    case starting
    case ready
    case failed
}

/// The two Info.plist values that must describe the same release channel.
/// Keeping validation independent from Sparkle makes the unset source-build
/// behavior deterministic and unit-testable.
nonisolated struct SparkleUpdateConfiguration: Equatable, Sendable {
    let feedURL: URL
    let publicEDKey: String

    static func resolve(from infoDictionary: [String: Any]) -> SparkleUpdateConfiguration? {
        guard let rawFeedURL = infoDictionary["SUFeedURL"] as? String,
              let rawPublicKey = infoDictionary["SUPublicEDKey"] as? String else { return nil }

        let feedURLString = rawFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicKey = rawPublicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let feedURL = URL(string: feedURLString),
              feedURL.scheme?.lowercased() == "https",
              feedURL.host != nil,
              let decodedPublicKey = Data(base64Encoded: publicKey),
              decodedPublicKey.count == 32 else { return nil }

        return SparkleUpdateConfiguration(feedURL: feedURL, publicEDKey: publicKey)
    }
}

nonisolated struct AppUpdateReminder: Equatable, Sendable {
    let version: String
    let build: String
    let isReadyToInstall: Bool

    var id: String { "\(build):\(isReadyToInstall)" }
    var title: String { isReadyToInstall ? "HeyMate \(version) is ready to install" : "HeyMate \(version) is available" }
}

nonisolated struct AppUpdateReminderSnooze: Equatable, Sendable {
    let reminderID: String
    let until: Date

    func hides(_ reminder: AppUpdateReminder, at date: Date) -> Bool {
        reminder.id == reminderID && date < until
    }
}

/// Keeps SwiftUI controls in sync with Sparkle, which owns update preferences
/// and the signed download/install flow.
@MainActor
final class AppUpdateController: ObservableObject {

    static let shared = AppUpdateController()

    /// Mirrors `SPUUpdater.canCheckForUpdates`, which is false while a check
    /// is already in flight.
    @Published private(set) var canCheckForUpdates: Bool = false

    /// Mirrors the automatic-check preference Sparkle persists itself. Exposed
    /// so the settings toggle reads the same value Sparkle will act on.
    @Published var automaticallyChecksForUpdates: Bool = false {
        didSet {
            guard let updaterController else { return }
            guard updaterController.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            updaterController.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    @Published var automaticallyDownloadsUpdates: Bool = false {
        didSet {
            guard let updater = updaterController?.updater,
                  updater.automaticallyDownloadsUpdates != automaticallyDownloadsUpdates else { return }
            updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    @Published private(set) var allowsAutomaticUpdates = false
    @Published private(set) var reminder: AppUpdateReminder?
    @Published private(set) var reminderSnooze: AppUpdateReminderSnooze?
    private var installsOnQuit = false
    private let defaults: UserDefaults
    private static let snoozeIDKey = "HeyMateUpdateReminderID"
    private static let snoozeDateKey = "HeyMateUpdateReminderUntil"

    /// The last successful update check, for the "Last checked" footnote.
    @Published private(set) var lastUpdateCheckDate: Date?

    /// Separates a valid release configuration from a successfully started
    /// updater. Settings never presents controls backed by a nil controller.
    @Published private(set) var availability: AppUpdateAvailability

    private var updaterController: SPUStandardUpdaterController?
    private let userDriverDelegate = BackgroundAppUpdateDriverDelegate()
    private var observations = Set<AnyCancellable>()
    private let hasReleaseConfiguration: Bool

    /// False for ordinary source/Debug builds where release.sh did not embed
    /// a signed feed. Settings uses this to avoid offering inert controls.
    var isConfigured: Bool {
        hasReleaseConfiguration
    }

    var isReady: Bool { availability == .ready }

    init(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:], defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let isConfigured = SparkleUpdateConfiguration.resolve(from: infoDictionary) != nil
        hasReleaseConfiguration = isConfigured
        availability = isConfigured ? .notStarted : .sourceBuild
        if let id = defaults.string(forKey: Self.snoozeIDKey),
           let until = defaults.object(forKey: Self.snoozeDateKey) as? Date {
            reminderSnooze = AppUpdateReminderSnooze(reminderID: id, until: until)
        }
    }

    /// Starts the updater. Called once from the app delegate on launch.
    /// An ordinary source build has empty Sparkle settings and intentionally
    /// returns here without constructing an updater.
    func start() {
        guard updaterController == nil else { return }
        guard isConfigured else { return }
        availability = .starting

        userDriverDelegate.owner = self
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: userDriverDelegate,
            userDriverDelegate: userDriverDelegate
        )
        self.updaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            let errorCode = (error as NSError).code
            HeyMateLog.log("⚠️ HeyMate: Sparkle updater failed to start with code \(errorCode)")
            self.updaterController = nil
            availability = .failed
            return
        }

        availability = .ready
        let updater = updaterController.updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &observations)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.automaticallyChecksForUpdates = $0 }
            .store(in: &observations)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.automaticallyDownloadsUpdates = $0 }
            .store(in: &observations)
        updater.publisher(for: \.allowsAutomaticUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.allowsAutomaticUpdates = $0 }
            .store(in: &observations)
        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastUpdateCheckDate = $0 }
            .store(in: &observations)
    }

    func remindLater() {
        guard let reminder else { return }
        let until = Date().addingTimeInterval(24 * 60 * 60)
        reminderSnooze = AppUpdateReminderSnooze(reminderID: reminder.id, until: until)
        defaults.set(reminder.id, forKey: Self.snoozeIDKey)
        defaults.set(until, forKey: Self.snoozeDateKey)
    }

    func showReminder(_ reminder: AppUpdateReminder, installsOnQuit: Bool = false) {
        self.installsOnQuit = installsOnQuit
        self.reminder = reminder
    }

    func finishReminderSession() {
        // An automatic download can finish its session while installation is
        // still waiting for quit. Keep that restart reminder visible.
        if !installsOnQuit { clearReminder() }
    }

    func clearReminder() {
        installsOnQuit = false
        reminder = nil
    }

    /// Shows Sparkle's own update UI. No-op when the updater never started.
    func checkForUpdates() {
        guard canCheckForUpdates, let updaterController else { return }
        updaterController.updater.checkForUpdates()
        lastUpdateCheckDate = updaterController.updater.lastUpdateCheckDate
    }

    /// Version string shown next to the check button.
    var displayedVersion: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        guard let buildNumber, buildNumber != shortVersion else { return shortVersion }
        return "\(shortVersion) (\(buildNumber))"
    }
}


/// Scheduled checks use an inline reminder instead of stealing focus from
/// another app. Explicit checks still use Sparkle's full update window.
@MainActor
final class BackgroundAppUpdateDriverDelegate: NSObject, @MainActor SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    weak var owner: AppUpdateController?
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Critical updates keep Sparkle's immediate presentation.
        update.isCriticalUpdate
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if handleShowingUpdate {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            owner?.showReminder(AppUpdateReminder(version: update.displayVersionString,
                                                   build: update.versionString,
                                                   isReadyToInstall: state.stage != .notDownloaded))
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        owner?.finishReminderSession()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        owner?.showReminder(AppUpdateReminder(version: item.displayVersionString,
                                               build: item.versionString,
                                               isReadyToInstall: true), installsOnQuit: true)
        // Sparkle retains control of scheduling and installation on normal quit.
        return false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        owner?.clearReminder()
    }

    func standardUserDriverWillShowModalAlert() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
