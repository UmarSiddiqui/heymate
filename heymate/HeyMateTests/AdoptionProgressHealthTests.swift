import Foundation
import Testing
@testable import HeyMate

struct AdoptionProgressHealthTests {
    private func run(at date: Date) -> AgentRun {
        var run = AgentRun.queued(id: UUID(), title: "Fixture", prompt: "Fixture",
                                  workspaceURL: URL(fileURLWithPath: "/tmp/unused-health-fixture"),
                                  executor: .codex, origin: .attached)
        run.status = .running
        run.startedAt = date
        run.progressObservationStartedAt = date
        run.detachedAttemptIdentifier = UUID().uuidString
        return run
    }

    @Test func recentToolProgressAndApprovalDoNotWarn() {
        let now = Date(timeIntervalSince1970: 10_000)
        var fixture = run(at: now.addingTimeInterval(-500))
        #expect(!AgentProgressHealth.summary(for: fixture, now: now).isEmpty)
        fixture.lastToolProgressAt = now.addingTimeInterval(-5)
        #expect(AgentProgressHealth.summary(for: fixture, now: now).isEmpty)
        fixture.lastToolProgressAt = nil
        fixture.status = .waitingForApproval
        #expect(AgentProgressHealth.summary(for: fixture, now: now).isEmpty)
    }

    @Test func heartbeatSnapshotDoesNotMasqueradeAsToolProgress() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let fixture = run(at: now.addingTimeInterval(-500))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try DetachedAgentRuntimeJournal(rootDirectoryURL: root, runID: fixture.id,
                                                       attemptID: fixture.detachedAttemptID!)
        let toolAt = now.addingTimeInterval(-400)
        let record = try journal.append(DetachedAgentEventEnvelope(runID: fixture.id,
                                      attemptID: fixture.detachedAttemptID!, emittedAt: toolAt,
                                      event: .progress("Reading fixture")))
        let state = DetachedAgentDurableState(runID: fixture.id, attemptID: fixture.detachedAttemptID!,
                                             leg: .execute, phase: .running, updatedAt: now,
                                             lastJournalSequence: record.sequence, lastHeartbeatAt: now)
        let reduced = try DetachedAgentRunReducer.reduce(run: fixture, state: state, journal: [record])
        #expect(reduced.lastToolProgressAt == toolAt)
        #expect(!AgentProgressHealth.summary(for: reduced, now: now).isEmpty)
        #expect(reduced.status == .running)
    }

    @Test func olderRunsDecodeWithoutProgressDates() throws {
        let fixture = run(at: Date())
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture)) as! [String: Any]
        object.removeValue(forKey: "lastToolProgressAt")
        object.removeValue(forKey: "progressObservationStartedAt")
        let restored = try JSONDecoder().decode(AgentRun.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.id == fixture.id)
        #expect(restored.lastToolProgressAt == nil)
        #expect(restored.progressObservationStartedAt == nil)
    }
}
