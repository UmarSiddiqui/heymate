//
//  BrainUsageLimit.swift
//  HeyMate
//
//  When a subscription brain says it is at its usage limit, a mate with a
//  backup brain keeps working on that backup and goes back to its own brain
//  once the limit should have reset. Reading the failure text never calls a
//  model.
//

import Foundation

nonisolated enum BrainUsageLimit {
    /// How long to stay on the backup when the failure does not say when
    /// the limit resets. A wrong guess only costs one more failed turn.
    static let defaultWait: TimeInterval = 60 * 60
    /// A reset further out than this is treated as a parse mistake.
    static let longestWait: TimeInterval = 8 * 24 * 60 * 60

    private static let limitMarkers = [
        "usage limit",
        "hit your limit",
        "limit reached",
        "rate limit",
        "rate_limit",
        "too many requests",
        "weekly limit",
        "5-hour limit",
    ]

    /// True when the failure means "this plan is used up for now", as
    /// opposed to signed out, offline, or a bug.
    static func isLimit(_ message: String) -> Bool {
        if SpokenFailure.classify(message: message) == .outOfCredits { return true }
        let lowered = message.lowercased()
        return limitMarkers.contains { lowered.contains($0) }
    }

    /// When the limit should be over, read from the failure where it says.
    /// Understands "…limit reached|1731362400", "try again in 2 hours 13
    /// minutes", and "resets 3pm" / "try again at 3:05 PM".
    static func resetDate(from message: String, now: Date, calendar: Calendar = .current) -> Date {
        if let date = epochReset(message, now: now) { return date }
        if let date = relativeReset(message, now: now) { return date }
        if let date = clockReset(message, now: now, calendar: calendar) { return date }
        return now.addingTimeInterval(defaultWait)
    }

    private static func sane(_ date: Date, now: Date) -> Date? {
        let wait = date.timeIntervalSince(now)
        guard wait > 0, wait <= longestWait else { return nil }
        return date
    }

    private static func epochReset(_ message: String, now: Date) -> Date? {
        guard let range = message.range(of: #"\|\s*(\d{10})"#, options: .regularExpression) else { return nil }
        let digits = message[range].filter(\.isNumber)
        guard let seconds = TimeInterval(digits) else { return nil }
        return sane(Date(timeIntervalSince1970: seconds), now: now)
    }

    private static func relativeReset(_ message: String, now: Date) -> Date? {
        let lowered = message.lowercased()
        guard let anchor = lowered.range(of: #"(try again|resets?|available again)\s+in\s+"#, options: .regularExpression) else { return nil }
        let tail = String(lowered[anchor.upperBound...].prefix(48))
        var seconds: TimeInterval = 0
        let units: [(String, TimeInterval)] = [
            (#"(\d+)\s*(days?|d\b)"#, 86_400),
            (#"(\d+)\s*(hours?|hrs?|h\b)"#, 3_600),
            (#"(\d+)\s*(minutes?|mins?|m\b)"#, 60),
            (#"(\d+)\s*(seconds?|secs?|s\b)"#, 1),
        ]
        for (pattern, scale) in units {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
                  let valueRange = Range(match.range(at: 1), in: tail),
                  let value = Double(tail[valueRange]) else { continue }
            seconds += value * scale
        }
        guard seconds > 0 else { return nil }
        return sane(now.addingTimeInterval(seconds), now: now)
    }

    private static func clockReset(_ message: String, now: Date, calendar: Calendar) -> Date? {
        let lowered = message.lowercased()
        let pattern = #"(?:resets?|try again at|available again at)\s*(?:at\s*)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
              let hourRange = Range(match.range(at: 1), in: lowered),
              let meridiemRange = Range(match.range(at: 3), in: lowered),
              var hour = Int(lowered[hourRange]), (1...12).contains(hour) else { return nil }
        let minute = Range(match.range(at: 2), in: lowered).flatMap { Int(lowered[$0]) } ?? 0
        if lowered[meridiemRange] == "pm", hour != 12 { hour += 12 }
        if lowered[meridiemRange] == "am", hour == 12 { hour = 0 }
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = min(59, max(0, minute))
        guard var candidate = calendar.date(from: components) else { return nil }
        if candidate <= now, let next = calendar.date(byAdding: .day, value: 1, to: candidate) { candidate = next }
        return sane(candidate, now: now)
    }
}

/// Which brains are at their limit and until when. Kept in UserDefaults so
/// a relaunch does not send the next turn straight back into the wall.
nonisolated struct BrainLimitLedger {
    static let defaultsKey = "heymate.brainLimitedUntil"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var stored: [String: Double] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:]
    }

    func limitedUntil(_ brain: AgentBrain, now: Date = Date()) -> Date? {
        guard let seconds = stored[brain.rawValue] else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        return date > now ? date : nil
    }

    func isLimited(_ brain: AgentBrain, now: Date = Date()) -> Bool {
        limitedUntil(brain, now: now) != nil
    }

    func markLimited(_ brain: AgentBrain, until date: Date) {
        var next = stored
        next[brain.rawValue] = date.timeIntervalSince1970
        defaults.set(next, forKey: Self.defaultsKey)
    }

    func clear(_ brain: AgentBrain) {
        var next = stored
        next.removeValue(forKey: brain.rawValue)
        defaults.set(next, forKey: Self.defaultsKey)
    }

    /// The brain a mate should use right now: its own, or its backup while
    /// its own is limited and the backup is not.
    func effectiveBrain(primary: AgentBrain, backup: AgentBrain?, now: Date = Date()) -> AgentBrain {
        guard let backup, backup != primary, isLimited(primary, now: now), !isLimited(backup, now: now) else {
            return primary
        }
        return backup
    }
}
