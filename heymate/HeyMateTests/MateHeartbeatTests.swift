import Foundation
import Testing
@testable import HeyMate

struct MateHeartbeatScheduleTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func nothingBeforeSevenOrAtNight() {
        #expect(!MateHeartbeatSchedule.isDue(now: at(16, 6, 59), lastRunAt: nil, backedOff: false, userActive: true, calendar: calendar))
        #expect(!MateHeartbeatSchedule.isDue(now: at(16, 21, 30), lastRunAt: at(15, 9), backedOff: false, userActive: true, calendar: calendar))
    }

    @Test func firstActivityAfterSevenRunsOnceThenWaitsForAfternoon() {
        #expect(MateHeartbeatSchedule.isDue(now: at(16, 8), lastRunAt: at(15, 15), backedOff: false, userActive: true, calendar: calendar))
        #expect(!MateHeartbeatSchedule.isDue(now: at(16, 8), lastRunAt: at(15, 15), backedOff: false, userActive: false, calendar: calendar))
        #expect(!MateHeartbeatSchedule.isDue(now: at(16, 11), lastRunAt: at(16, 8), backedOff: false, userActive: true, calendar: calendar))
        #expect(MateHeartbeatSchedule.isDue(now: at(16, 14, 5), lastRunAt: at(16, 8), backedOff: false, userActive: true, calendar: calendar))
    }

    @Test func missedDaysCollapseToOneAndAfternoonNeedsAGap() {
        // A week away: one run now, then nothing until the next slot.
        #expect(MateHeartbeatSchedule.isDue(now: at(16, 15), lastRunAt: at(9, 8), backedOff: false, userActive: true, calendar: calendar))
        #expect(!MateHeartbeatSchedule.isDue(now: at(16, 16), lastRunAt: at(16, 15), backedOff: false, userActive: true, calendar: calendar))
        // A late morning run does not double up at 14:00.
        #expect(!MateHeartbeatSchedule.isDue(now: at(16, 14, 1), lastRunAt: at(16, 13, 50), backedOff: false, userActive: true, calendar: calendar))
    }

    @Test func backedOffMateWaitsThreeDays() {
        #expect(!MateHeartbeatSchedule.isDue(now: at(17, 8), lastRunAt: at(16, 8), backedOff: true, userActive: true, calendar: calendar))
        #expect(MateHeartbeatSchedule.isDue(now: at(19, 8), lastRunAt: at(16, 8), backedOff: true, userActive: true, calendar: calendar))
    }
}

struct MateHeartbeatFatigueTests {
    private func record(_ title: String, _ outcome: MateHeartbeatRecord.Outcome, daysAgo: Double, now: Date) -> MateHeartbeatRecord {
        let at = now.addingTimeInterval(-daysAgo * 86_400)
        return MateHeartbeatRecord(id: UUID(), title: title, createdAt: at, outcome: outcome, resolvedAt: at)
    }

    @Test func titleSkippedTwiceIsSuppressedForThirtyDays() {
        let now = Date()
        let records = [record("Draft the weekly report", .skipped, daysAgo: 5, now: now),
                       record("draft the weekly report!", .skipped, daysAgo: 2, now: now),
                       record("Tidy the folder", .skipped, daysAgo: 1, now: now)]
        #expect(MateHeartbeatFatigue.suppressedTitles(records, now: now) == ["draft the weekly report!"])
        #expect(MateHeartbeatFatigue.suppressedTitles(records, now: now.addingTimeInterval(31 * 86_400)).isEmpty)
    }

    @Test func fiveIgnoredProposalsBackOffUntilOneIsApproved() {
        let now = Date()
        var records = (0..<5).map { record("Idea \($0)", $0.isMultiple(of: 2) ? .skipped : .expired, daysAgo: Double(5 - $0), now: now) }
        #expect(MateHeartbeatFatigue.isBackedOff(records))
        records.append(record("Useful", .approved, daysAgo: 0, now: now))
        #expect(!MateHeartbeatFatigue.isBackedOff(records))
        #expect(!MateHeartbeatFatigue.isBackedOff(Array(records.prefix(4))))
    }

    @Test func eligibilityDefaultsFollowFolderOrConnectedApp() {
        #expect(MateHeartbeatEligibility.isEnabled(globalEnabled: true, override: nil, archived: false, conductsOthers: false, hasFolder: true, hasConnectedApp: false))
        #expect(MateHeartbeatEligibility.isEnabled(globalEnabled: true, override: nil, archived: false, conductsOthers: false, hasFolder: false, hasConnectedApp: true))
        #expect(!MateHeartbeatEligibility.isEnabled(globalEnabled: true, override: nil, archived: false, conductsOthers: false, hasFolder: false, hasConnectedApp: false))
        #expect(!MateHeartbeatEligibility.isEnabled(globalEnabled: true, override: true, archived: true, conductsOthers: false, hasFolder: true, hasConnectedApp: true))
        #expect(!MateHeartbeatEligibility.isEnabled(globalEnabled: false, override: true, archived: false, conductsOthers: false, hasFolder: true, hasConnectedApp: true))
        #expect(MateHeartbeatEligibility.isEnabled(globalEnabled: true, override: true, archived: false, conductsOthers: false, hasFolder: false, hasConnectedApp: false))
        #expect(!MateHeartbeatEligibility.isEnabled(globalEnabled: true, override: false, archived: false, conductsOthers: false, hasFolder: true, hasConnectedApp: true))
        #expect(!MateHeartbeatEligibility.isEnabled(globalEnabled: true, override: nil, archived: false, conductsOthers: true, hasFolder: true, hasConnectedApp: true))
    }
}

struct MateHeartbeatParserTests {
    @Test func zeroProposalsIsValid() {
        #expect(MateHeartbeatParser.parse("{\"proposals\": []}") == [])
        #expect(MateHeartbeatParser.parse("Nothing today.\n```json\n{\"proposals\":[]}\n```") == [])
    }

    @Test func wellFormedProposalsParse() {
        let reply = """
        {"proposals": [{"title": "Summarise the Q3 notes", "why_now": "q3-notes.md changed this morning",
          "prompt": "Read q3-notes.md and write a five-line summary.", "needs_approval": null},
          {"title": "Prepare the 10:00 call", "why_now": "Calendar: 10:00 Acme sync",
           "prompt": "Draft talking points for the Acme sync.", "needs_approval": "Sending the draft to Ana"}]}
        """
        let drafts = MateHeartbeatParser.parse(reply)
        #expect(drafts?.count == 2)
        #expect(drafts?[0].needsApproval == nil)
        #expect(drafts?[1].needsApproval == "Sending the draft to Ana")
    }

    @Test func malformedOutputIsDroppedWhole() {
        let item = "{\"title\": \"T\", \"why_now\": \"W\", \"prompt\": \"P\"}"
        #expect(MateHeartbeatParser.parse("no json here") == nil)
        #expect(MateHeartbeatParser.parse("{\"proposals\": [\(item), \(item), \(item), \(item)]}") == nil)
        #expect(MateHeartbeatParser.parse("{\"proposals\": [{\"title\": \"T\", \"prompt\": \"P\"}]}") == nil)
        #expect(MateHeartbeatParser.parse("{\"proposals\": [{\"title\": \"T\", \"why_now\": \"W\", \"prompt\": \"P\", \"run\": true}]}") == nil)
        #expect(MateHeartbeatParser.parse("{\"proposals\": [{\"title\": \"Two\\nlines\", \"why_now\": \"W\", \"prompt\": \"P\"}]}") == nil)
        #expect(MateHeartbeatParser.parse("{\"proposals\": [], \"extra\": 1}") == nil)
        #expect(MateHeartbeatParser.parse("{\"proposals\": [{\"title\": \"T\", \"why_now\": \"W\", \"prompt\": \"P\", \"needs_approval\": 3}]}") == nil)
        let longTitle = String(repeating: "a", count: 81)
        #expect(MateHeartbeatParser.parse("{\"proposals\": [{\"title\": \"\(longTitle)\", \"why_now\": \"W\", \"prompt\": \"P\"}]}") == nil)
    }
}

struct MateHeartbeatDedupeTests {
    private func draft(_ title: String) -> MateHeartbeatParser.Draft {
        MateHeartbeatParser.Draft(title: title, whyNow: "why", prompt: "do \(title)", needsApproval: nil)
    }

    @Test func dropsSuppressedOpenRunningAndRepeatedTitles() {
        let kept = MateHeartbeatDedupe.filter(
            [draft("Draft the weekly report"), draft("Draft the weekly report."), draft("Tidy Downloads"),
             draft("Reply to Ana about invoices"), draft("Plan Friday")],
            blockedTitles: ["tidy downloads"],
            busyTexts: ["Reply to Ana about invoices and receipts", "Plan"]
        )
        #expect(kept.map(\.title) == ["Draft the weekly report", "Plan Friday"])
    }

    @Test func normalisationIgnoresCaseAndPunctuation() {
        #expect(MateHeartbeatText.normalized("  Draft: the WEEKLY report!! ") == "draft the weekly report")
    }
}

struct MateHeartbeatContextTests {
    @Test func rendersOnlyNamesDatesAndConnectedSources() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var inputs = MateHeartbeatContext.Inputs(mateName: "Ivy", job: "Research", soul: "", memory: "# Notes\nKeep it short",
            folderPath: "/Users/x/Ivy", now: now)
        inputs.folder = [.init(name: "plan.md", modified: now, isDirectory: false), .init(name: "drafts", modified: now, isDirectory: true)]
        inputs.failedJobs = ["Merge PDFs: file missing"]
        inputs.recentProposals = [
            MateHeartbeatRecord(id: UUID(), title: "Old idea", createdAt: now.addingTimeInterval(-8 * 86_400), outcome: .skipped),
            MateHeartbeatRecord(id: UUID(), title: "Fresh idea", createdAt: now.addingTimeInterval(-86_400), outcome: .approved)
        ]
        inputs.doNotPropose = ["Tidy Downloads"]
        let text = MateHeartbeatContext.render(inputs)
        #expect(text.contains("Keep it short"))
        #expect(text.contains("- plan.md (modified"))
        #expect(text.contains("- drafts/ (modified"))
        #expect(text.contains("Merge PDFs: file missing"))
        #expect(text.contains("Fresh idea (approved)"))
        #expect(!text.contains("Old idea"))
        #expect(text.contains("Tidy Downloads"))
        #expect(!text.contains("calendar"))
        #expect(!text.contains("Unread mail"))
        inputs.calendarToday = []
        inputs.unreadMail = ["Ana: Invoice 42"]
        let connected = MateHeartbeatContext.render(inputs)
        #expect(connected.contains("Today's calendar"))
        #expect(connected.contains("Ana: Invoice 42"))
    }

    @Test func excludedAppsBlockTheirSource() {
        #expect(!MateHeartbeatContext.allowsSource(bundleID: "com.apple.mail", excluded: ["com.apple.Mail"]))
        #expect(MateHeartbeatContext.allowsSource(bundleID: "com.apple.iCal", excluded: ["com.apple.mail"]))
    }

    @Test func folderListingNeverReadsContents() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("heartbeat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "secret body".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: folder.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        let entries = MateHeartbeatContext.folderEntries(at: folder.path)
        #expect(entries.map(\.name) == ["a.txt"])
        #expect(!MateHeartbeatContext.render(.init(mateName: "I", job: "J", soul: "", folderPath: folder.path,
            folder: entries, now: Date())).contains("secret body"))
    }
}

struct MateHeartbeatSurfaceTests {
    private func proposalItem(mateID: UUID, title: String, expiresIn: TimeInterval) -> MateInboxItem {
        let now = Date()
        let proposal = MateHeartbeatProposal(id: UUID(), title: title, whyNow: "why", prompt: "go", needsApproval: nil,
                                             createdAt: now, expiresAt: now.addingTimeInterval(expiresIn))
        return MateInboxItem(id: proposal.id, mateID: mateID, mateName: "Ivy", chatID: UUID(), createdAt: now,
                             resolvedAt: nil, resolutionSummary: nil, kind: .proposal(proposal))
    }

    @Test func proposalsExpireAndRoundTrip() throws {
        let live = proposalItem(mateID: UUID(), title: "Live", expiresIn: 3600)
        let old = proposalItem(mateID: UUID(), title: "Old", expiresIn: -1)
        #expect(live.isPendingAttention)
        #expect(!old.isPendingAttention)
        let decoded = try JSONDecoder().decode(MateInboxItem.self, from: JSONEncoder().encode(live))
        #expect(decoded == live)
        #expect(decoded.proposal?.title == "Live")
    }

    @Test func notificationNamesTheMateAndFirstTitle() {
        let payload = AgentNotificationPayload.proposals(mateName: "Ivy", firstTitle: "Summarise the notes", count: 2)
        #expect(payload?.title == "Ivy has an idea")
        #expect(payload?.body == "Summarise the notes (+1 more)")
        #expect(AgentNotificationPayload.proposals(mateName: "Ivy", firstTitle: "x", count: 0) == nil)
    }

    @MainActor @Test func digestListsProposalsAfterBlockedWork() {
        let mate = Mate(id: UUID(), name: "Ivy", job: "Job", pinned: false, archived: false, unreadCount: 0,
                        createdAt: Date(), updatedAt: Date(), memoryNote: "", folderPath: nil)
        let items = [proposalItem(mateID: mate.id, title: "Summarise the notes", expiresIn: 3600),
                     proposalItem(mateID: mate.id, title: "Old", expiresIn: -1)]
        let result = MateDigest.make(mates: [mate], routines: [], runs: [], owners: [:], sessions: [],
                                     defaultMateID: UUID(), activeMateID: nil, includesUnread: false, proposals: items)
        #expect(result.items.count == 1)
        #expect(result.items.first?.kind == .proposal)
        #expect(result.items.first?.detail == "Summarise the notes")
    }
}

@MainActor
struct MateHeartbeatSchedulerHookTests {
    @Test func heartbeatRidesTheRoutineTickWithoutRoutines() {
        let heartbeat = FakeHeartbeat()
        let scheduler = MateRoutineScheduler(network: HeartbeatTestNetwork(), wake: HeartbeatTestWake(), power: HeartbeatTestPower())
        let owner = HeartbeatTestOwner()
        scheduler.owner = owner
        scheduler.heartbeat = heartbeat
        scheduler.start()
        defer { scheduler.stop() }
        #expect(heartbeat.ticks == 1)
        #expect(heartbeat.lastNetwork == true)
        heartbeat.wants = false
        scheduler.tick(now: Date())
        #expect(heartbeat.ticks == 1)
    }
}

@MainActor private final class FakeHeartbeat: MateHeartbeatTicking {
    var wants = true
    var ticks = 0
    var lastNetwork: Bool?
    var wantsHeartbeatTicks: Bool { wants }
    func heartbeatTick(now: Date, networkUsable: Bool) {
        ticks += 1
        lastNetwork = networkUsable
    }
}

@MainActor private final class HeartbeatTestOwner: MateRoutineRunning {
    var scheduledRoutines: [MateRoutine] { [] }
    func deferRoutine(id: UUID, now: Date) {}
    func dueRoutines(now: Date) -> [MateRoutine] { [] }
    func markRoutineWaiting(id: UUID) {}
    func kickoffRoutine(_ routine: MateRoutine) -> MateRoutineKickoff { .busy }
    func noteRoutineFailure(id: UUID, message: String, now: Date) {}
}

private final class HeartbeatTestNetwork: MateNetworkMonitoring {
    var hasUsableNetwork: Bool { true }
    func start(onUsableNetwork: @escaping @MainActor @Sendable () -> Void) {}
    func stop() {}
}

@MainActor private final class HeartbeatTestWake: MateWakeSource {
    func shouldHold(now: Date) -> Bool { false }
    func start(onWake: @escaping @MainActor @Sendable () -> Void) {}
    func stop() {}
}

@MainActor private final class HeartbeatTestPower: MateRoutinePowerManaging {
    func update(armed: Bool) {}
    func stop() {}
}
