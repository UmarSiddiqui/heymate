//
//  ReleaseConfigurationTests.swift
//  HeyMateTests
//

import Foundation
import Testing
@testable import HeyMate

struct SparkleUpdateConfigurationTests {

    private let validPublicKey = Data(repeating: 0x2A, count: 32).base64EncodedString()

    @Test func resolvesACompleteHTTPSReleaseConfiguration() {
        let configuration = SparkleUpdateConfiguration.resolve(from: [
            "SUFeedURL": "https://github.com/example/heymate/releases/latest/download/appcast.xml",
            "SUPublicEDKey": validPublicKey
        ])

        #expect(configuration?.feedURL.absoluteString == "https://github.com/example/heymate/releases/latest/download/appcast.xml")
        #expect(configuration?.publicEDKey == validPublicKey)
    }

    @Test func unsetSourceBuildConfigurationStaysDisabled() {
        #expect(SparkleUpdateConfiguration.resolve(from: [:]) == nil)
        #expect(SparkleUpdateConfiguration.resolve(from: [
            "SUFeedURL": "$(SPARKLE_FEED_URL)",
            "SUPublicEDKey": "$(SPARKLE_PUBLIC_ED_KEY)"
        ]) == nil)
    }

    @Test func rejectsInsecureFeedsAndWrongKeys() {
        #expect(SparkleUpdateConfiguration.resolve(from: [
            "SUFeedURL": "http://example.com/appcast.xml",
            "SUPublicEDKey": validPublicKey
        ]) == nil)
        #expect(SparkleUpdateConfiguration.resolve(from: [
            "SUFeedURL": "https://example.com/appcast.xml",
            "SUPublicEDKey": Data(repeating: 0x2A, count: 31).base64EncodedString()
        ]) == nil)
    }
}

struct SupportLinksTests {

    @Test func supportLinksPointAtIssueFormsAndNotDiscussions() {
        let paths = Dictionary(uniqueKeysWithValues: SupportLinks.destinations.map { ($0.id, $0.url.path) })
        let urls = Dictionary(uniqueKeysWithValues: SupportLinks.destinations.map { ($0.id, $0.url) })

        #expect(paths["report-a-bug"]?.hasSuffix("/issues/new") == true)
        #expect(paths["request-a-feature"]?.hasSuffix("/issues/new") == true)
        #expect(paths["issues"]?.hasSuffix("/issues") == true)
        #expect(urls["report-a-bug"]?.query == "template=bug.yml")
        #expect(urls["request-a-feature"]?.query == "template=feature.yml")
        #expect(SupportLinks.destinations.contains { $0.url.path.hasSuffix("/discussions") } == false)
    }

    /// Updates install on their own and quietly; the running app's Info.plist
    /// is the one Sparkle reads.
    @Test func updatesCheckDownloadAndInstallWithoutAsking() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(info["SUAutomaticallyUpdate"] as? Bool == true)
        #expect((info["SUScheduledCheckInterval"] as? Int ?? 0) <= 86_400)
    }
}


struct AppUpdateReminderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let available = AppUpdateReminder(version: "1.4", build: "140", isReadyToInstall: false)

    @Test func snoozeExpiresAtDeadline() {
        let snooze = AppUpdateReminderSnooze(reminderID: available.id, until: now.addingTimeInterval(86_400))
        #expect(snooze.hides(available, at: now))
        #expect(snooze.hides(available, at: now.addingTimeInterval(86_399)))
        #expect(!snooze.hides(available, at: now.addingTimeInterval(86_400)))
    }

    @Test func aNewBuildWithTheSameDisplayVersionBypassesSnooze() {
        let snooze = AppUpdateReminderSnooze(reminderID: available.id, until: now.addingTimeInterval(86_400))
        let newer = AppUpdateReminder(version: "1.4", build: "141", isReadyToInstall: false)
        #expect(!snooze.hides(newer, at: now))
    }

    @Test func finishedDownloadGetsItsOwnRestartReminder() {
        let snooze = AppUpdateReminderSnooze(reminderID: available.id, until: now.addingTimeInterval(86_400))
        let ready = AppUpdateReminder(version: "1.4", build: "140", isReadyToInstall: true)
        #expect(!snooze.hides(ready, at: now))
        let restartSnooze = AppUpdateReminderSnooze(reminderID: ready.id, until: now.addingTimeInterval(86_400))
        #expect(restartSnooze.hides(ready, at: now))
    }
}


@MainActor
struct AppUpdateReminderLifecycleTests {
    private let available = AppUpdateReminder(version: "1.4", build: "140", isReadyToInstall: false)

    @Test func dismissedManualUpdateClearsReminder() {
        let suite = "HeyMateUpdateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AppUpdateController(infoDictionary: [:], defaults: defaults)
        controller.showReminder(available)
        controller.finishReminderSession()
        #expect(controller.reminder == nil)
    }

    @Test func automaticInstallOnQuitKeepsRestartReminder() {
        let suite = "HeyMateUpdateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AppUpdateController(infoDictionary: [:], defaults: defaults)
        let ready = AppUpdateReminder(version: "1.4", build: "140", isReadyToInstall: true)
        controller.showReminder(ready, installsOnQuit: true)
        controller.finishReminderSession()
        #expect(controller.reminder == ready)
    }

    @Test func snoozeSurvivesControllerRecreationWithoutChangingUpdatePreferences() {
        let suite = "HeyMateUpdateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AppUpdateController(infoDictionary: [:], defaults: defaults)
        controller.showReminder(available)
        controller.remindLater()
        let restored = AppUpdateController(infoDictionary: [:], defaults: defaults)
        #expect(restored.reminderSnooze?.hides(available, at: Date()) == true)
        #expect((restored.reminderSnooze?.until.timeIntervalSinceNow ?? 0) > 86_390)
        // Snoozing affects inline reminders only; it doesn't disable Sparkle
        // or write Sparkle's own automatic check/download preferences.
        #expect(defaults.object(forKey: "SUEnableAutomaticChecks") == nil)
        #expect(defaults.object(forKey: "SUAutomaticallyUpdate") == nil)
    }
}
