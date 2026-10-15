import Foundation
import CoreGraphics
import Testing
@testable import HeyMate

@MainActor
struct FloatingAgentNoticeTests {
    private func run(status: AgentRunStatus = .running) -> AgentRun {
        var run = AgentRun.queued(id: UUID(), title: "Private task title", prompt: "Private task prompt",
                                  workspaceURL: URL(fileURLWithPath: "/tmp/private-workspace"),
                                  executor: .codex, origin: .sandbox,
                                  chatOwner: AgentChatOwner(mateID: UUID(), chatID: UUID()))
        run.status = status
        return run
    }
    private func finish(_ run: AgentRun, at: TimeInterval = 100, status: AgentRunStatus = .succeeded) -> AgentRun {
        var run = run
        run.status = status
        run.finishedAt = Date(timeIntervalSince1970: at)
        run.privateFinalResult = "Private answer prose"
        return run
    }

    @Test func startupHistoryAndUnobservedTerminalJobsNeverReplay() {
        let store = FloatingAgentNoticeStore(fileURL: nil)
        let old = finish(run())
        store.start(runs: [old])
        store.observe(runs: [old, finish(run())])
        #expect(store.notices.isEmpty)
    }

    @Test func onlyFreshOwnedSuccessAndFailureCreateUpdates() {
        let store = FloatingAgentNoticeStore(fileURL: nil)
        let success = run()
        let failure = run()
        let cancelled = run()
        var unowned = run()
        unowned.chatOwner = nil
        store.start(runs: [success, failure, cancelled, unowned])
        store.observe(runs: [finish(success), finish(failure, status: .failed),
                             finish(cancelled, status: .cancelled), finish(unowned)])
        #expect(Set(store.notices.map(\.runID)) == Set([success.id, failure.id]))
    }

    @Test func repeatedPublicationsAndDismissalCannotReplaySameResult() throws {
        let store = FloatingAgentNoticeStore(fileURL: nil)
        let active = run()
        let completed = finish(active)
        store.start(runs: [active])
        store.observe(runs: [completed])
        let notice = try #require(store.notices.first)
        store.observe(runs: [completed])
        #expect(store.notices == [notice])
        store.dismiss(id: notice.id)
        store.observe(runs: [completed])
        #expect(store.notices.isEmpty)
    }

    @Test func newAttemptClearsStaleUpdateAndProducesDistinctIdentity() throws {
        let store = FloatingAgentNoticeStore(fileURL: nil)
        let active = run()
        store.start(runs: [active])
        store.observe(runs: [finish(active)])
        let old = try #require(store.notices.first)
        var next = active
        next.detachedAttemptIdentifier = UUID().uuidString
        store.observe(runs: [next])
        #expect(store.notices.isEmpty)
        let result = finish(next, at: 200)
        store.observe(runs: [result])
        let current = try #require(store.notices.first)
        #expect(current.id != old.id)
        #expect(current.matches(result))
        #expect(!old.matches(result))
    }

    @Test func ownerChangesAndDeletedJobsInvalidateUpdates() {
        let store = FloatingAgentNoticeStore(fileURL: nil)
        let active = run()
        store.start(runs: [active])
        var changed = finish(active)
        changed.chatOwner = AgentChatOwner(mateID: UUID(), chatID: UUID())
        store.observe(runs: [changed])
        #expect(store.notices.isEmpty)
        store.start(runs: [active])
        store.observe(runs: [finish(active)])
        #expect(store.notices.count == 1)
        store.observe(runs: [])
        #expect(store.notices.isEmpty)
    }

    @Test func pendingMetadataSurvivesRelaunchAndDismissalWithoutPersistingProse() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notice-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("updates.json")
        let active = run()
        let completed = finish(active)
        let first = FloatingAgentNoticeStore(fileURL: file)
        first.start(runs: [active])
        first.observe(runs: [completed])
        let notice = try #require(first.notices.first)
        let text = try String(contentsOf: file, encoding: .utf8)
        for privateText in [active.title, active.prompt, active.workspacePath, completed.privateFinalResult!] {
            #expect(!text.contains(privateText))
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        let second = FloatingAgentNoticeStore(fileURL: file)
        second.start(runs: [completed])
        #expect(second.notices == [notice])
        second.dismiss(id: notice.id)
        let third = FloatingAgentNoticeStore(fileURL: file)
        third.start(runs: [completed])
        #expect(third.notices.isEmpty)
    }

    @Test func approvalsRemainAheadOfUpdatesAndRunningJobs() throws {
        let approval = run(status: .awaitingPlanApproval)
        let running = run()
        let completed = finish(run())
        let owner = try #require(completed.chatOwner)
        let notice = FloatingAgentNotice(id: UUID(), runID: completed.id, resultKey: completed.resultDeliveryKey,
                                         mateID: owner.mateID, chatID: owner.chatID, createdAt: .distantPast)
        let item = FloatingAgentNoticeItem(notice: notice, run: completed, mateName: "Builder")
        let rows = FloatingAgentPresentation.rows(runs: [running, approval, completed], updates: [item])
        #expect(rows.map(\.id) == ["run:\(approval.id)", "update:\(notice.id)", "run:\(running.id)"])
    }
    @Test func reportFallsBackFromWhitespaceAndRedactsFailureDetails() {
        var failed = run(status: .failed)
        failed.privateFinalResult = " \n "
        failed.error = "Authentication failed: api_key=sk-test-secret"
        let answer = FloatingAgentReportContent.answer(for: failed)
        #expect(answer.contains("Authentication failed"))
        #expect(!answer.contains("sk-test-secret"))
        failed.error = " \n "
        #expect(!FloatingAgentReportContent.answer(for: failed).isEmpty)
        let succeeded = run(status: .succeeded)
        #expect(FloatingAgentReportContent.answer(for: succeeded) == AgentFinalResult.missingMessage)
    }

    @Test func bubbleExpansionKeepsAvatarCenterAndCompactNativeBounds() {
        let screen = CGRect(x: -1440, y: 80, width: 1440, height: 900)
        let compact = FloatingAgentPresentation.bubbleFrame(visibleFrame: screen, index: 1, expanded: false)
        let expanded = FloatingAgentPresentation.bubbleFrame(visibleFrame: screen, index: 1, expanded: true)
        #expect(compact.size == CGSize(width: 56, height: 56))
        #expect(expanded.maxX == compact.maxX)
        #expect(expanded.midY == compact.midY)
        #expect(expanded.minX < compact.minX)
        #expect(screen.contains(expanded))
        #expect(screen.contains(FloatingAgentPresentation.bubbleFrame(visibleFrame: screen, index: 0, expanded: true)))
    }

}
