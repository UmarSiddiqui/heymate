import Foundation
import Testing
@testable import HeyMate

@MainActor
struct MateDigestTests {
    private let defaultID = UUID()

    private func mate(_ name: String, unread: Int = 0, archived: Bool = false, folder: String? = nil) -> Mate {
        Mate(
            id: UUID(), name: name, job: "Job", pinned: false, archived: archived,
            unreadCount: unread, createdAt: Date(), updatedAt: Date(), memoryNote: "", folderPath: folder
        )
    }

    private func run(_ title: String, status: AgentRunStatus, path: String = "/tmp/heymate-digest-none") -> AgentRun {
        var run = AgentRun.queued(
            id: UUID(), title: title, prompt: title,
            workspaceURL: URL(fileURLWithPath: path, isDirectory: true),
            executor: .openCode, origin: .sandbox, createdAt: Date()
        )
        run.status = status
        return run
    }

    private func routine(for mate: Mate, pausedReason: String?, status: String? = nil) -> MateRoutine {
        var routine = MateRoutine.scheduled(
            mateID: mate.id, task: "Write the brief", schedule: .everyHours(3), now: Date(), calendar: .current
        )
        routine.pausedReason = pausedReason
        routine.lastStatusMessage = status
        return routine
    }

    private func digest(
        _ mates: [Mate], routines: [MateRoutine] = [], runs: [AgentRun] = [],
        owners: [UUID: UUID] = [:], sessions: [ChatSession] = [], active: UUID? = nil
    ) -> (items: [MateDigestItem], hiddenCount: Int) {
        MateDigest.make(
            mates: mates, routines: routines, runs: runs, owners: owners,
            sessions: sessions, defaultMateID: defaultID, activeMateID: active
        )
    }

    @Test func aQuietRosterShowsNothing() {
        let ivy = mate("Ivy")
        let done = run("Tidy files", status: .succeeded)
        #expect(digest([ivy], runs: [done], owners: [done.id: ivy.id]).items.isEmpty)
    }

    @Test func waitingJobsComeFirstThenStoppedRoutinesThenUnread() {
        let reader = mate("Reader", unread: 2)
        let brief = mate("Brief")
        let clerk = mate("Clerk")
        let plan = run("Merge the PDFs", status: .awaitingPlanApproval)
        let step = run("Rename scans", status: .waitingForApproval)
        var chat = ChatSession.empty()
        chat.mateID = reader.id
        chat.messages = [ChatMessage(id: UUID(), role: .assistant, text: "Drafted **6 replies**.", createdAt: Date())]

        let result = digest(
            [reader, brief, clerk],
            routines: [routine(for: brief, pausedReason: "Paused after 3 failed runs.", status: "Could not reach Mail")],
            runs: [plan, step],
            owners: [plan.id: clerk.id, step.id: clerk.id],
            sessions: [chat]
        )
        #expect(result.items.map(\.kind) == [.needsOK, .routineStopped, .unread])
        #expect(result.items.map(\.mateName) == ["Clerk", "Brief", "Reader"])
        #expect(result.items[0].detail.hasSuffix("and 1 more"))
        #expect(result.items[1].detail == "Could not reach Mail")
        #expect(result.items[2].detail == "Drafted 6 replies.")
        #expect(result.hiddenCount == 0)
    }

    @Test func pausesThePersonChoseAreNotNews() {
        let brief = mate("Brief")
        let gone = mate("Gone", unread: 3, archived: true)
        let result = digest(
            [brief, gone],
            routines: [
                routine(for: brief, pausedReason: MateRoutineAccounting.manualPauseReason),
                routine(for: gone, pausedReason: MateRoutineAccounting.archivedPauseReason)
            ]
        )
        #expect(result.items.isEmpty)
    }

    @Test func theOpenChatIsNotUnreadAndEachAgentGetsOneLine() {
        let reader = mate("Reader", unread: 1)
        let clerk = mate("Clerk", unread: 4)
        let plan = run("Merge the PDFs", status: .awaitingPlanApproval)
        let result = digest([reader, clerk], runs: [plan], owners: [plan.id: clerk.id], active: reader.id)
        #expect(result.items.map(\.id) == ["needsOK-\(clerk.id.uuidString)"])
    }

    @Test func thePeekListsWaitingAgentsBeforeNewerChats() {
        let quiet = mate("Quiet")
        let clerk = mate("Clerk")
        var chat = ChatSession.empty()
        chat.mateID = quiet.id
        chat.messages = [ChatMessage(id: UUID(), role: .assistant, text: "Newest", createdAt: Date().addingTimeInterval(60))]
        let plain = NotchMatesPeekOrder.mates([clerk, quiet], sessions: [chat], defaultMateID: defaultID)
        #expect(plain.map(\.mate.name) == ["Quiet", "Clerk"])
        let waiting = NotchMatesPeekOrder.mates(
            [clerk, quiet], sessions: [chat], defaultMateID: defaultID, waitingFirst: [clerk.id]
        )
        #expect(waiting.map(\.mate.name) == ["Clerk", "Quiet"])
    }

    @Test func theRailCanLeaveUnreadToTheRowDots() {
        let reader = mate("Reader", unread: 2)
        let clerk = mate("Clerk", unread: 1)
        let plan = run("Merge the PDFs", status: .awaitingPlanApproval)
        let result = MateDigest.make(
            mates: [reader, clerk], routines: [], runs: [plan], owners: [plan.id: clerk.id],
            sessions: [], defaultMateID: defaultID, activeMateID: nil, includesUnread: false
        )
        #expect(result.items.map(\.kind) == [.needsOK])
        #expect(result.hiddenCount == 0)
    }

    @Test func extraAgentsAreCountedNotShown() {
        let mates = (1...6).map { mate("Agent \($0)", unread: 1) }
        let result = digest(mates)
        #expect(result.items.count == MateDigest.maxItems)
        #expect(result.hiddenCount == 2)
    }
}
