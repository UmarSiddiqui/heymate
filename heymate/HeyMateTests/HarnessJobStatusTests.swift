import Foundation
import Testing
@testable import HeyMate

struct HarnessJobStatusTests {
    private let mateID = UUID()

    private func run(status: AgentRunStatus, date: TimeInterval = 0, owner: UUID? = nil) -> AgentRun {
        var run = AgentRun.queued(
            id: UUID(), title: "Job \(date)", prompt: "Private original task",
            workspaceURL: URL(fileURLWithPath: "/tmp/private-workspace"),
            executor: .codex, origin: .sandbox,
            createdAt: Date(timeIntervalSince1970: date),
            chatOwner: AgentChatOwner(mateID: owner ?? mateID, chatID: UUID())
        )
        run.status = status
        return run
    }

    @Test func reportsOnlySelectedMateWithoutClaimingVerification() {
        var completed = run(status: .succeeded)
        completed.privateFinalResult = "Created report.md; checked its totals."
        var other = run(status: .failed, owner: UUID())
        other.error = "OTHER_MATE_PRIVATE_ERROR"
        let report = HarnessJobStatus.report(mateName: "Ada", mateID: mateID, runs: [other, completed])
        #expect(report.contains(completed.id.uuidString))
        #expect(report.contains("Created report.md"))
        #expect(report.contains("evidence review"))
        #expect(!report.contains("OTHER_MATE_PRIVATE_ERROR"))
        #expect(!report.contains("Private original task"))
        #expect(!report.contains("/tmp/private-workspace"))
    }

    @Test func keepsOldLiveJobVisibleAheadOfTerminalHistoryAndReportsApproval() {
        var pending = run(status: .awaitingPlanApproval, date: 1)
        pending.planText = "Add export command."
        let history = (2...10).map { run(status: .succeeded, date: Double($0)) }
        let report = HarnessJobStatus.report(mateName: "Ada", mateID: mateID, runs: history + [pending])
        #expect(report.contains(pending.id.uuidString))
        #expect(report.contains("user must review and approve"))
        #expect(report.contains("Add export command."))
        #expect(report.contains("4 more recorded jobs omitted"))
    }

    @Test func failedMissingAndCancelledOutcomesStayHonest() {
        var failed = run(status: .failed)
        failed.error = "Build failed"
        let report = HarnessJobStatus.report(mateName: "Ada", mateID: mateID, runs: [
            failed, run(status: .succeeded), run(status: .cancelled)
        ])
        #expect(report.contains("Build failed"))
        #expect(report.contains(AgentFinalResult.missingMessage))
        #expect(report.contains("task completion is not established"))
    }

    @Test func finalAnswersAreBounded() {
        var completed = run(status: .succeeded)
        completed.privateFinalResult = String(repeating: "x", count: 8_000)
        let report = HarnessJobStatus.report(mateName: "Ada", mateID: mateID, runs: [completed])
        #expect(report.contains("[truncated]"))
        #expect(report.count < 7_000)
    }
}
