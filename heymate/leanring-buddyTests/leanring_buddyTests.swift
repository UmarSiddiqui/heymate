//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import AppKit
import Testing
@testable import HeyMate

@MainActor
struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func successfulScreenRecordingPromptIsRememberedEvenIfPreflightLags() {
        #expect(
            WindowPositionManager.shouldPersistScreenRecordingGrant(
                preflightGranted: false,
                systemPromptReturnedGranted: true
            )
        )
        #expect(
            !WindowPositionManager.shouldPersistScreenRecordingGrant(
                preflightGranted: false,
                systemPromptReturnedGranted: false
            )
        )
        #expect(
            WindowPositionManager.shouldPersistScreenRecordingGrant(
                preflightGranted: true,
                systemPromptReturnedGranted: false
            )
        )
    }

    @Test func setupGateDoesNotRequireTheScreenContentPicker() {
        #expect(
            WindowPositionManager.requiredPermissionsAreGranted(
                hasAccessibility: true,
                hasScreenRecording: true,
                hasMicrophone: true
            )
        )
        #expect(
            !WindowPositionManager.requiredPermissionsAreGranted(
                hasAccessibility: true,
                hasScreenRecording: false,
                hasMicrophone: true
            )
        )
    }

    @Test func privacyDropPrefersExistingApplicationsCopy() {
        #expect(
            WindowPositionManager.privacyDropPlan(
                isAlreadyInApplications: true,
                canCopyToApplications: true
            ) == .useExistingApplicationsCopy
        )
    }

    @Test func privacyDropCopiesToApplicationsWhenMissing() {
        #expect(
            WindowPositionManager.privacyDropPlan(
                isAlreadyInApplications: false,
                canCopyToApplications: true
            ) == .copyToApplications
        )
    }

    @Test func privacyDropFallsBackToDesktopWhenApplicationsIsNotWritable() {
        #expect(
            WindowPositionManager.privacyDropPlan(
                isAlreadyInApplications: false,
                canCopyToApplications: false
            ) == .copyToDesktop
        )
    }

    @Test func privacyPasteboardAdvertisesARealFileURL() {
        let fileURL = URL(fileURLWithPath: "/Applications/HeyMate.app")
        let writer = AppBundlePasteboardWriter(fileURL: fileURL)
        let types = writer.writableTypes(for: NSPasteboard.general)
        #expect(types == [.fileURL])
        #expect(writer.pasteboardPropertyList(forType: .fileURL) as? String == fileURL.absoluteString)
        #expect(
            writer.pasteboardPropertyList(
                forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
            ) == nil
        )
    }
}
