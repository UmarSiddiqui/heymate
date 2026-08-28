//
//  CaptureAuditTests.swift
//  leanring-buddyTests
//
//  Tests for the privacy audit trail: recording bookkeeping, blank-context
//  rejection, reset semantics, and the core invariant that no capture
//  attempt may ever carry an "idle" context.
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct CaptureAuditTests {

    /// Fresh instance per test: fully isolated from other suites running in
    /// parallel (the shared singleton is reserved for production call sites).
    private func makeAudit() -> CaptureAudit {
        CaptureAudit()
    }

    // MARK: - Recording

    @Test func recordCaptureAttemptIncrementsCountAndSetsLastContext() {
        let audit = makeAudit()

        #expect(audit.attemptCount == 0)
        #expect(audit.lastContext == nil)

        audit.recordCaptureAttempt(context: "talk.responsePipeline")

        #expect(audit.attemptCount == 1)
        #expect(audit.lastContext == "talk.responsePipeline")
    }

    @Test func multipleAttemptsPreserveChronologicalOrder() {
        let audit = makeAudit()

        audit.recordCaptureAttempt(context: "talk.responsePipeline")
        audit.recordCaptureAttempt(context: "dictate.responsePipeline")
        audit.recordCaptureAttempt(context: "spatial.pointing")

        #expect(audit.attemptCount == 3)
        #expect(audit.attempts.map(\.context) == ["talk.responsePipeline", "dictate.responsePipeline", "spatial.pointing"])
        #expect(audit.lastContext == "spatial.pointing")
    }

    @Test func recordedAttemptStampsTimestamp() {
        let audit = makeAudit()

        let beforeRecording = Date()
        audit.recordCaptureAttempt(context: "talk.responsePipeline")

        guard let record = audit.attempts.first else {
            Issue.record("Expected exactly one attempt after recording")
            return
        }
        #expect(record.timestamp >= beforeRecording)
    }

    // MARK: - Blank context rejection

    @Test func emptyAndWhitespaceContextsAreIgnored() {
        let audit = makeAudit()

        audit.recordCaptureAttempt(context: "")
        audit.recordCaptureAttempt(context: "   ")
        audit.recordCaptureAttempt(context: "\n\t")

        #expect(audit.attemptCount == 0)
        #expect(audit.lastContext == nil)
        #expect(audit.attempts.isEmpty)
    }

    @Test func surroundingWhitespaceIsTrimmedFromStoredContext() {
        let audit = makeAudit()

        audit.recordCaptureAttempt(context: "  talk.responsePipeline  ")

        #expect(audit.lastContext == "talk.responsePipeline")
    }

    // MARK: - Reset semantics

    @Test func resetForTestingClearsAllHistory() {
        let audit = makeAudit()

        audit.recordCaptureAttempt(context: "talk.responsePipeline")
        audit.recordCaptureAttempt(context: "spatial.pointing")
        #expect(audit.attemptCount == 2)

        audit.resetForTesting()

        #expect(audit.attemptCount == 0)
        #expect(audit.lastContext == nil)
        #expect(audit.attempts.isEmpty)
    }

    // MARK: - Idle invariant

    private static let legitimatePipelineContexts = [
        "talk.responsePipeline",
        "dictate.responsePipeline",
        "spatial.pointing"
    ]

    @Test func idleInvariantPassesWithNoRecords() {
        #expect(!CaptureAudit.violatesIdleInvariant(records: []))
    }

    @Test func idleInvariantPassesForLegitimatePipelineContextsOnly() {
        let legitimateRecords = Self.legitimatePipelineContexts.map { context in
            CaptureAudit.AttemptRecord(context: context, timestamp: Date())
        }
        #expect(!CaptureAudit.violatesIdleInvariant(records: legitimateRecords))
    }

    @Test func idleInvariantFailsWhenAnyRecordIsIdleRegardlessOfCaseOrWhitespace() {
        for idleSpelling in ["idle", "Idle", "IDLE", "  idle  "] {
            let records = [
                CaptureAudit.AttemptRecord(context: "talk.responsePipeline", timestamp: Date()),
                CaptureAudit.AttemptRecord(context: idleSpelling, timestamp: Date())
            ]
            #expect(CaptureAudit.violatesIdleInvariant(records: records), "Failed to flag: \(idleSpelling)")
        }
    }

    @Test func idleInvariantFailsWhenIdleIsTheOnlyRecord() {
        let records = [CaptureAudit.AttemptRecord(context: "idle", timestamp: Date())]
        #expect(CaptureAudit.violatesIdleInvariant(records: records))
    }
}
