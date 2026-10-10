//
//  PermissionsTests.swift
//  HeyMateTests
//
//  How HeyMate asks for macOS permissions and prepares the app bundle that
//  users drag into Privacy settings.
//

import AppKit
import Testing
@testable import HeyMate

@MainActor
struct PermissionsTests {

    @Test func requestRoutesThroughPromptOnceThenSettings() {
        #expect(MacPermissions.route(hasPermission: false, alreadyPrompted: false) == .systemPrompt)
        #expect(MacPermissions.route(hasPermission: false, alreadyPrompted: true) == .systemSettings)
        #expect(MacPermissions.route(hasPermission: true, alreadyPrompted: false) == .alreadyGranted)
        #expect(MacPermissions.route(hasPermission: true, alreadyPrompted: true) == .alreadyGranted)
    }

    @Test func earlierScreenRecordingGrantCoversALaggingLiveCheck() {
        #expect(MacPermissions.screenRecordingCountsAsGranted(grantedNow: false, confirmedBefore: true))
        #expect(MacPermissions.screenRecordingCountsAsGranted(grantedNow: true, confirmedBefore: false))
        #expect(!MacPermissions.screenRecordingCountsAsGranted(grantedNow: false, confirmedBefore: false))
    }

    @Test func promptAnswerIsRememberedEvenWhenPreflightLags() {
        #expect(MacPermissions.shouldRememberScreenRecordingGrant(preflightGranted: false, promptGranted: true))
        #expect(MacPermissions.shouldRememberScreenRecordingGrant(preflightGranted: true, promptGranted: false))
        #expect(!MacPermissions.shouldRememberScreenRecordingGrant(preflightGranted: false, promptGranted: false))
    }

    @Test func setupNeedsExactlyAccessibilityScreenRecordingAndMicrophone() {
        #expect(MacPermissions.requiredPermissionsAreGranted(
            hasAccessibility: true, hasScreenRecording: true, hasMicrophone: true))
        #expect(!MacPermissions.requiredPermissionsAreGranted(
            hasAccessibility: true, hasScreenRecording: false, hasMicrophone: true))
        #expect(!MacPermissions.requiredPermissionsAreGranted(
            hasAccessibility: false, hasScreenRecording: true, hasMicrophone: true))
        #expect(!MacPermissions.requiredPermissionsAreGranted(
            hasAccessibility: true, hasScreenRecording: true, hasMicrophone: false))
    }

    @Test func privacyDropPrefersApplicationsThenDesktop() {
        #expect(PrivacyDropBundle.plan(isAlreadyInApplications: true, canCopyToApplications: true)
            == .useExistingApplicationsCopy)
        #expect(PrivacyDropBundle.plan(isAlreadyInApplications: false, canCopyToApplications: true)
            == .copyToApplications)
        #expect(PrivacyDropBundle.plan(isAlreadyInApplications: false, canCopyToApplications: false)
            == .copyToDesktop)
    }

    @Test func privacyPasteboardAdvertisesARealFileURL() {
        let fileURL = URL(fileURLWithPath: "/Applications/HeyMate.app")
        let writer = AppBundlePasteboardWriter(fileURL: fileURL)
        #expect(writer.writableTypes(for: NSPasteboard.general) == [.fileURL])
        #expect(writer.pasteboardPropertyList(forType: .fileURL) as? String == fileURL.absoluteString)
        #expect(writer.pasteboardPropertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) == nil)
    }
}
