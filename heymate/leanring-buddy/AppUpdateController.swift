//
//  AppUpdateController.swift
//  leanring-buddy
//
//  Owns the Sparkle updater for the whole app so a settings row can drive it.
//  Sparkle was already linked and configured; it just had no owner outside the
//  app delegate and no user-facing entry point, so nothing could ever trigger
//  a check.
//

import Combine
import Foundation
import Sparkle

/// Wraps `SPUStandardUpdaterController` and republishes the one piece of
/// updater state the UI needs — whether a check is currently allowed — so a
/// SwiftUI button can disable itself while a check is already running.
@MainActor
final class AppUpdateController: ObservableObject {

    static let shared = AppUpdateController()

    /// Mirrors `SPUUpdater.canCheckForUpdates`, which is false while a check
    /// is already in flight.
    @Published private(set) var canCheckForUpdates: Bool = false

    /// Mirrors the automatic-check preference Sparkle persists itself. Exposed
    /// so the settings toggle reads the same value Sparkle will act on.
    @Published var automaticallyChecksForUpdates: Bool = true {
        didSet {
            guard let updaterController else { return }
            guard updaterController.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            updaterController.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// The last successful update check, for the "Last checked" footnote.
    @Published private(set) var lastUpdateCheckDate: Date?

    private var updaterController: SPUStandardUpdaterController?
    private var canCheckObservation: AnyCancellable?

    private init() {}

    /// Starts the updater. Called once from the app delegate on launch.
    /// Failing to start is not fatal — the app simply has no update path,
    /// which is exactly the state it shipped in before this was wired up.
    func start() {
        guard updaterController == nil else { return }

        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ HeyMate: Sparkle updater failed to start: \(error)")
            self.updaterController = nil
            return
        }

        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
        lastUpdateCheckDate = updaterController.updater.lastUpdateCheckDate

        canCheckObservation = updaterController.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }
    }

    /// Shows Sparkle's own update UI. No-op when the updater never started.
    func checkForUpdates() {
        guard let updaterController else { return }
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
