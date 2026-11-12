//
//  MateParityTests.swift
//  HeyMateTests
//

import Foundation
import Testing
@testable import HeyMate

struct BrainUsageLimitTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func recognisesLimitMessages() {
        #expect(BrainUsageLimit.isLimit("Claude AI usage limit reached|1700003600"))
        #expect(BrainUsageLimit.isLimit("You've hit your limit · resets 3pm"))
        #expect(BrainUsageLimit.isLimit("You've hit your usage limit. Try again in 2 hours 13 minutes."))
        #expect(!BrainUsageLimit.isLimit("Not logged in"))
        #expect(!BrainUsageLimit.isLimit("The file could not be found"))
    }

    @Test func readsEpochReset() {
        let date = BrainUsageLimit.resetDate(from: "Claude AI usage limit reached|1700003600", now: now)
        #expect(date == Date(timeIntervalSince1970: 1_700_003_600))
    }

    @Test func readsRelativeReset() {
        let date = BrainUsageLimit.resetDate(from: "Try again in 2 hours 13 minutes.", now: now)
        #expect(date == now.addingTimeInterval(2 * 3_600 + 13 * 60))
    }

    @Test func readsClockResetAndRollsToTomorrow() {
        // now is 22:13 UTC, so "resets 3pm" means tomorrow.
        let date = BrainUsageLimit.resetDate(from: "You've hit your limit · resets 3pm", now: now, calendar: calendar)
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        #expect(parts.hour == 15 && parts.minute == 0)
        #expect(date > now && date.timeIntervalSince(now) < 24 * 3_600)
    }

    @Test func fallsBackToDefaultWait() {
        #expect(BrainUsageLimit.resetDate(from: "usage limit", now: now) == now.addingTimeInterval(BrainUsageLimit.defaultWait))
    }

    @Test func ledgerPicksBackupOnlyWhileLimited() {
        let defaults = UserDefaults(suiteName: "MateParityTests-\(UUID().uuidString)")!
        let ledger = BrainLimitLedger(defaults: defaults)
        #expect(ledger.effectiveBrain(primary: .claudeCode, backup: .codex, now: now) == .claudeCode)
        ledger.markLimited(.claudeCode, until: now.addingTimeInterval(600))
        #expect(ledger.effectiveBrain(primary: .claudeCode, backup: .codex, now: now) == .codex)
        #expect(ledger.effectiveBrain(primary: .claudeCode, backup: nil, now: now) == .claudeCode)
        #expect(ledger.effectiveBrain(primary: .claudeCode, backup: .codex, now: now.addingTimeInterval(601)) == .claudeCode)
    }
}

struct MateRoutineHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func routine() -> MateRoutine {
        var routine = MateRoutine.scheduled(
            mateID: UUID(), task: "Check mail", schedule: .everyHours(1), now: now, calendar: .current
        )
        routine = MateRoutineAccounting.recordLaunch(routine, now: now, calendar: .current)
        return routine
    }

    @Test func keepsNewestRunsFirstAndCapped() {
        var current = routine()
        for index in 0..<(MateRoutineRun.keptCount + 3) {
            current = MateRoutineAccounting.recordLaunch(current, now: now.addingTimeInterval(Double(index) * 100), calendar: .current)
            current = MateRoutineAccounting.recordSuccess(
                current, now: now.addingTimeInterval(Double(index) * 100 + 30), calendar: .current, status: "Run \(index)\nmore"
            )
        }
        #expect(current.history?.count == MateRoutineRun.keptCount)
        #expect(current.history?.first?.summary == "Run \(MateRoutineRun.keptCount + 2)")
        #expect(current.history?.first?.duration == 30)
    }

    @Test func runLimitOnlyAppliesWhileRunning() {
        var current = routine()
        current.maxRunMinutes = 5
        #expect(!MateRoutineAccounting.isOverRunLimit(current, now: now.addingTimeInterval(4 * 60)))
        #expect(MateRoutineAccounting.isOverRunLimit(current, now: now.addingTimeInterval(5 * 60)))
        let timedOut = MateRoutineAccounting.recordTimedOut(current, now: now.addingTimeInterval(5 * 60), calendar: .current)
        #expect(timedOut.history?.first?.outcome == .timedOut)
        #expect(!MateRoutineAccounting.isOverRunLimit(timedOut, now: now.addingTimeInterval(10 * 60)))
    }

    @Test func oldRoutineFilesStillDecode() throws {
        let original = routine()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json.removeValue(forKey: "history")
        json.removeValue(forKey: "maxRunMinutes")
        let decoded = try JSONDecoder().decode(MateRoutine.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.history == nil && decoded.maxRunMinutes == nil)
    }
}

struct MateMarkdownTests {
    @Test func roundTrips() throws {
        let document = MateMarkdownDocument(
            name: "Inbox Scout",
            job: "Keeps my inbox tidy",
            soul: "Brief.\n# not a heading",
            brainRawValue: "claudeCode",
            backupBrainRawValue: "codex",
            howItWorks: ["Lead with the result"],
            asksFirst: ["Sending email"],
            memory: "Prefers mornings",
            routines: [MateMarkdownRoutine(when: "every weekday at 9am", task: "Sort new mail: label it", maxRunMinutes: 30)],
            wakeKind: .newMail,
            wakeMatch: "invoice"
        )
        let parsed = try MateMarkdown.parse(MateMarkdown.render(document)).get()
        #expect(parsed == document)
    }

    @Test func rejectsOtherMarkdown() {
        #expect(MateMarkdown.parse("# Notes\n\nhello") == .failure(.notAnAgentFile))
        #expect(MateMarkdown.parse("---\n\(MateMarkdown.formatMarker)\nname: X\n---\n") == .failure(.missingJob))
    }

    @Test func dropsUnknownBrains() throws {
        let parsed = try MateMarkdown.parse("---\n\(MateMarkdown.formatMarker)\nname: X\njob: Y\nbrain: hal9000\n---\n").get()
        #expect(parsed.brainRawValue == nil)
    }
}

struct MateRoutineRecoveryTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func launched() -> MateRoutine {
        let routine = MateRoutine.scheduled(mateID: UUID(), task: "Check mail", schedule: .everyHours(4), now: now, calendar: .current)
        return MateRoutineAccounting.recordLaunch(routine, now: now, calendar: .current)
    }

    @Test func genericFailureRetriesOnceThenCounts() {
        let first = MateRoutineAccounting.recordFailureWithRecovery(
            launched(), now: now, calendar: .current, status: "Network hiccup", backupAvailable: false)
        #expect(first.consecutiveFailures == 0)
        #expect(first.nextRunAt == now.addingTimeInterval(MateRoutineAccounting.failureRetryInterval))
        #expect(first.autoRetried == true)
        let relaunched = MateRoutineAccounting.recordLaunch(first, now: now.addingTimeInterval(20), calendar: .current)
        let second = MateRoutineAccounting.recordFailureWithRecovery(
            relaunched, now: now.addingTimeInterval(30), calendar: .current, status: "Network hiccup", backupAvailable: false)
        #expect(second.consecutiveFailures == 1)
        #expect(second.autoRetried == nil)
    }

    @Test func usageLimitWaitsForReset() {
        let reset = now.addingTimeInterval(2 * 3_600)
        let waited = MateRoutineAccounting.recordFailureWithRecovery(
            launched(), now: now, calendar: .current,
            status: "Claude AI usage limit reached|\(Int(reset.timeIntervalSince1970))", backupAvailable: false)
        #expect(waited.consecutiveFailures == 0)
        #expect(waited.nextRunAt == reset.addingTimeInterval(MateRoutineAccounting.afterResetDelay))
    }

    @Test func usageLimitWithBackupRetriesSoon() {
        let retried = MateRoutineAccounting.recordFailureWithRecovery(
            launched(), now: now, calendar: .current, status: "You've hit your usage limit", backupAvailable: true)
        #expect(retried.nextRunAt == now.addingTimeInterval(MateRoutineAccounting.failureRetryInterval))
    }

    @Test func signedOutIsNotRetried() {
        let failed = MateRoutineAccounting.recordFailureWithRecovery(
            launched(), now: now, calendar: .current, status: "Not logged in", backupAvailable: false)
        #expect(failed.consecutiveFailures == 1)
    }

    @Test func busySkipsSlotAfterAnHour() {
        var routine = launched()
        routine = MateRoutineAccounting.recordRefusal(routine, now: now)
        #expect(routine.busySince == now)
        let later = now.addingTimeInterval(MateRoutineAccounting.busyWaitLimit + 1)
        routine = MateRoutineAccounting.recordRefusal(routine, now: later)
        #expect(routine.busySince == nil)
        #expect(routine.lastStatusMessage == MateRoutineAccounting.busySkippedStatus)
        #expect(routine.nextRunAt > later.addingTimeInterval(60))
    }
}
