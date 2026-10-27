import Foundation
import CoreGraphics
import Testing
@testable import HeyMate

/// The one line a floating job bubble shows: plan while waiting, latest
/// step while working, the answer when done.
@MainActor
struct FloatingAgentDetailTests {
    private func run(status: AgentRunStatus) -> AgentRun {
        var run = AgentRun.queued(id: UUID(), title: "Invoices", prompt: "Find invoices",
                                  workspaceURL: URL(fileURLWithPath: "/tmp/detail-workspace"),
                                  executor: .codex, origin: .sandbox,
                                  chatOwner: AgentChatOwner(mateID: UUID(), chatID: UUID()))
        run.status = status
        return run
    }

    @Test func planWaitingForApprovalSkipsHeadingsToItsFirstStep() {
        var run = run(status: .awaitingPlanApproval)
        run.planText = "## Plan\n\n1. Search Gmail for invoices from October\n2. Make a sheet"
        #expect(FloatingAgentPresentation.detail(for: run) == "Search Gmail for invoices from October")
    }

    @Test func workingShowsTheLatestProgress() {
        var run = run(status: .running)
        run.activity = []
        run.latestAction = "Starting"
        #expect(FloatingAgentPresentation.detail(for: run) == "Starting")
        run.activity = [
            AgentActivityEntry(kind: .progress, text: "Reading inbox"),
            AgentActivityEntry(kind: .agent, text: "private chatter"),
            AgentActivityEntry(kind: .progress, text: "Found 3 invoices in v1.2 folder"),
        ]
        #expect(FloatingAgentPresentation.detail(for: run) == "Found 3 invoices in v1.2 folder")
    }

    @Test func doneShowsTheAnswerAndFailureShowsTheError() {
        var done = run(status: .succeeded)
        done.privateFinalResult = "- Three invoices, total $1,240.\nDetails follow."
        #expect(FloatingAgentPresentation.detail(for: done) == "Three invoices, total $1,240.")

        var failed = run(status: .failed)
        failed.error = "Gmail is not connected."
        #expect(FloatingAgentPresentation.detail(for: failed) == "Gmail is not connected.")

        #expect(FloatingAgentPresentation.detail(for: run(status: .cancelled)) == nil)
    }

    @Test func longLinesAreCappedAndEmptyTextIsNil() {
        let long = String(repeating: "word ", count: 60)
        let line = FloatingAgentPresentation.firstMeaningfulLine(long)
        #expect(line?.count == 160)
        #expect(line?.hasSuffix("…") == true)
        #expect(FloatingAgentPresentation.firstMeaningfulLine("\n---\n  \n") == nil)
    }

    @Test func replyingMakesRoomForTheTextField() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let collapsed = FloatingAgentPresentation.bubbleFrame(visibleFrame: visible, index: 0, expanded: false)
        let expanded = FloatingAgentPresentation.bubbleFrame(visibleFrame: visible, index: 0, expanded: true)
        let replying = FloatingAgentPresentation.bubbleFrame(visibleFrame: visible, index: 0, expanded: true, replying: true)
        #expect(collapsed.height < expanded.height)
        #expect(expanded.height < replying.height)
        #expect(expanded.maxX == replying.maxX)
    }
}
