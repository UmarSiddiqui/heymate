//
//  PrivacyInvariantsTests.swift
//  leanring-buddyTests
//
//  End-to-end privacy invariant assertions (master spec "Privacy invariants"):
//  - no screenshot capture happens while idle (manager at rest + pure state
//    cycling must record zero capture attempts);
//  - every real capture context is a legitimate pipeline stage;
//  - excluded-app policy gates resolve correctly for the running host.
//

import AppKit
import Testing
@testable import HeyMate

@MainActor
struct PrivacyInvariantsTests {

    // MARK: - No capture while idle

    @Test func managerAtRestPerformsZeroCaptureAttempts() {
        CaptureAudit.shared.resetForTesting()

        // Constructing the companion (status item, monitors lazy, pipelines
        // dormant) must not touch ScreenCaptureKit.
        _ = CompanionManager()

        #expect(CaptureAudit.shared.attemptCount == 0)
        #expect(!CaptureAudit.violatesIdleInvariant(records: CaptureAudit.shared.attempts))
    }

    @Test func annotationLifecycleRecordsNoCaptures() {
        CaptureAudit.shared.resetForTesting()
        let manager = CompanionManager()
        defer { CaptureAudit.shared.resetForTesting() }

        let screens = [
            VisualActionResolver.ScreenGeometryInfo(
                id: "screen1",
                frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
                isCursorScreen: true
            )
        ]
        let circle = VisualAction(
            type: .circle, screenId: nil, x: nil, y: nil,
            points: nil, center: [0.5, 0.5], radius: [0.1, 0.1], rect: nil, label: nil, ttlMs: nil
        )

        manager.applyVisualActions([circle], screenCaptures: [])
        manager.clearAnnotations()

        #expect(CaptureAudit.shared.attemptCount == 0)
    }

    // MARK: - Real capture contexts are never idle

    @Test func everyRealCaptureContextSatisfiesIdleInvariant() {
        let realContexts = [
            CaptureAudit.Context.talkResponsePipeline,
            CaptureAudit.Context.dictateResponsePipeline,
            CaptureAudit.Context.onboardingDemoInteraction,
            CaptureAudit.Context.externalControlScreenshot
        ]

        let records = realContexts.map {
            CaptureAudit.AttemptRecord(context: $0, timestamp: Date())
        }

        #expect(!realContexts.isEmpty)          // guard against silent constant removal
        #expect(!CaptureAudit.violatesIdleInvariant(records: records))
    }

    // MARK: - Exclusion policy integration surface

    @Test func publishedExclusionsMirrorPolicyList() {
        let manager = CompanionManager()
        // Structural mirror check (not exact equality — parallel suites may
        // hold their own exclusions in the shared defaults).
        #expect(manager.excludedAppBundleIds == manager.excludedAppBundleIds.sorted())
        for defaultId in ExcludedApps.defaultExcludedBundleIds {
            #expect(manager.excludedAppBundleIds.contains(defaultId))
        }
    }

    @Test func addRemoveUserExclusionRefreshesPublishedList() {
        let manager = CompanionManager()
        let probeId = "com.privacytests.probe"
        defer { ExcludedApps.removeUserExclusion(probeId) }

        #expect(!manager.excludedAppBundleIds.contains(probeId))
        manager.addUserAppExclusion("  \(probeId.uppercased()) ")
        #expect(manager.excludedAppBundleIds.contains(probeId))

        manager.removeUserAppExclusion(probeId)
        #expect(!manager.excludedAppBundleIds.contains(probeId))
    }

    @Test func frontmostHostAppIsNotExcludedByDefault() {
        // The test host itself (HeyMate dev build) is unknown to the default
        // list — fail-open usability contract for unlisted apps.
        let hostBundleId = Bundle.main.bundleIdentifier
        #expect(!ExcludedApps.isCurrentlyExcluded(bundleId: hostBundleId))
    }
}
