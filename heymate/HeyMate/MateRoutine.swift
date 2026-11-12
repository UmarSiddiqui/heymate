//
//  MateRoutine.swift
//  HeyMate
//
//  A schedule owned by one mate. Due-ness, catch-up, and failure pauses are
//  pure so tests never start a timer.
//

import Foundation

nonisolated enum RoutineSchedule: Codable, Equatable {
    case daily(hour: Int, minute: Int)
    case everyHours(Int)
    /// Monday to Friday at one time.
    case weekdays(hour: Int, minute: Int)
    /// One day a week. `weekday` is Calendar's: 1 is Sunday, 7 is Saturday.
    case weekly(weekday: Int, hour: Int, minute: Int)
    case everyMinutes(Int)

    /// Shortest gap a person can schedule. Each run costs a model turn.
    static let minimumMinutes = 15
    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    static func weekdayName(_ weekday: Int) -> String {
        weekdayNames[min(7, max(1, weekday)) - 1]
    }

    /// Schedules a build from before 1.0.92 cannot read. They are kept in
    /// their own file so that build still loads every routine it knows.
    var isExtended: Bool {
        switch self {
        case .daily, .everyHours: return false
        case .weekdays, .weekly, .everyMinutes: return true
        }
    }

    private static func clock(_ hour: Int, _ minute: Int) -> String {
        let suffix = hour < 12 ? "am" : "pm"
        let shownHour = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d%@", shownHour, minute, suffix)
    }

    private static func phraseClock(_ hour: Int, _ minute: Int) -> String {
        let suffix = hour < 12 ? "am" : "pm"
        let shownHour = hour % 12 == 0 ? 12 : hour % 12
        return minute == 0 ? "\(shownHour)\(suffix)" : String(format: "%d:%02d%@", shownHour, minute, suffix)
    }

    var summary: String {
        switch self {
        case .daily(let hour, let minute):
            return "Daily at \(Self.clock(hour, minute))"
        case .everyHours(let hours):
            let count = max(1, hours)
            return count == 1 ? "Every hour" : "Every \(count) hours"
        case .weekdays(let hour, let minute):
            return "Weekdays at \(Self.clock(hour, minute))"
        case .weekly(let weekday, let hour, let minute):
            return "\(Self.weekdayName(weekday))s at \(Self.clock(hour, minute))"
        case .everyMinutes(let minutes):
            return "Every \(max(Self.minimumMinutes, minutes)) minutes"
        }
    }

    /// A phrase `RoutinePhraseParser` accepts for this schedule.
    var instructionPhrase: String {
        switch self {
        case .daily(let hour, let minute):
            return "daily at \(Self.phraseClock(hour, minute))"
        case .everyHours(let hours):
            return "every \(max(1, hours)) hour\(max(1, hours) == 1 ? "" : "s")"
        case .weekdays(let hour, let minute):
            return "every weekday at \(Self.phraseClock(hour, minute))"
        case .weekly(let weekday, let hour, let minute):
            return "every \(Self.weekdayName(weekday).lowercased()) at \(Self.phraseClock(hour, minute))"
        case .everyMinutes(let minutes):
            return "every \(max(Self.minimumMinutes, minutes)) minutes"
        }
    }

    /// The first `hour:minute` after `now` on a day `allows` accepts.
    private static func nextClock(
        hour: Int, minute: Int, now: Date, calendar: Calendar, allows: (Int) -> Bool
    ) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = min(23, max(0, hour))
        components.minute = min(59, max(0, minute))
        components.second = 0
        guard var candidate = calendar.date(from: components) else { return now.addingTimeInterval(3_600) }
        // Eight steps covers a full week from any starting day.
        for _ in 0..<8 {
            if candidate > now, allows(calendar.component(.weekday, from: candidate)) { return candidate }
            candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate.addingTimeInterval(86_400)
        }
        return candidate
    }

    /// Next slot strictly after `now` when `from` is already due. Missed
    /// intervals collapse to a single following slot — no backlog.
    func advance(from scheduled: Date, now: Date, calendar: Calendar) -> Date {
        switch self {
        case .everyHours(let hours):
            let interval = TimeInterval(max(1, hours) * 3_600)
            if scheduled > now { return scheduled }
            let elapsed = now.timeIntervalSince(scheduled)
            let steps = floor(elapsed / interval) + 1
            return scheduled.addingTimeInterval(steps * interval)
        case .everyMinutes(let minutes):
            let interval = TimeInterval(max(Self.minimumMinutes, minutes) * 60)
            if scheduled > now { return scheduled }
            let steps = floor(now.timeIntervalSince(scheduled) / interval) + 1
            return scheduled.addingTimeInterval(steps * interval)
        case .weekdays(let hour, let minute):
            return Self.nextClock(hour: hour, minute: minute, now: now, calendar: calendar) { (2...6).contains($0) }
        case .weekly(let weekday, let hour, let minute):
            let day = min(7, max(1, weekday))
            return Self.nextClock(hour: hour, minute: minute, now: now, calendar: calendar) { $0 == day }
        case .daily(let hour, let minute):
            let safeHour = min(23, max(0, hour))
            let safeMinute = min(59, max(0, minute))
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = safeHour
            components.minute = safeMinute
            components.second = 0
            guard var candidate = calendar.date(from: components) else {
                return now.addingTimeInterval(3_600)
            }
            if candidate <= now {
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate)
                    ?? candidate.addingTimeInterval(86_400)
            }
            return candidate
        }
    }
}

nonisolated struct MateRoutine: Codable, Equatable, Identifiable {
    let id: UUID
    var mateID: UUID
    var task: String
    var enabled: Bool
    var schedule: RoutineSchedule
    var nextRunAt: Date
    var lastRunAt: Date?
    var lastStatusMessage: String?
    var consecutiveFailures: Int
    /// Non-nil means paused. Paused routines do not run.
    var pausedReason: String?
    // Optional additions keep pre-port routines.json files decodable.
    var runCount: Int? = nil
    var lastRunFinishedAt: Date? = nil
    var pendingRetryAt: Date? = nil
    var lastRunFailed: Bool? = nil
    /// Newest first, at most `MateRoutineRun.keptCount`.
    var history: [MateRoutineRun]? = nil
    /// Stop a run that is still going after this many minutes. Nil: no limit.
    var maxRunMinutes: Int? = nil
    /// The last failure already had its one automatic retry.
    var autoRetried: Bool? = nil
    /// When the routine first found HeyMate busy for this slot.
    var busySince: Date? = nil
}

/// One finished run of a routine, kept so the person can see how it has
/// been going rather than only the last line.
nonisolated struct MateRoutineRun: Codable, Equatable, Identifiable {
    enum Outcome: String, Codable {
        case succeeded, failed, interrupted, timedOut
    }

    var id: UUID = UUID()
    var startedAt: Date
    var finishedAt: Date
    var outcome: Outcome
    /// First line of the result or failure, trimmed.
    var summary: String

    static let keptCount = 10
    static let summaryLimit = 160

    var duration: TimeInterval { max(0, finishedAt.timeIntervalSince(startedAt)) }

    static func summarize(_ text: String) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return firstLine.count > summaryLimit ? String(firstLine.prefix(summaryLimit - 1)) + "…" : firstLine
    }
}

extension MateRoutine {
    /// A new enabled routine whose first run is the schedule's next slot.
    nonisolated static func scheduled(
        mateID: UUID,
        task: String,
        schedule: RoutineSchedule,
        now: Date,
        calendar: Calendar
    ) -> MateRoutine {
        MateRoutine(
            id: UUID(),
            mateID: mateID,
            task: task,
            enabled: true,
            schedule: schedule,
            nextRunAt: schedule.advance(from: now, now: now, calendar: calendar),
            lastRunAt: nil,
            lastStatusMessage: nil,
            consecutiveFailures: 0,
            pausedReason: nil
        )
    }

    /// Replaces task, schedule, and nextRunAt. The id, mate, and run history stay.
    nonisolated func editing(task: String, schedulePhrase: String, now: Date, calendar: Calendar) -> MateRoutine? {
        guard let parsed = RoutinePhraseParser.parse(
            schedulePhrase,
            mateID: mateID,
            now: now,
            calendar: calendar
        ) else { return nil }
        var copy = self
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.task = trimmedTask.isEmpty ? parsed.task : trimmedTask
        copy.schedule = parsed.schedule
        copy.nextRunAt = parsed.nextRunAt
        copy.pendingRetryAt = nil
        return copy
    }
}

nonisolated enum MateRoutineAccounting {
    static let networkWaitStatus = "I'll run it when the internet is back"
    static let failurePauseCount = 3
    static let archivedPauseReason = "Paused because this agent is archived."
    static let manualPauseReason = "Paused by you."
    static let interruptedStatus = "Interrupted. I'll try the next slot."
    static let runLimitChoices = [5, 15, 30, 60, 120]

    static func timedOutStatus(minutes: Int) -> String {
        "Stopped after \(minutes) min, the time limit. I'll try the next slot."
    }

    /// The running turn has gone past the routine's own time limit.
    static func isOverRunLimit(_ routine: MateRoutine, now: Date) -> Bool {
        guard let minutes = routine.maxRunMinutes, minutes > 0,
              let started = routine.lastRunAt, routine.lastRunFinishedAt == nil else { return false }
        return now.timeIntervalSince(started) >= Double(minutes) * 60
    }

    static func appendingRun(
        _ routine: MateRoutine, startedFrom previous: MateRoutine, now: Date,
        outcome: MateRoutineRun.Outcome, status: String
    ) -> MateRoutine {
        var copy = routine
        let run = MateRoutineRun(
            startedAt: min(previous.lastRunAt ?? now, now),
            finishedAt: now,
            outcome: outcome,
            summary: MateRoutineRun.summarize(status)
        )
        copy.history = Array(([run] + (routine.history ?? [])).prefix(MateRoutineRun.keptCount))
        return copy
    }

    static func recordTimedOut(_ routine: MateRoutine, now: Date, calendar: Calendar) -> MateRoutine {
        let status = timedOutStatus(minutes: routine.maxRunMinutes ?? 0)
        var copy = finish(routine, now: now, calendar: calendar)
        copy.lastRunFailed = true
        copy.lastStatusMessage = status
        return appendingRun(copy, startedFrom: routine, now: now, outcome: .timedOut, status: status)
    }

    /// The previous run failed or was cut off, so it may have done part of
    /// the work. The next run checks before repeating anything.
    static func lastAttemptDidNotFinish(_ routine: MateRoutine) -> Bool {
        routine.consecutiveFailures > 0 || routine.lastStatusMessage == interruptedStatus
            || routine.lastRunFailed == true
            || ((routine.runCount ?? 0) > 0 && routine.lastRunFinishedAt == nil)
    }

    static func isDue(_ routine: MateRoutine, now: Date) -> Bool {
        guard routine.enabled, routine.pausedReason == nil else { return false }
        return routine.nextRunAt < now
    }

    static func markWaitingForNetwork(_ routine: MateRoutine) -> MateRoutine {
        var copy = routine
        if lastAttemptDidNotFinish(routine) { copy.lastRunFailed = true }
        copy.lastStatusMessage = networkWaitStatus
        return copy
    }

    /// A busy HeyMate is checked again this often, for up to `busyWaitLimit`.
    static let refusalRetryInterval: TimeInterval = 30
    static let busyWaitLimit: TimeInterval = 60 * 60
    static let busySkippedStatus = "Skipped this run: HeyMate stayed busy for an hour. I'll try the next slot."
    static let failureRetryInterval: TimeInterval = 15
    /// A usage limit further out than this fails the run; the next slot comes sooner.
    static let longestLimitWait: TimeInterval = 12 * 60 * 60
    static let afterResetDelay: TimeInterval = 60

    static func recordLaunch(_ routine: MateRoutine, now: Date, calendar: Calendar) -> MateRoutine {
        var copy = routine
        copy.runCount = (routine.runCount ?? 0) + 1
        copy.lastRunAt = now
        copy.lastRunFinishedAt = nil
        copy.lastStatusMessage = nil
        copy.lastRunFailed = false
        copy.pendingRetryAt = nil
        copy.busySince = nil
        switch routine.schedule {
        case .everyHours(let hours):
            copy.nextRunAt = now.addingTimeInterval(Double(max(1, hours)) * 3_600)
        case .everyMinutes(let minutes):
            copy.nextRunAt = now.addingTimeInterval(Double(max(RoutineSchedule.minimumMinutes, minutes)) * 60)
        case .daily, .weekdays, .weekly:
            copy.nextRunAt = routine.schedule.advance(from: now, now: now, calendar: calendar)
        }
        return copy
    }

    static func recordRefusal(_ routine: MateRoutine, now: Date, calendar: Calendar = .current) -> MateRoutine {
        var copy = routine
        let since = routine.busySince ?? now
        if now.timeIntervalSince(since) >= busyWaitLimit {
            copy.busySince = nil
            copy.pendingRetryAt = nil
            copy.lastStatusMessage = busySkippedStatus
            copy.nextRunAt = routine.schedule.advance(from: now, now: now, calendar: calendar)
            var waited = copy
            waited.lastRunAt = since
            return appendingRun(copy, startedFrom: waited, now: now, outcome: .interrupted, status: busySkippedStatus)
        }
        copy.busySince = since
        copy.nextRunAt = now.addingTimeInterval(refusalRetryInterval)
        copy.pendingRetryAt = copy.nextRunAt
        return copy
    }

    /// What a failed unattended run turns into. A usage limit is waited out
    /// (or retried at once when a backup brain can take it); any other
    /// failure gets one retry 15 seconds later; a second failure counts.
    /// A Stop never comes here, so it is never retried.
    static func recordFailureWithRecovery(
        _ routine: MateRoutine,
        now: Date,
        calendar: Calendar,
        status: String,
        backupAvailable: Bool
    ) -> MateRoutine {
        if BrainUsageLimit.isLimit(status) {
            if backupAvailable, routine.autoRetried != true {
                var retry = scheduledRetry(routine, now: now, calendar: calendar, after: failureRetryInterval,
                                           status: "The brain hit its usage limit. Retrying on the backup.", originalStatus: status)
                retry.autoRetried = true
                return retry
            }
            let reset = BrainUsageLimit.resetDate(from: status, now: now, calendar: calendar)
            if reset.timeIntervalSince(now) <= longestLimitWait {
                let clock = reset.formatted(date: .omitted, time: .shortened)
                return scheduledRetry(routine, now: now, calendar: calendar,
                                      after: reset.timeIntervalSince(now) + afterResetDelay,
                                      status: "Waiting for the usage limit to reset around \(clock), then I'll run it.",
                                      originalStatus: status)
            }
        }
        let ownerMustFix = SpokenFailure.classify(message: status) == .signedOut
        if !ownerMustFix, routine.autoRetried != true {
            var retry = scheduledRetry(routine, now: now, calendar: calendar, after: failureRetryInterval,
                                       status: "Failed. Trying once more in a moment.", originalStatus: status)
            retry.autoRetried = true
            return retry
        }
        var failed = recordFailure(routine, now: now, calendar: calendar, status: status)
        failed.autoRetried = nil
        return failed
    }

    private static func scheduledRetry(
        _ routine: MateRoutine, now: Date, calendar: Calendar, after delay: TimeInterval,
        status: String, originalStatus: String
    ) -> MateRoutine {
        var copy = finish(routine, now: now, calendar: calendar)
        copy.lastRunFailed = true
        copy.lastStatusMessage = status
        copy.nextRunAt = now.addingTimeInterval(delay)
        copy.pendingRetryAt = copy.nextRunAt
        return appendingRun(copy, startedFrom: routine, now: now, outcome: .failed, status: originalStatus)
    }

    private static func finish(_ routine: MateRoutine, now: Date, calendar: Calendar) -> MateRoutine {
        var copy = routine
        copy.lastRunFinishedAt = now
        copy.pendingRetryAt = nil
        // New runs advance at acceptance. Legacy callers without launch accounting
        // still advance here. Completion must not drift a running schedule.
        if routine.runCount == nil {
            copy.lastRunAt = now
            copy.nextRunAt = routine.schedule.advance(from: routine.nextRunAt, now: now, calendar: calendar)
        }
        return copy
    }

    static func recordSuccess(
        _ routine: MateRoutine,
        now: Date,
        calendar: Calendar,
        status: String
    ) -> MateRoutine {
        var copy = finish(routine, now: now, calendar: calendar)
        copy.consecutiveFailures = 0
        copy.lastRunFailed = false
        copy.lastStatusMessage = status
        copy.autoRetried = nil
        return appendingRun(copy, startedFrom: routine, now: now, outcome: .succeeded, status: status)
    }

    static func recordFailure(
        _ routine: MateRoutine,
        now: Date,
        calendar: Calendar,
        status: String
    ) -> MateRoutine {
        var copy = finish(routine, now: now, calendar: calendar)
        copy.consecutiveFailures += 1
        copy.lastRunFailed = true
        copy.lastStatusMessage = status
        if copy.consecutiveFailures >= failurePauseCount {
            copy.pausedReason = "Paused after \(failurePauseCount) failed runs. \(status)"
        }
        return appendingRun(copy, startedFrom: routine, now: now, outcome: .failed, status: status)
    }

    static func recordInterrupted(_ routine: MateRoutine, now: Date, calendar: Calendar) -> MateRoutine {
        var copy = finish(routine, now: now, calendar: calendar)
        copy.lastRunFailed = true
        copy.lastStatusMessage = interruptedStatus
        return appendingRun(copy, startedFrom: routine, now: now, outcome: .interrupted, status: interruptedStatus)
    }

    static func pauseForArchivedMate(_ routine: MateRoutine) -> MateRoutine {
        var copy = routine
        copy.pausedReason = archivedPauseReason
        return copy
    }

    static func pauseManually(_ routine: MateRoutine) -> MateRoutine {
        var copy = routine
        copy.pausedReason = manualPauseReason
        return copy
    }

    static func resume(_ routine: MateRoutine, now: Date, calendar: Calendar) -> MateRoutine {
        var copy = routine
        copy.pausedReason = nil
        copy.enabled = true
        copy.pendingRetryAt = nil
        copy.consecutiveFailures = 0
        copy.nextRunAt = routine.schedule.advance(from: now, now: now, calendar: calendar)
        return copy
    }
}

nonisolated enum MateRoutineMessage {
    static func format(task: String, outcome: String) -> String {
        let taskLine = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcomeText = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !taskLine.isEmpty else { return outcomeText }
        guard !outcomeText.isEmpty else { return taskLine }
        if outcomeText == taskLine || outcomeText.hasPrefix(taskLine + "\n") {
            return outcomeText
        }
        return "\(taskLine)\n\(outcomeText)"
    }
}

struct ActiveRoutineTurn: Equatable {
    let routineID: UUID
    let mateID: UUID
    let task: String
    let writesIntoOpenChat: Bool
    var promptRoutine: MateRoutine? = nil
    /// A one-off the person just agreed to, not a scheduled run.
    var isWake: Bool = false
}

enum MateRoutineTurnOutcome: Equatable {
    case success(String)
    case failure(String)
    case cancelled
}

enum MateRoutineKickoff: Equatable {
    case started
    case busy
    case failed(String)
}
