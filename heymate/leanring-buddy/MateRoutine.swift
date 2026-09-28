//
//  MateRoutine.swift
//  leanring-buddy
//
//  A schedule owned by one mate. Due-ness, catch-up, and failure pauses are
//  pure so tests never start a timer.
//

import Foundation

nonisolated enum RoutineSchedule: Codable, Equatable {
    case daily(hour: Int, minute: Int)
    case everyHours(Int)

    var summary: String {
        switch self {
        case .daily(let hour, let minute):
            let suffix = hour < 12 ? "am" : "pm"
            let shownHour = hour % 12 == 0 ? 12 : hour % 12
            return String(format: "Daily at %d:%02d%@", shownHour, minute, suffix)
        case .everyHours(let hours):
            let count = max(1, hours)
            return count == 1 ? "Every hour" : "Every \(count) hours"
        }
    }

    /// A phrase `RoutinePhraseParser` accepts for this schedule.
    var instructionPhrase: String {
        switch self {
        case .daily(let hour, let minute):
            let suffix = hour < 12 ? "am" : "pm"
            let shownHour = hour % 12 == 0 ? 12 : hour % 12
            if minute == 0 {
                return "daily at \(shownHour)\(suffix)"
            }
            return String(format: "daily at %d:%02d%@", shownHour, minute, suffix)
        case .everyHours(let hours):
            return "every \(max(1, hours)) hour\(max(1, hours) == 1 ? "" : "s")"
        }
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
}

extension MateRoutine {
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
        return copy
    }
}

nonisolated enum MateRoutineAccounting {
    static let networkWaitStatus = "I'll run it when the internet is back"
    static let failurePauseCount = 3
    static let archivedPauseReason = "Paused because this mate is archived."
    static let manualPauseReason = "Paused by you."

    static func isDue(_ routine: MateRoutine, now: Date) -> Bool {
        guard routine.enabled, routine.pausedReason == nil else { return false }
        return routine.nextRunAt <= now
    }

    static func markWaitingForNetwork(_ routine: MateRoutine) -> MateRoutine {
        var copy = routine
        copy.lastStatusMessage = networkWaitStatus
        return copy
    }

    static func recordSuccess(
        _ routine: MateRoutine,
        now: Date,
        calendar: Calendar,
        status: String
    ) -> MateRoutine {
        var copy = routine
        copy.consecutiveFailures = 0
        copy.lastRunAt = now
        copy.lastStatusMessage = status
        copy.nextRunAt = routine.schedule.advance(from: routine.nextRunAt, now: now, calendar: calendar)
        return copy
    }

    static func recordFailure(
        _ routine: MateRoutine,
        now: Date,
        calendar: Calendar,
        status: String
    ) -> MateRoutine {
        var copy = routine
        copy.consecutiveFailures += 1
        copy.lastRunAt = now
        copy.lastStatusMessage = status
        copy.nextRunAt = routine.schedule.advance(from: routine.nextRunAt, now: now, calendar: calendar)
        if copy.consecutiveFailures >= failurePauseCount {
            copy.pausedReason = "Paused after \(failurePauseCount) failed runs. \(status)"
        }
        return copy
    }

    static func recordInterrupted(_ routine: MateRoutine, now: Date, calendar: Calendar) -> MateRoutine {
        var copy = routine
        copy.lastRunAt = now
        copy.lastStatusMessage = "Interrupted. I'll try the next slot."
        copy.nextRunAt = routine.schedule.advance(from: routine.nextRunAt, now: now, calendar: calendar)
        return copy
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
