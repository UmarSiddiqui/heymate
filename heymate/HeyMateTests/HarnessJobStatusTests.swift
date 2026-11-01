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

struct HandoffStatusTests {
    private let mateID = UUID()

    private func handoff(_ instruction: String, mate: UUID? = nil) -> MateHandoff {
        MateHandoff(mateID: mate ?? mateID, mateName: "Ada", instruction: instruction)
    }

    @Test func emptyStatusSaysHandoffsAreSessionOnly() {
        let report = HarnessJobStatus.report(mateName: "Ada", mateID: mateID, runs: [])
        #expect(report.contains("no recorded jobs and no handoffs since HeyMate launched"))
        #expect(report.contains("not kept"))
    }

    @Test func acceptedHandoffIsVisibleButNotStarted() {
        var ledger = HandoffLedger()
        let queued = handoff("Make a scrapbook")
        ledger.queued(queued)
        ledger.queued(handoff("Other mate's task", mate: UUID()))
        let report = HarnessJobStatus.report(mateName: "Ada", mateID: mateID, runs: [],
                                             handoffs: ledger.records(for: mateID))
        #expect(report.contains(queued.id.uuidString))
        #expect(report.contains("— queued"))
        #expect(report.contains("Accepted, not started"))
        #expect(report.contains("no agent runs recorded"))
        #expect(!report.contains("Other mate's task"))
    }

    @Test func lifecycleDistinguishesRunningReportedAndFailed() {
        var ledger = HandoffLedger()
        let first = handoff("First"), second = handoff("Second"), third = handoff("Third")
        for (offset, item) in [first, second, third].enumerated() {
            ledger.queued(item, at: Date(timeIntervalSince1970: Double(offset)))
        }
        ledger.mark(first.id, .running)
        let runID = UUID()
        ledger.mark(second.id, .reported, runIDs: [runID])
        ledger.mark(third.id, .failed, note: "The reply asked for a [WORK: ...] run, which this chat cannot start. Nothing ran.")
        let report = HarnessJobStatus.report(mateName: "Ada", mateID: mateID, runs: [], handoffs: ledger.records(for: mateID))
        #expect(report.contains("— running"))
        #expect(report.contains("— reported"))
        #expect(report.contains("not proof of execution"))
        #expect(report.contains(runID.uuidString))
        #expect(report.contains("— failed"))
        #expect(report.contains("Nothing ran."))
        // Live handoffs list before finished ones.
        let running = try! #require(report.range(of: "— running"))
        let reported = try! #require(report.range(of: "— reported"))
        #expect(running.lowerBound < reported.lowerBound)
    }

    @Test func ledgerIsBoundedAndKeepsLiveHandoffs() {
        var ledger = HandoffLedger()
        let live = handoff("Still waiting")
        ledger.queued(live)
        for index in 0..<HandoffLedger.limit + 5 {
            let done = handoff("Done \(index)")
            ledger.queued(done)
            ledger.mark(done.id, .reported)
        }
        #expect(ledger.records.count == HandoffLedger.limit)
        #expect(ledger.records.contains { $0.id == live.id })
    }
}

struct MateAgentApprovalPolicyTests {
    private func params(_ tool: String, _ args: [String: String]) -> [String: JSONValue] {
        let data = try! JSONSerialization.data(withJSONObject: args)
        return ["title": .string("Allow \(tool)?"), "description": .string(String(decoding: data, as: UTF8.self))]
    }

    @Test func askMeAlwaysShowsTheCard() {
        #expect(!MateAgentApprovalPolicy.autoAllows(params("write", ["path": "output/a.html", "content": "x"]), mode: .askMe))
        #expect(!MateAgentApprovalPolicy.autoAllows(params("bash", ["command": "ls"]), mode: .askMe))
    }

    @Test func fullAccessAllowsOrdinaryFileWorkAndCommands() {
        #expect(MateAgentApprovalPolicy.autoAllows(params("write", ["path": "output/scrapbook.html", "content": "share this page"]), mode: .fullAccess))
        #expect(MateAgentApprovalPolicy.autoAllows(params("edit", ["path": "/Users/me/site/index.html"]), mode: .fullAccess))
        #expect(MateAgentApprovalPolicy.autoAllows(params("bash", ["command": "sips -Z 1200 photo.jpg --out output/photo.jpg"]), mode: .fullAccess))
    }

    @Test func fullAccessKeepsTheFloor() {
        for command in ["rm -rf output", "git push origin main", "curl -X POST https://example.com", "sudo ls",
                        "osascript -e 'tell app \"Mail\"'", "echo $API_TOKEN", "git reset --hard"] {
            #expect(!MateAgentApprovalPolicy.autoAllows(params("bash", ["command": command]), mode: .fullAccess), "\(command)")
        }
        #expect(!MateAgentApprovalPolicy.autoAllows(params("write", ["path": "secrets/key.txt"]), mode: .fullAccess))
        #expect(!MateAgentApprovalPolicy.autoAllows(params("connector_send", ["to": "a"]), mode: .fullAccess))
        // Truncated or unreadable details are not guessed at.
        #expect(!MateAgentApprovalPolicy.autoAllows(["title": .string("Allow bash?"), "description": .string("{\"command\":\"ls")], mode: .fullAccess))
    }

    @Test func structuredToolNameWinsOverTitle() {
        var request = params("write", ["path": "output/a.txt"])
        request["tool"] = .string("bash")
        #expect(MateAgentApprovalPolicy.toolName(request) == "bash")
        #expect(!MateAgentApprovalPolicy.autoAllows(request, mode: .fullAccess))
    }

    @Test func expiredCardsStayVisibleInTheChat() {
        let expired = MateAgentActivityEntry(type: "request.expired", payload: .object(["title": .string("Allow bash?")]))
        #expect(expired.persistsAfterTurn)
        #expect(expired.text.contains("expired"))
        #expect(expired.text.contains("nothing ran"))
    }
}
