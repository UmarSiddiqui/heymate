//
//  AppUpdateController.swift
//  leanring-buddy
//
//  Owns the Sparkle updater for the whole app so a settings row can drive it.
//  Sparkle is linked in every build, but only release archives receive a feed
//  URL and public signing key. Source and Debug builds deliberately stay inert.
//

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
    @Published var automaticallyChecksForUpdates: Bool = false {
        didSet {
            guard let updaterController else { return }
            guard updaterController.updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            updaterController.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    /// The last successful update check, for the "Last checked" footnote.
    @Published private(set) var lastUpdateCheckDate: Date?

    /// Separates a valid release configuration from a successfully started
    /// updater. Settings never presents controls backed by a nil controller.
    @Published private(set) var availability: AppUpdateAvailability

    private var updaterController: SPUStandardUpdaterController?
    private var canCheckObservation: AnyCancellable?
    private let hasReleaseConfiguration: Bool

    /// False for ordinary source/Debug builds where release.sh did not embed
    /// a signed feed. Settings uses this to avoid offering inert controls.
    var isConfigured: Bool {
        hasReleaseConfiguration
    }

    var isReady: Bool { availability == .ready }

    private init() {
        let isConfigured = SparkleUpdateConfiguration.resolve(
            from: Bundle.main.infoDictionary ?? [:]
        ) != nil
        hasReleaseConfiguration = isConfigured
        availability = isConfigured ? .notStarted : .sourceBuild
    }

    /// Starts the updater. Called once from the app delegate on launch.
    /// An ordinary source build has empty Sparkle settings and intentionally
    /// returns here without constructing an updater.
    func start() {
        guard updaterController == nil else { return }
        guard isConfigured else { return }
        availability = .starting

        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            let errorCode = (error as NSError).code
            print("⚠️ HeyMate: Sparkle updater failed to start with code \(errorCode)")
            self.updaterController = nil
            availability = .failed
            return
        }

        automaticallyChecksForUpdates = updaterController.updater.automaticallyChecksForUpdates
        lastUpdateCheckDate = updaterController.updater.lastUpdateCheckDate
        availability = .ready

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
