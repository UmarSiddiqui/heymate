//
//  RoutinePhraseParser.swift
//  leanring-buddy
//
//  Turns a short instruction into a routine on a mate the caller already chose.
//

import Foundation

nonisolated enum RoutinePhraseParser {
    static let invalidScheduleMessage = "Say when it should run, like every morning or every 3 hours."

    static func parse(
        _ text: String,
        mateID: UUID,
        now: Date,
        calendar: Calendar
    ) -> MateRoutine? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("?") else { return nil }
        guard let detected = detectSchedule(in: trimmed) else { return nil }
        let task = taskText(in: trimmed, removing: detected.range)
        let schedule = detected.schedule
        return MateRoutine(
            id: UUID(),
            mateID: mateID,
            task: task.isEmpty ? "Check in" : task,
            enabled: true,
            schedule: schedule,
            nextRunAt: schedule.advance(from: now, now: now, calendar: calendar),
            lastRunAt: nil,
            lastStatusMessage: nil,
            consecutiveFailures: 0,
            pausedReason: nil
        )
    }

    private struct DetectedSchedule {
        let schedule: RoutineSchedule
        let range: Range<String.Index>
    }

    private static func detectSchedule(in text: String) -> DetectedSchedule? {
        if let range = text.range(of: #"every\s+few\s+hours"#, options: [.regularExpression, .caseInsensitive]) {
            return DetectedSchedule(schedule: .everyHours(3), range: range)
        }
        if let match = firstMatch(#"every\s+(\d+)\s+hours?"#, in: text),
           let hours = Int(match.capture), hours >= 1 {
            return DetectedSchedule(schedule: .everyHours(hours), range: match.range)
        }
        if let range = text.range(of: #"every\s+morning"#, options: [.regularExpression, .caseInsensitive]) {
            return DetectedSchedule(schedule: .daily(hour: 8, minute: 0), range: range)
        }
        if let match = firstMatch(#"daily\s+at\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"#, in: text),
           let hour = clockHour(match) {
            return DetectedSchedule(
                schedule: .daily(hour: hour, minute: clockMinute(match)),
                range: match.range
            )
        }
        return nil
    }

    private struct PhraseMatch {
        let range: Range<String.Index>
        let groups: [String]
        var capture: String { groups.first ?? "" }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> PhraseMatch? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let full = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: full),
              let range = Range(match.range, in: text) else { return nil }
        var groups: [String] = []
        if match.numberOfRanges > 1 {
            for index in 1..<match.numberOfRanges {
                if let groupRange = Range(match.range(at: index), in: text) {
                    groups.append(String(text[groupRange]))
                } else {
                    groups.append("")
                }
            }
        }
        return PhraseMatch(range: range, groups: groups)
    }

    private static func clockHour(_ match: PhraseMatch) -> Int? {
        guard let raw = Int(match.groups.first ?? "") else { return nil }
        let suffix = match.groups.count >= 3 ? match.groups[2].lowercased() : ""
        switch suffix {
        case "am":
            guard (1...12).contains(raw) else { return nil }
            return raw == 12 ? 0 : raw
        case "pm":
            guard (1...12).contains(raw) else { return nil }
            return raw == 12 ? 12 : raw + 12
        default:
            guard (0...23).contains(raw) else { return nil }
            return raw
        }
    }

    private static func clockMinute(_ match: PhraseMatch) -> Int {
        guard match.groups.count >= 2, let minute = Int(match.groups[1]) else { return 0 }
        return min(59, max(0, minute))
    }

    private static func taskText(in text: String, removing range: Range<String.Index>) -> String {
        var remainder = text
        remainder.removeSubrange(range)
        let trimmed = remainder.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        )
        return trimmed.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
