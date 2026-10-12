//
//  HarnessTurnNotes.swift
//  HeyMate
//
//  Short, state-driven notes that ride on the user message for one turn.
//  They stay out of the standing system prompt. Nothing here talks to a
//  model or a store.
//

import Foundation

enum HarnessTurnKind: Equatable {
    case conversation
    case routine(isFirstRun: Bool)
    case standingOrder
}

enum HarnessJobState: Equatable {
    case running
    case waiting
}

struct HarnessJobNote: Equatable {
    var mateName: String
    var title: String
    var state: HarnessJobState
}

struct HarnessExchange: Equatable {
    var user: String
    var assistant: String
}

struct HarnessRoutineLine: Equatable {
    var title: String
    var scheduleSummary: String
    var isPaused: Bool
    var task: String
}

struct HarnessTurnNoteInput: Equatable {
    var now: Date
    var timeZone: TimeZone
    var hasScreenshot: Bool
    var userActedWhileThinking: Bool
    var isRetryOfFailedRun: Bool
    var kind: HarnessTurnKind
    var runningJobs: [HarnessJobNote] = []
    var recentExchanges: [HarnessExchange] = []
    var routines: [HarnessRoutineLine] = []
    var includeRunningJobs: Bool = false
    var includeRecentExchanges: Bool = false
    var includeRoutines: Bool = false
}

enum HarnessTurnNotes {
    static let recentExchangeLimit = 3
    static let runningJobLimit = 6
    static let lineLimit = 160

    static func prefix(_ input: HarnessTurnNoteInput) -> String {
        var lines: [String] = []
        lines.append(dateLine(now: input.now, timeZone: input.timeZone))
        if !input.hasScreenshot {
            lines.append("No screenshot is attached.")
        }
        if input.userActedWhileThinking {
            lines.append("The user acted while you were thinking.")
        }
        if input.isRetryOfFailedRun {
            lines.append("This continues a failed run. Check what is already done and continue.")
        }
        switch input.kind {
        case .conversation:
            break
        case .routine(let isFirstRun):
            lines.append("This brief was written by HeyMate.")
            if !isFirstRun {
                lines.append("Report only what is new.")
            }
        case .standingOrder:
            lines.append("This brief was written by HeyMate.")
        }
        if input.includeRunningJobs, !input.runningJobs.isEmpty {
            lines.append(runningJobsBlock(input.runningJobs))
        }
        if input.includeRecentExchanges, !input.recentExchanges.isEmpty {
            lines.append(recentExchangesBlock(input.recentExchanges))
        }
        if input.includeRoutines {
            lines.append(routinesBlock(input.routines))
        }
        return lines.joined(separator: "\n")
    }

    static func userMessage(notes: String, transcript: String) -> String {
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedNotes.isEmpty { return trimmedTranscript }
        if trimmedTranscript.isEmpty { return trimmedNotes }
        return trimmedNotes + "\n\n" + trimmedTranscript
    }

    /// The user's own words from a noted message. Notes always open with the
    /// date line and never contain a blank line, so the first blank line ends
    /// them.
    static func transcript(fromUserMessage message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("Today is "), let gap = trimmed.range(of: "\n\n") else { return trimmed }
        return trimmed[gap.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func dateLine(now: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE d MMMM yyyy"
        return "Today is \(formatter.string(from: now)) (\(timeZone.identifier))."
    }

    private static func runningJobsBlock(_ jobs: [HarnessJobNote]) -> String {
        let rows = jobs.prefix(runningJobLimit).map { job in
            let state: String
            switch job.state {
            case .running:
                state = "running"
            case .waiting:
                state = "waiting"
            }
            return "- \(clipped(job.mateName, limit: 40)) — \(clipped(job.title, limit: 80)) (\(state))"
        }
        return (["Agents still working:"] + rows).joined(separator: "\n")
    }

    private static func recentExchangesBlock(_ exchanges: [HarnessExchange]) -> String {
        var rows = ["Recent companion exchanges. Use only if the transcript refers to them."]
        for exchange in exchanges.suffix(recentExchangeLimit) {
            rows.append("You: \(clipped(exchange.user, limit: lineLimit))")
            rows.append("HeyMate: \(clipped(exchange.assistant, limit: lineLimit))")
        }
        return rows.joined(separator: "\n")
    }

    private static func routinesBlock(_ routines: [HarnessRoutineLine]) -> String {
        var rows = ["Routines for this agent. This list is the one that is live:"]
        if routines.isEmpty {
            rows.append("- none")
            return rows.joined(separator: "\n")
        }
        for routine in routines.prefix(8) {
            let state = routine.isPaused ? "paused" : "on"
            rows.append(
                "- \(clipped(routine.title, limit: 60)) — \(routine.scheduleSummary) — \(state). \(clipped(routine.task, limit: lineLimit))"
            )
        }
        return rows.joined(separator: "\n")
    }

    private static func clipped(_ text: String, limit: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }
}

struct HarnessReplyChrome: Equatable {
    var nextActions: [String]
    var artifactPaths: [String]
}

struct PendingDestructiveWork: Equatable, Identifiable {
    let id: UUID
    var transcript: String
}

struct PendingMateQuestion: Equatable, Identifiable {
    let id: UUID
    let mateID: UUID
    var runID: UUID?
    var prompt: String
}

enum HarnessToolName: String, Equatable, CaseIterable {
    case startMateWork = "start_mate_work"
    case sendToMate = "send_to_mate"
    case answerRequest = "answer_request"
    case askDeeper = "ask_deeper"
}

struct HarnessToolRequest: Equatable {
    var name: HarnessToolName
    var arguments: [String: String]
}

enum HarnessToolRequestParser {
    static func parse(_ text: String) -> HarnessToolRequest? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{") {
            return request(fromJSONObject: trimmed)
        }
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? trimmed
        if let name = HarnessToolName(rawValue: firstLine) {
            return HarnessToolRequest(name: name, arguments: [:])
        }
        guard let space = firstLine.firstIndex(of: " ") else { return nil }
        let namePart = String(firstLine[..<space])
        guard let name = HarnessToolName(rawValue: namePart) else { return nil }
        let rest = firstLine[firstLine.index(after: space)...].trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("{"), let arguments = stringArguments(fromJSONObject: rest) else { return nil }
        return HarnessToolRequest(name: name, arguments: arguments)
    }

    static func stringArguments(_ arguments: [String: Any]) -> [String: String] {
        var strings: [String: String] = [:]
        for (key, value) in arguments {
            if let text = value as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { strings[key] = trimmed }
            } else if let number = value as? NSNumber {
                strings[key] = number.stringValue
            }
        }
        return strings
    }

    static func argument(_ arguments: [String: String], keys: [String]) -> String? {
        for key in keys {
            if let value = arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func request(fromJSONObject text: String) -> HarnessToolRequest? {
        guard let arguments = stringArguments(fromJSONObject: text) else { return nil }
        guard let rawName = arguments["tool"] ?? arguments["name"],
              let name = HarnessToolName(rawValue: rawName) else { return nil }
        var payload = arguments
        payload["tool"] = nil
        payload["name"] = nil
        return HarnessToolRequest(name: name, arguments: payload)
    }

    private static func stringArguments(fromJSONObject text: String) -> [String: String]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return stringArguments(object)
    }
}

enum HarnessRoutineChange: Equatable {
    case upsert(MateRoutine)
    case delete(UUID)
}

enum HarnessRoutineDeclaration {
    static func schedule(everyMinutes: Int?) -> RoutineSchedule {
        let minutes = max(1, everyMinutes ?? 60)
        if minutes % 60 == 0 {
            return .everyHours(minutes / 60)
        }
        return .everyHours(max(1, minutes / 60))
    }

    static func title(of routine: MateRoutine) -> String {
        let first = routine.task.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? routine.task
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? routine.task : trimmed
    }

    static func matches(_ routine: MateRoutine, title: String) -> Bool {
        let needle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, routine.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        if routine.task.compare(needle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return true
        }
        return self.title(of: routine).compare(needle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    static func changes(
        for request: AgentRoutineRequest,
        mateID: UUID,
        existing: [MateRoutine],
        now: Date,
        calendar: Calendar
    ) -> [HarnessRoutineChange] {
        let titled = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (titled?.isEmpty == false) ? titled : nil
        switch request.action {
        case .create:
            return [upsert(
                matching: title,
                mateID: mateID,
                existing: existing,
                everyMinutes: request.everyMinutes,
                task: storedTask(title: title, work: request.task),
                now: now,
                calendar: calendar,
                createIfMissing: true
            )].compactMap { $0 }
        case .update:
            let renamed = request.newTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let nextTitle = (renamed?.isEmpty == false) ? renamed : title
            return [upsert(
                matching: title,
                mateID: mateID,
                existing: existing,
                everyMinutes: request.everyMinutes,
                task: storedTask(title: nextTitle, work: request.task),
                now: now,
                calendar: calendar,
                createIfMissing: false
            )].compactMap { $0 }
        case .pause:
            guard let title, let routine = match(title, mateID: mateID, existing: existing) else { return [] }
            return [.upsert(MateRoutineAccounting.pauseManually(routine))]
        case .resume:
            guard let title, let routine = match(title, mateID: mateID, existing: existing) else { return [] }
            return [.upsert(MateRoutineAccounting.resume(routine, now: now, calendar: calendar))]
        case .delete:
            guard let title, let routine = match(title, mateID: mateID, existing: existing) else { return [] }
            return [.delete(routine.id)]
        }
    }

    private static func match(_ title: String, mateID: UUID, existing: [MateRoutine]) -> MateRoutine? {
        existing.first { $0.mateID == mateID && matches($0, title: title) }
    }

    private static func storedTask(title: String?, work: String?) -> String {
        let trimmedWork = work?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedTitle.isEmpty { return trimmedWork.isEmpty ? "Check in" : trimmedWork }
        if trimmedWork.isEmpty || trimmedWork.compare(trimmedTitle, options: .caseInsensitive) == .orderedSame {
            return trimmedTitle
        }
        return trimmedTitle + "\n" + trimmedWork
    }

    private static func upsert(
        matching title: String?,
        mateID: UUID,
        existing: [MateRoutine],
        everyMinutes: Int?,
        task: String,
        now: Date,
        calendar: Calendar,
        createIfMissing: Bool
    ) -> HarnessRoutineChange? {
        let schedule = schedule(everyMinutes: everyMinutes)
        if let title, let existing = match(title, mateID: mateID, existing: existing) {
            var copy = existing
            copy.task = task
            copy.schedule = schedule
            copy.nextRunAt = schedule.advance(from: now, now: now, calendar: calendar)
            return .upsert(copy)
        }
        guard createIfMissing else { return nil }
        let routine = MateRoutine(
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
        return .upsert(routine)
    }
}
