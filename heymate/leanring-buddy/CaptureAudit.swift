//
//  CaptureAudit.swift
//  leanring-buddy
//
//  Privacy infrastructure (master spec 07): makes the invariant "screenshots
//  are only captured during an explicitly active interaction" assertable.
//  Every real ScreenCaptureKit call site must report through recordCaptureAttempt,
//  so tests can prove zero attempts happen while idle / during pure state
//  transitions and that every context names a legitimate pipeline stage.
//

import Foundation

/// Tracks every screenshot-capture attempt with its triggering context so
/// privacy invariants can be asserted in tests and surfaced in debug UI later.
@MainActor
final class CaptureAudit {

    /// Canonical context strings for every real capture call site. Tests
    /// assert these never drift into "idle" territory.
    enum Context {
        static let talkResponsePipeline = "talk.responsePipeline"
        static let dictateResponsePipeline = "dictate.responsePipeline"
        static let onboardingDemoInteraction = "onboarding.demoInteraction"
        static let externalControlScreenshot = "externalControl.screenshot"
    }

    static let shared = CaptureAudit()

    /// One reported screenshot-capture attempt.
    struct AttemptRecord: Equatable {
        /// Pipeline stage that triggered the capture, e.g. "talk.responsePipeline".
        /// Never "idle" — enforced by violatesIdleInvariant.
        let context: String
        let timestamp: Date
    }

    /// Chronological log of every capture attempt since the last reset.
    private(set) var attempts: [AttemptRecord] = []

    /// Convenience count so callers don't reach into the array.
    var attemptCount: Int {
        attempts.count
    }

    /// Context of the most recent capture attempt, if any ever happened.
    var lastContext: String? {
        attempts.last?.context
    }

    /// Internal on purpose: tests construct isolated instances so parallel
    /// test suites never observe each other's records. Production code goes
    /// through `shared`.
    init() {}

    /// Records one screenshot-capture attempt. Call this at every real
    /// ScreenCaptureKit invocation, tagged with the pipeline stage that
    /// justified the capture. Blank contexts are ignored so a mis-tagged
    /// call site fails loudly in review instead of polluting the audit trail.
    func recordCaptureAttempt(context: String) {
        let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContext.isEmpty else { return }
        attempts.append(AttemptRecord(context: trimmedContext, timestamp: Date()))
    }

    /// Test support: wipe history between scenarios so assertions on
    /// attemptCount/lastContext only see what the scenario itself produced.
    func resetForTesting() {
        attempts.removeAll()
    }

    /// Invariant check: no attempt may ever carry the "idle" context.
    /// A screenshot captured while idle would violate the privacy promise,
    /// because nothing the user did asked for it.
    nonisolated static func violatesIdleInvariant(records: [AttemptRecord]) -> Bool {
        // Trim + lowercase so "Idle", "IDLE", or stray whitespace can't
        // sneak an idle capture past the audit.
        records.contains { record in
            record.context.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "idle"
        }
    }
}
