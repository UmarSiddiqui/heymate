//
//  HeyMateDataDirectory.swift
//  HeyMate
//
//  Where HeyMate keeps its data, and the one switch that keeps the unit
//  tests away from the user's real copy.
//
//  The unit tests run inside the HeyMate app itself, with the real bundle
//  identifier. Before this, a test that built a `CompanionManager()` loaded
//  the user's real mates, chats, and agent runs, applied the active mate's
//  brain to the real preferences, and recovered real runs. Every path here
//  points at a throwaway folder while hosting tests, and the preferences —
//  which macOS will not redirect — are put back exactly as they were when
//  the test host exits.
//

import Foundation

nonisolated enum HeyMateDataDirectory {

    /// Redirects data for the unit-test host or an explicit scratch profile.
    /// XCTest's launch environment is available before its bundle is loaded.
    static let isHostingTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment[testDataRootKey] != nil
            || isUnitTestHost
    }()

    /// Unlike the scratch-data override, this identifies hosted unit tests
    /// only. A separately launched QA app must still run normal services.
    static var isUnitTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// Carries the scratch root to child processes — the detached agent
    /// runner computes the same paths and must land in the same folder.
    static let testDataRootKey = "HEYMATE_TEST_DATA_ROOT"

    /// One scratch root per test-host process, inherited by its children.
    private static let scratchRoot: URL = {
        if let inherited = ProcessInfo.processInfo.environment[testDataRootKey], inherited.hasPrefix("/") {
            return URL(fileURLWithPath: inherited, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-test-host-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }()

    /// `~/Library/Application Support`, or its scratch stand-in under tests.
    static let applicationSupportURL: URL = isHostingTests
        ? scratchRoot.appendingPathComponent("Application Support", isDirectory: true)
        : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    /// `~/Library/Application Support/heymate`.
    static var url: URL {
        applicationSupportURL.appendingPathComponent("heymate", isDirectory: true)
    }

    /// The home folder mate workspaces hang off (`~/Projects/heymate/…`).
    static let homeURL: URL = isHostingTests
        ? scratchRoot.appendingPathComponent("Home", isDirectory: true)
        : FileManager.default.homeDirectoryForCurrentUser

    // MARK: - Preferences

    nonisolated(unsafe) private static var preferencesSnapshot: [String: Any]?

    /// Snapshots this app's preferences and restores them when the test host
    /// exits. Call first thing at launch; a no-op outside tests.
    static func protectPreferencesWhileHostingTests() {
        guard isHostingTests, preferencesSnapshot == nil,
              let identifier = Bundle.main.bundleIdentifier else { return }
        setenv(testDataRootKey, scratchRoot.path, 1)
        preferencesSnapshot = UserDefaults.standard.persistentDomain(forName: identifier) ?? [:]
        if isUnitTestHost {
            // The app delegate constructs a manager before XCTest starts its
            // fixtures. Do not warm the user's installed voice models there.
            // A scratch QA app using only testDataRootKey keeps its choices.
            UserDefaults.standard.set("macos", forKey: "selectedVoiceSpeakProvider")
            UserDefaults.standard.set("apple", forKey: "selectedVoiceListenProvider")
        }
        atexit {
            HeyMateDataDirectory.restorePreferences()
        }
    }

    private static func restorePreferences() {
        guard let snapshot = preferencesSnapshot,
              let identifier = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.setPersistentDomain(snapshot, forName: identifier)
        UserDefaults.standard.synchronize()
    }
}
