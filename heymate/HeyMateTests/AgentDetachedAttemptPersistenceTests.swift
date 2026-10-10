//
//  AgentDetachedAttemptPersistenceTests.swift
//  HeyMateTests
//

import Foundation
import Testing
@testable import HeyMate

struct AgentDetachedAttemptPersistenceTests {
    @Test func detachedAttemptRoundTripsAndOldRecordsDefaultSafely() throws {
        let workspaceURL = URL(fileURLWithPath: "/tmp/heymate-detached-test", isDirectory: true)
        var run = AgentRun.queued(
            id: UUID(),
            title: "Detached",
            prompt: "Work",
            workspaceURL: workspaceURL,
            executor: .codex,
            origin: .attached,
            sessionIdentifier: "session"
        )
        let attemptID = UUID()
        run.detachedAttemptIdentifier = attemptID.uuidString
        run.lastDetachedJournalSequence = 42

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AgentRun.self, from: encoder.encode(run))
        #expect(decoded.detachedAttemptID == attemptID)
        #expect(decoded.lastDetachedJournalSequence == 42)

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(run)) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "detachedAttemptIdentifier")
        legacyObject.removeValue(forKey: "lastDetachedJournalSequence")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyDecoded = try decoder.decode(AgentRun.self, from: legacyData)
        #expect(legacyDecoded.detachedAttemptID == nil)
        #expect(legacyDecoded.lastDetachedJournalSequence == 0)
    }
}
