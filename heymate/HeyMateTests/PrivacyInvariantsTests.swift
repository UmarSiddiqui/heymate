//
//  PrivacyInvariantsTests.swift
//  HeyMateTests
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

    // MARK: - Screen-derived telemetry

    @Test func pointingTelemetryDiscardsLabelsAndCommentary() throws {
        let privateLabel = "Quarterly payroll approval"
        let privateCommentary = "that total looks unexpectedly high"
        let summary = ScreenPointingTelemetrySummary(
            coordinate: CGPoint(x: 431.9, y: 207.4),
            elementLabel: privateLabel,
            commentary: privateCommentary
        )

        #expect(summary.x == 431)
        #expect(summary.y == 207)
        #expect(summary.labelCharacterCount == privateLabel.count)
        #expect(summary.commentaryCharacterCount == privateCommentary.count)
        #expect(summary.analyticsProperties["x"] as? Int == 431)
        #expect(summary.analyticsProperties["y"] as? Int == 207)
        #expect(
            summary.analyticsProperties["label_character_count"] as? Int
                == privateLabel.count
        )
        #expect(summary.analyticsProperties["element_label"] == nil)

        let encodedProperties = try JSONSerialization.data(
            withJSONObject: summary.analyticsProperties,
            options: [.sortedKeys]
        )
        let encodedText = String(decoding: encodedProperties, as: UTF8.self)
        #expect(!encodedText.contains(privateLabel))
        #expect(!encodedText.contains(privateCommentary))
    }

    @Test func analyticsErrorTelemetryDropsDescriptionsAndBoundsMetadata() throws {
        let privateDescription = "upstream body: customer payroll row 17"
        let error = NSError(
            domain: "upstream response contained \(privateDescription)",
            code: 502,
            userInfo: [NSLocalizedDescriptionKey: privateDescription]
        )
        let summary = AnalyticsErrorSummary(
            category: .responsePipeline,
            error: error
        )

        #expect(summary.category == .responsePipeline)
        #expect(summary.domain == "other")
        #expect(summary.code == 502)
        #expect(summary.analyticsProperties["category"] as? String == "response_pipeline")
        #expect(summary.analyticsProperties["error_domain"] as? String == "other")
        #expect(summary.analyticsProperties["error_code"] as? Int == 502)
        #expect(summary.analyticsProperties["error"] == nil)
        #expect(summary.analyticsProperties["description"] == nil)

        let encodedProperties = try JSONSerialization.data(
            withJSONObject: summary.analyticsProperties,
            options: [.sortedKeys]
        )
        let encodedText = String(decoding: encodedProperties, as: UTF8.self)
        #expect(!encodedText.contains(privateDescription))

        let longDomain = String(repeating: "com.example.provider.", count: 8)
        let bounded = AnalyticsErrorSummary(
            category: .textToSpeech,
            error: NSError(domain: longDomain, code: -1)
        )
        #expect(bounded.domain.count == 80)
        #expect(longDomain.hasPrefix(bounded.domain))
    }
}
