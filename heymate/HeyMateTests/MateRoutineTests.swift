//
//  MateRoutineTests.swift
//  HeyMateTests
//

import Foundation
import Testing
@testable import HeyMate

struct MateRoutinePhraseTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        Date(timeIntervalSince1970: 1_700_000_000)
    }

    @Test func everyMorningIsEight() {
        let routine = RoutinePhraseParser.parse(
            "every morning",
            mateID: UUID(),
            now: now,
            calendar: calendar
        )
        #expect(routine?.schedule == .daily(hour: 8, minute: 0))
        #expect(routine?.task == "Check in")
    }

    @Test func dailyAtEightAndEightThirty() {
        let onTheHour = RoutinePhraseParser.parse(
            "daily at 8",
            mateID: UUID(),
            now: now,
            calendar: calendar
        )
        let half = RoutinePhraseParser.parse(
            "daily at 8:30am",
            mateID: UUID(),
            now: now,
            calendar: calendar
        )
        #expect(onTheHour?.schedule == .daily(hour: 8, minute: 0))
        #expect(half?.schedule == .daily(hour: 8, minute: 30))
    }

    @Test func everyFewHoursMeansThreeAndKeepsTheTask() {
        let hours = RoutinePhraseParser.parse(
            "every 3 hours",
            mateID: UUID(),
            now: now,
            calendar: calendar
        )
        let mateID = UUID()
        let few = RoutinePhraseParser.parse(
            "check this every few hours",
            mateID: mateID,
            now: now,
            calendar: calendar
        )
        #expect(hours?.schedule == .everyHours(3))
        #expect(few?.schedule == .everyHours(3))
        #expect(few?.task == "check this")
        #expect(few?.mateID == mateID)
    }
}

struct MateRoutineScheduleTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func missedIntervalsCatchUpOnce() {
        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let now = from.addingTimeInterval(9.5 * 3_600)
        let next = RoutineSchedule.everyHours(3).advance(from: from, now: now, calendar: calendar)
        #expect(next == from.addingTimeInterval(12 * 3_600))
    }

    @Test func dailyAdvancesToTheFollowingSlot() {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 9
        parts.day = 23
        parts.hour = 10
        parts.minute = 0
        parts.timeZone = TimeZone(secondsFromGMT: 0)
        let now = calendar.date(from: parts)!
        let next = RoutineSchedule.daily(hour: 8, minute: 0).advance(
            from: now.addingTimeInterval(-86_400 * 3),
            now: now,
            calendar: calendar
        )
        let expected = calendar.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026,
            month: 9,
            day: 24,
            hour: 8,
            minute: 0
        ))
        #expect(next == expected)
    }

    @Test func networkWaitDoesNotCountAFailure() {
        let routine = sample(failures: 2)
        let waited = MateRoutineAccounting.markWaitingForNetwork(routine)
        #expect(waited.consecutiveFailures == 2)
        #expect(waited.nextRunAt == routine.nextRunAt)
        #expect(waited.lastStatusMessage == "I'll run it when the internet is back")
        #expect(waited.pausedReason == nil)
    }

    @Test func thirdFailurePauses() {
        var routine = sample(failures: 2)
        routine = MateRoutineAccounting.recordFailure(
            routine,
            now: routine.nextRunAt.addingTimeInterval(60),
            calendar: calendar,
            status: "The send failed."
        )
        #expect(routine.consecutiveFailures == 3)
        #expect(routine.pausedReason?.contains("3 failed") == true)
        #expect(MateRoutineAccounting.isDue(routine, now: Date.distantFuture) == false)
    }

    @Test func successResetsFailuresAndMovesForward() {
        let routine = sample(failures: 2)
        let now = routine.nextRunAt.addingTimeInterval(30)
        let updated = MateRoutineAccounting.recordSuccess(
            routine,
            now: now,
            calendar: calendar,
            status: "Done."
        )
        #expect(updated.consecutiveFailures == 0)
        #expect(updated.nextRunAt > now)
        #expect(updated.lastStatusMessage == "Done.")
    }

    @Test func pausedAndArchivedRoutinesStayPaused() {
        let paused = MateRoutineAccounting.pauseManually(sample(failures: 0))
        #expect(MateRoutineAccounting.isDue(paused, now: Date.distantFuture) == false)
        let archived = MateRoutineAccounting.pauseForArchivedMate(sample(failures: 0))
        #expect(archived.pausedReason == MateRoutineAccounting.archivedPauseReason)
        #expect(MateRoutineAccounting.isDue(archived, now: Date.distantFuture) == false)
    }

    @Test func unfinishedRunsAreFlaggedForTheNextOne() {
        let clean = sample(failures: 0)
        #expect(!MateRoutineAccounting.lastAttemptDidNotFinish(clean))
        #expect(MateRoutineAccounting.lastAttemptDidNotFinish(sample(failures: 1)))
        let interrupted = MateRoutineAccounting.recordInterrupted(clean, now: clean.nextRunAt, calendar: calendar)
        #expect(MateRoutineAccounting.lastAttemptDidNotFinish(interrupted))
        let succeeded = MateRoutineAccounting.recordSuccess(interrupted, now: interrupted.nextRunAt,
                                                            calendar: calendar, status: "Done.")
        #expect(!MateRoutineAccounting.lastAttemptDidNotFinish(succeeded))
    }

    @Test func routineMessagePrefixesTheTask() {
        #expect(
            MateRoutineMessage.format(task: "Check inbox", outcome: "3 new.")
                == "Check inbox\n3 new."
        )
    }

    @Test func dueBoundaryIsStrict() {
        let routine = sample(failures: 0)
        #expect(!MateRoutineAccounting.isDue(routine, now: routine.nextRunAt))
        #expect(MateRoutineAccounting.isDue(routine, now: routine.nextRunAt.addingTimeInterval(0.001)))
    }

    @Test func acceptedRunAdvancesFromStartAndCompletionKeepsThatSlot() {
        let original = sample(failures: 1)
        let start = original.nextRunAt.addingTimeInterval(600)
        let launched = MateRoutineAccounting.recordLaunch(original, now: start, calendar: calendar)
        #expect(launched.runCount == 1)
        #expect(launched.lastRunAt == start)
        #expect(launched.lastStatusMessage == nil)
        #expect(launched.nextRunAt == start.addingTimeInterval(3 * 3_600))
        #expect(MateRoutineAccounting.lastAttemptDidNotFinish(launched))
        let completed = MateRoutineAccounting.recordSuccess(launched, now: start.addingTimeInterval(60),
                                                            calendar: calendar, status: "Done.")
        #expect(completed.lastRunAt == start)
        #expect(completed.lastRunFinishedAt == start.addingTimeInterval(60))
        #expect(completed.nextRunAt == launched.nextRunAt)
        #expect(!MateRoutineAccounting.lastAttemptDidNotFinish(completed))
    }

    @Test func refusalPreservesRunHistoryAndRetriesInFiveMinutes() {
        let original = sample(failures: 2)
        let now = original.nextRunAt.addingTimeInterval(1)
        let retry = MateRoutineAccounting.recordRefusal(original, now: now)
        #expect(retry.nextRunAt == now.addingTimeInterval(300))
        #expect(retry.pendingRetryAt == retry.nextRunAt)
        #expect(retry.consecutiveFailures == original.consecutiveFailures)
        #expect(retry.lastRunAt == original.lastRunAt)
        #expect(retry.runCount == nil)
        let launched = MateRoutineAccounting.recordLaunch(retry, now: retry.nextRunAt, calendar: calendar)
        #expect(launched.pendingRetryAt == nil)
    }

    @Test func oldSavedRoutinesDecodeAndInterruptedLaunchSurvivesRelaunch() throws {
        let original = sample(failures: 0)
        let encoded = try JSONEncoder().encode(original)
        let legacy = try JSONDecoder().decode(MateRoutine.self, from: encoded)
        #expect(legacy.runCount == nil)
        #expect(legacy == original)
        let launched = MateRoutineAccounting.recordLaunch(legacy, now: legacy.nextRunAt, calendar: calendar)
        let restored = try JSONDecoder().decode(MateRoutine.self, from: JSONEncoder().encode(launched))
        #expect(restored.runCount == 1)
        #expect(MateRoutineAccounting.lastAttemptDidNotFinish(restored))
    }

    private func sample(failures: Int) -> MateRoutine {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return MateRoutine(
            id: UUID(),
            mateID: UUID(),
            task: "Check inbox",
            enabled: true,
            schedule: .everyHours(3),
            nextRunAt: start,
            lastRunAt: nil,
            lastStatusMessage: nil,
            consecutiveFailures: failures,
            pausedReason: nil
        )
    }
}

@MainActor
struct MateRoutineSchedulerTests {
    @Test func offlineWaitDoesNotStartOrFail() {
        let runner = FakeRoutineRunner(routines: [dueRoutine()])
        let network = FakeMateNetwork(hasUsableNetwork: false)
        let scheduler = MateRoutineScheduler(network: network, wake: FakeMateWake(), power: FakeRoutinePower())
        scheduler.owner = runner
        scheduler.tick(now: Date())
        #expect(runner.waitingIDs.count == 1)
        #expect(runner.started.isEmpty)
        #expect(runner.failures.isEmpty)
    }

    @Test func busyTurnGetsRetryWithoutFailure() {
        let runner = FakeRoutineRunner(routines: [dueRoutine()])
        runner.kickoff = .busy
        let scheduler = MateRoutineScheduler(
            network: FakeMateNetwork(hasUsableNetwork: true),
            wake: FakeMateWake(), power: FakeRoutinePower()
        )
        scheduler.owner = runner
        scheduler.tick(now: Date())
        #expect(runner.started.count == 1)
        #expect(runner.failures.isEmpty)
        #expect(runner.waitingIDs.isEmpty)
    }

    @Test func refusedSendRetriesWithoutCountingFailure() {
        let runner = FakeRoutineRunner(routines: [dueRoutine()])
        runner.kickoff = .failed("Couldn't send that routine.")
        let scheduler = MateRoutineScheduler(
            network: FakeMateNetwork(hasUsableNetwork: true),
            wake: FakeMateWake(), power: FakeRoutinePower()
        )
        scheduler.owner = runner
        scheduler.tick(now: Date())
        #expect(runner.failures.isEmpty)
        #expect(runner.deferredIDs.count == 1)
    }

    @Test func networkRecoveryRetriesDueWorkWithoutWaitingForTheTimer() {
        let runner = FakeRoutineRunner(routines: [dueRoutine()])
        let network = FakeMateNetwork(hasUsableNetwork: false)
        let scheduler = MateRoutineScheduler(network: network, wake: FakeMateWake(), power: FakeRoutinePower())
        scheduler.owner = runner
        scheduler.start()
        defer { scheduler.stop() }
        #expect(runner.started.isEmpty)
        #expect(runner.waitingIDs.count == 1)
        network.hasUsableNetwork = true
        network.onUsableNetwork?()
        #expect(runner.started.count == 1)
        #expect(runner.failures.isEmpty)
    }

    @Test func stopCleansSourcesAndRejectsOldCallbacksAfterRestart() {
        let runner = FakeRoutineRunner(routines: [dueRoutine()])
        let network = FakeMateNetwork(hasUsableNetwork: true)
        let wake = FakeMateWake()
        let scheduler = MateRoutineScheduler(network: network, wake: wake, power: FakeRoutinePower())
        scheduler.owner = runner
        scheduler.start()
        let oldNetwork = network.onUsableNetwork
        let oldWake = wake.onWake
        #expect(runner.started.count == 1)
        scheduler.stop()
        #expect(network.stops == 1)
        #expect(wake.stops == 1)
        oldNetwork?()
        oldWake?()
        #expect(runner.started.count == 1)
        scheduler.start()
        defer { scheduler.stop() }
        #expect(runner.started.count == 2)
        oldNetwork?()
        oldWake?()
        #expect(runner.started.count == 2)
        wake.onWake?()
        #expect(runner.started.count == 3)
    }

    @Test func wakeGateBlocksBothPollingAndManualDispatch() {
        let runner = FakeRoutineRunner(routines: [dueRoutine()])
        let wake = FakeMateWake()
        wake.held = true
        let scheduler = MateRoutineScheduler(network: FakeMateNetwork(hasUsableNetwork: true),
                                             wake: wake, power: FakeRoutinePower())
        scheduler.owner = runner
        scheduler.tick()
        scheduler.run(runner.routines[0])
        #expect(runner.started.isEmpty)
        #expect(runner.failures.isEmpty)
        wake.held = false
        scheduler.tick()
        #expect(runner.started.count == 1)
    }

    @Test func emptyScheduleStopsSourcesAndAddingRoutineRestarts() {
        let runner = FakeRoutineRunner(routines: [])
        let power = FakeRoutinePower()
        let network = FakeMateNetwork(hasUsableNetwork: true)
        let scheduler = MateRoutineScheduler(network: network, wake: FakeMateWake(), power: power)
        scheduler.owner = runner
        scheduler.start()
        defer { scheduler.stop() }
        #expect(network.onUsableNetwork == nil)
        runner.routines = [dueRoutine()]
        scheduler.schedulesChanged()
        #expect(network.onUsableNetwork != nil)
        #expect(power.armed)
        runner.routines[0].pausedReason = "Paused"
        scheduler.schedulesChanged()
        #expect(!power.armed)
        runner.routines = []
        scheduler.schedulesChanged()
        #expect(network.onUsableNetwork == nil)
    }

    private func dueRoutine() -> MateRoutine {
        MateRoutine(
            id: UUID(),
            mateID: UUID(),
            task: "Check inbox",
            enabled: true,
            schedule: .everyHours(1),
            nextRunAt: Date(timeIntervalSince1970: 10),
            lastRunAt: nil,
            lastStatusMessage: nil,
            consecutiveFailures: 0,
            pausedReason: nil
        )
    }
}

@MainActor
private final class FakeRoutineRunner: MateRoutineRunning {
    var routines: [MateRoutine]
    var scheduledRoutines: [MateRoutine] { routines }
    var deferredIDs: [UUID] = []
    func deferRoutine(id: UUID, now: Date) { deferredIDs.append(id) }
    var kickoff: MateRoutineKickoff = .started
    var waitingIDs: [UUID] = []
    var started: [UUID] = []
    var failures: [UUID] = []

    init(routines: [MateRoutine]) {
        self.routines = routines
    }

    func dueRoutines(now: Date) -> [MateRoutine] {
        routines.filter { MateRoutineAccounting.isDue($0, now: now) }
    }

    func markRoutineWaiting(id: UUID) {
        waitingIDs.append(id)
    }

    func kickoffRoutine(_ routine: MateRoutine) -> MateRoutineKickoff {
        started.append(routine.id)
        return kickoff
    }

    func noteRoutineFailure(id: UUID, message: String, now: Date) {
        failures.append(id)
    }
}

private final class FakeMateNetwork: MateNetworkMonitoring {
    var hasUsableNetwork: Bool
    init(hasUsableNetwork: Bool) { self.hasUsableNetwork = hasUsableNetwork }
    var onUsableNetwork: (@MainActor @Sendable () -> Void)?
    var stops = 0
    func start(onUsableNetwork: @escaping @MainActor @Sendable () -> Void) {
        self.onUsableNetwork = onUsableNetwork
    }
    func stop() { stops += 1; onUsableNetwork = nil }
}

@MainActor
private final class FakeMateWake: MateWakeSource {
    var held = false
    func shouldHold(now: Date) -> Bool { held }
    var onWake: (@MainActor @Sendable () -> Void)?
    var stops = 0
    func start(onWake: @escaping @MainActor @Sendable () -> Void) { self.onWake = onWake }
    func stop() { stops += 1; onWake = nil }
}

struct MateRoutineEditingTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        Date(timeIntervalSince1970: 1_700_000_000)
    }

    @Test func editKeepsIdentityAndReplacesSchedule() {
        let id = UUID()
        let mateID = UUID()
        let original = MateRoutine(
            id: id,
            mateID: mateID,
            task: "Check inbox",
            enabled: true,
            schedule: .everyHours(3),
            nextRunAt: now,
            lastRunAt: now.addingTimeInterval(-10),
            lastStatusMessage: "Done.",
            consecutiveFailures: 2,
            pausedReason: MateRoutineAccounting.manualPauseReason
        )
        let edited = original.editing(
            task: "Scan news",
            schedulePhrase: "every morning",
            now: now,
            calendar: calendar
        )
        let expectedNext = RoutineSchedule.daily(hour: 8, minute: 0).advance(from: now, now: now, calendar: calendar)
        #expect(edited?.id == id)
        #expect(edited?.mateID == mateID)
        #expect(edited?.task == "Scan news")
        #expect(edited?.schedule == .daily(hour: 8, minute: 0))
        #expect(edited?.nextRunAt == expectedNext)
        #expect(edited?.enabled == true)
        #expect(edited?.lastRunAt == original.lastRunAt)
        #expect(edited?.lastStatusMessage == "Done.")
        #expect(edited?.consecutiveFailures == 2)
        #expect(edited?.pausedReason == MateRoutineAccounting.manualPauseReason)
    }

    @Test func badSchedulePhraseIsRejected() {
        let original = MateRoutine(
            id: UUID(),
            mateID: UUID(),
            task: "Check inbox",
            enabled: true,
            schedule: .everyHours(3),
            nextRunAt: now,
            lastRunAt: nil,
            lastStatusMessage: nil,
            consecutiveFailures: 0,
            pausedReason: nil
        )
        let edited = original.editing(
            task: "Scan news",
            schedulePhrase: "later",
            now: now,
            calendar: calendar
        )
        #expect(edited == nil)
        #expect(RoutinePhraseParser.invalidScheduleMessage == "Say when it should run, like every morning or every 3 hours.")
    }

    @Test func instructionPhrasesRoundTripThroughTheParser() {
        let schedules: [RoutineSchedule] = [
            .daily(hour: 0, minute: 0),
            .daily(hour: 8, minute: 0),
            .daily(hour: 12, minute: 0),
            .daily(hour: 15, minute: 30),
            .everyHours(1),
            .everyHours(3)
        ]
        for schedule in schedules {
            let parsed = RoutinePhraseParser.parse(
                schedule.instructionPhrase,
                mateID: UUID(),
                now: now,
                calendar: calendar
            )
            #expect(parsed?.schedule == schedule)
        }
    }
}

@MainActor
struct MateRoutineUpdateTests {
    @Test func updateRoutineKeepsTheSameId() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-routine-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = CompanionManager(
            chatHistoryStore: FileChatHistoryStore(fileURL: folder.appendingPathComponent("chats.json")),
            mateStore: FileMateStore(fileURL: folder.appendingPathComponent("mates.json")),
            routineStore: FileMateRoutineStore(fileURL: folder.appendingPathComponent("routines.json"))
        )
        let mateID = try #require(manager.mates.first?.id)
        let routine = try #require(RoutinePhraseParser.parse(
            "check inbox every 3 hours",
            mateID: mateID,
            now: Date(),
            calendar: .current
        ))
        manager.addRoutine(routine)
        let error = manager.updateRoutine(id: routine.id, task: "Scan news", schedulePhrase: "every morning")
        #expect(error == nil)
        let saved = manager.routines.filter { $0.id == routine.id }
        #expect(saved.count == 1)
        #expect(saved.first?.task == "Scan news")
        #expect(saved.first?.schedule == .daily(hour: 8, minute: 0))
        #expect(saved.first?.mateID == mateID)
        let rejected = manager.updateRoutine(id: routine.id, task: "Scan news", schedulePhrase: "later")
        #expect(rejected == RoutinePhraseParser.invalidScheduleMessage)
        #expect(manager.routines.first { $0.id == routine.id }?.schedule == .daily(hour: 8, minute: 0))
    }

    @Test func persistFailureRecordsTheError() {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-persist-blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("nope".utf8))
        defer { try? FileManager.default.removeItem(at: blocker) }
        let store = FileMateRoutineStore(fileURL: blocker.appendingPathComponent("routines.json"))
        let key = "heymate.lastPersistError"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let box = PersistNoteBox()
        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name("heymate.persistFailed"),
            object: nil,
            queue: nil
        ) { _ in
            box.posted = true
        }
        defer { NotificationCenter.default.removeObserver(token) }
        store.upsert(MateRoutine(
            id: UUID(),
            mateID: UUID(),
            task: "Check inbox",
            enabled: true,
            schedule: .everyHours(3),
            nextRunAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastRunAt: nil,
            lastStatusMessage: nil,
            consecutiveFailures: 0,
            pausedReason: nil
        ))
        #expect(UserDefaults.standard.string(forKey: key)?.isEmpty == false)
        #expect(box.posted)
        #expect(store.loadAll().count == 1)
    }
}

private final class PersistNoteBox: @unchecked Sendable {
    var posted = false
}

@MainActor
private final class FakeRoutinePower: MateRoutinePowerManaging {
    var armed = false
    var stops = 0
    func update(armed: Bool) { self.armed = armed }
    func stop() { stops += 1; armed = false }
}

struct RoutineWakeGateTests {
    @Test func darkWakeHasNoDeadlineUntilMainDisplayWakes() {
        var gate = RoutineWakeGate()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        gate.willSleep()
        #expect(Bool(gate.shouldHold(displayAsleep: true, now: now)))
        #expect(Bool(gate.shouldHold(displayAsleep: true, now: now.addingTimeInterval(500))))
        gate.screensDidWake()
        #expect(Bool(gate.shouldHold(displayAsleep: false, now: now.addingTimeInterval(500))))
        #expect(Bool(gate.shouldHold(displayAsleep: false, now: now.addingTimeInterval(679))))
        #expect(!Bool(gate.shouldHold(displayAsleep: false, now: now.addingTimeInterval(680))))
    }

    @Test func fullWakeClearsHoldAndSecondSleepResetsDeadline() {
        var gate = RoutineWakeGate()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        gate.willSleep()
        #expect(Bool(gate.shouldHold(displayAsleep: false, now: now)))
        gate.didWake()
        #expect(!Bool(gate.shouldHold(displayAsleep: false, now: now)))
        gate.willSleep()
        gate.didWake()
        #expect(Bool(gate.shouldHold(displayAsleep: true, now: now)))
        #expect(!Bool(gate.shouldHold(displayAsleep: false, now: now)))
        gate.willSleep()
        #expect(Bool(gate.shouldHold(displayAsleep: false, now: now.addingTimeInterval(500))))
    }
}
