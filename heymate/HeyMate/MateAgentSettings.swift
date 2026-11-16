//
//  MateAgentSettings.swift
//  HeyMate
//
//  Per-mate settings added with the agent settings redesign, and the pure
//  rules that read them: quiet hours, notification gating, stricter-only
//  approval mode, and limits. No UI, no timers, no file IO; the store that
//  saves these lives in MateAgentSettingsStore.swift.
//
//  These live in their own small file under HeyMateDataDirectory rather than
//  on the Mate record, so a Mate written by this build stays exactly what the
//  previous release reads. Every field decodes with a default, so a file
//  from a later build with extra fields still loads.
//

import Foundation

// MARK: - Approval

/// A mate can only be made stricter than HeyMate's approval mode, never looser.
nonisolated enum MateApprovalOverride: String, Codable, CaseIterable, Sendable {
    /// Follow HeyMate's Ask me / Full access.
    case inherit
    /// Ask every time: Full access does not apply and allow rules are set aside.
    case alwaysAsk
}

nonisolated enum MatePermissionResolver {
    /// The approval mode in force for one mate.
    static func effectiveMode(global: ApprovalMode, override: MateApprovalOverride) -> ApprovalMode {
        override == .alwaysAsk ? .askMe : global
    }

    /// A stored rule's decision after the mate's override. "Always ask" sets
    /// allow rules aside (the card decides); ask and deny rules still apply.
    static func ruleDecision(
        _ decision: MateApprovalRule.Decision?, override: MateApprovalOverride
    ) -> MateApprovalRule.Decision? {
        override == .alwaysAsk && decision == .allow ? nil : decision
    }
}

// MARK: - Quiet hours

/// A daily window, in minutes after local midnight, that may wrap past midnight.
nonisolated struct MateQuietHours: Codable, Equatable, Sendable {
    /// Matches the heartbeat's former hard-coded window: nothing from 21:00 to 07:00.
    static let defaultStartMinute = 21 * 60
    static let defaultEndMinute = 7 * 60
    static let minutesPerDay = 24 * 60

    var enabled = true
    var startMinute = defaultStartMinute
    var endMinute = defaultEndMinute

    init(enabled: Bool = true, startMinute: Int = defaultStartMinute, endMinute: Int = defaultEndMinute) {
        self.enabled = enabled
        self.startMinute = Self.clamped(startMinute)
        self.endMinute = Self.clamped(endMinute)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        startMinute = Self.clamped(try container.decodeIfPresent(Int.self, forKey: .startMinute) ?? Self.defaultStartMinute)
        endMinute = Self.clamped(try container.decodeIfPresent(Int.self, forKey: .endMinute) ?? Self.defaultEndMinute)
    }

    static func clamped(_ minute: Int) -> Int {
        ((minute % minutesPerDay) + minutesPerDay) % minutesPerDay
    }

    /// An empty window (start == end) is never quiet.
    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, startMinute != endMinute else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }

    /// When the quiet window that holds `date` ends, or nil when `date` is not quiet.
    func end(after date: Date, calendar: Calendar = .current) -> Date? {
        guard contains(date, calendar: calendar) else { return nil }
        let day = calendar.startOfDay(for: date)
        guard let todayEnd = calendar.date(byAdding: .minute, value: endMinute, to: day) else { return nil }
        if todayEnd > date { return todayEnd }
        return calendar.date(byAdding: .day, value: 1, to: todayEnd)
    }

    /// "9:00 PM" style clock text for one minute-of-day.
    static func clockText(_ minute: Int, calendar: Calendar = .current) -> String {
        let clamped = clamped(minute)
        var parts = DateComponents()
        parts.hour = clamped / 60
        parts.minute = clamped % 60
        let date = calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
        return date.formatted(date: .omitted, time: .shortened)
    }

    var summary: String {
        guard enabled else { return "Off. Check-ins and routine notices can arrive at any hour." }
        guard startMinute != endMinute else { return "Start and end are the same, so there are no quiet hours." }
        return "\(Self.clockText(startMinute)) to \(Self.clockText(endMinute))"
    }
}

// MARK: - Notifications

nonisolated struct MateNotificationPreferences: Codable, Equatable, Sendable {
    var proposals = true
    var finishedWork = true
    var needsInput = true
    var failedRoutine = true

    init(proposals: Bool = true, finishedWork: Bool = true, needsInput: Bool = true, failedRoutine: Bool = true) {
        self.proposals = proposals
        self.finishedWork = finishedWork
        self.needsInput = needsInput
        self.failedRoutine = failedRoutine
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        proposals = try container.decodeIfPresent(Bool.self, forKey: .proposals) ?? true
        finishedWork = try container.decodeIfPresent(Bool.self, forKey: .finishedWork) ?? true
        needsInput = try container.decodeIfPresent(Bool.self, forKey: .needsInput) ?? true
        failedRoutine = try container.decodeIfPresent(Bool.self, forKey: .failedRoutine) ?? true
    }

    func allows(_ kind: MateNotificationKind) -> Bool {
        switch kind {
        case .proposal: proposals
        case .finishedWork: finishedWork
        case .needsInput: needsInput
        case .failed: failedRoutine
        }
    }
}

nonisolated enum MateNotificationKind: String, CaseIterable, Sendable {
    case proposal
    case finishedWork
    case needsInput
    case failed
}

nonisolated enum MateNotificationGate {
    enum Decision: Equatable, Sendable {
        case deliver
        case deliverAt(Date)
        case drop
    }

    /// Whether and when one notification for a mate goes out.
    /// - Off for this kind: dropped.
    /// - Finished work for a chat the person is looking at: dropped (they saw it).
    /// - Inside quiet hours, for unattended work (proposals, routines,
    ///   background jobs) or anything except a question: held until they end.
    ///   A question that blocks a task the person started still reaches them.
    static func decide(
        _ kind: MateNotificationKind,
        preferences: MateNotificationPreferences,
        quietHours: MateQuietHours,
        isWatching: Bool,
        isUnattended: Bool,
        now: Date,
        calendar: Calendar = .current
    ) -> Decision {
        guard preferences.allows(kind) else { return .drop }
        if kind == .finishedWork, isWatching { return .drop }
        let holdsInQuiet = isUnattended || kind != .needsInput
        if holdsInQuiet, let end = quietHours.end(after: now, calendar: calendar) { return .deliverAt(end) }
        return .deliver
    }
}

// MARK: - Limits

nonisolated struct MateAgentLimits: Codable, Equatable, Sendable {
    /// Nil follows HeyMate's default for each.
    var maxContinuations: Int?
    var routineMinutes: Int?
    var heartbeatsPerDay: Int?

    static let continuationRange = 0...MateAgentContinuation.maxContinuations * 4
    static let routineMinuteRange = 5...(24 * 60)
    static let heartbeatRange = 0...MateHeartbeatSchedule.slotsPerDay
    static let defaultHeartbeatsPerDay = MateHeartbeatSchedule.slotsPerDay

    init(maxContinuations: Int? = nil, routineMinutes: Int? = nil, heartbeatsPerDay: Int? = nil) {
        self.maxContinuations = maxContinuations
        self.routineMinutes = routineMinutes
        self.heartbeatsPerDay = heartbeatsPerDay
    }

    var effectiveMaxContinuations: Int {
        maxContinuations.map { min(max($0, Self.continuationRange.lowerBound), Self.continuationRange.upperBound) }
            ?? MateAgentContinuation.maxContinuations
    }

    /// Nil: a routine without its own limit runs until it finishes.
    var effectiveRoutineMinutes: Int? {
        routineMinutes.map { min(max($0, Self.routineMinuteRange.lowerBound), Self.routineMinuteRange.upperBound) }
    }

    var effectiveHeartbeatsPerDay: Int {
        heartbeatsPerDay.map { min(max($0, Self.heartbeatRange.lowerBound), Self.heartbeatRange.upperBound) }
            ?? Self.defaultHeartbeatsPerDay
    }

    /// The routine with this mate's default time limit filled in when it has none.
    func applyingRoutineDefault(to routine: MateRoutine) -> MateRoutine {
        guard routine.maxRunMinutes == nil, let minutes = effectiveRoutineMinutes else { return routine }
        var copy = routine
        copy.maxRunMinutes = minutes
        return copy
    }
}

// MARK: - Today's activity

/// Counts only, for one local day. No tokens, no prices.
nonisolated struct MateActivityDay: Codable, Equatable, Sendable {
    enum Counter: String, CaseIterable, Sendable { case turns, heartbeats, routineRuns }

    var day: String
    var turns = 0
    var heartbeats = 0
    var routineRuns = 0

    init(day: String, turns: Int = 0, heartbeats: Int = 0, routineRuns: Int = 0) {
        self.day = day
        self.turns = turns
        self.heartbeats = heartbeats
        self.routineRuns = routineRuns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decodeIfPresent(String.self, forKey: .day) ?? ""
        turns = try container.decodeIfPresent(Int.self, forKey: .turns) ?? 0
        heartbeats = try container.decodeIfPresent(Int.self, forKey: .heartbeats) ?? 0
        routineRuns = try container.decodeIfPresent(Int.self, forKey: .routineRuns) ?? 0
    }

    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// A day's record after one more of `counter`; a new day starts from zero.
    static func incremented(_ current: MateActivityDay?, _ counter: Counter, now: Date,
                            calendar: Calendar = .current) -> MateActivityDay {
        let today = key(for: now, calendar: calendar)
        var day = MateActivityDay(day: today)
        if let current, current.day == today { day = current }
        switch counter {
        case .turns: day.turns += 1
        case .heartbeats: day.heartbeats += 1
        case .routineRuns: day.routineRuns += 1
        }
        return day
    }

    /// Today's counts, or zeros when the record is from another day.
    static func today(_ current: MateActivityDay?, now: Date, calendar: Calendar = .current) -> MateActivityDay {
        let today = key(for: now, calendar: calendar)
        if let current, current.day == today { return current }
        return MateActivityDay(day: today)
    }
}

// MARK: - Choosing a folder

nonisolated enum MateFolderChoice {
    /// Why a picked folder can't be a mate's folder, or nil when it can.
    /// A mate writes freely in its folder, so whole-disk, home, and system
    /// folders are refused.
    static func refusal(for folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        if path == "/" || path == homePath { return "Pick a folder inside your home folder, not the whole thing." }
        let system = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/private", "/etc", "/var"]
        if system.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) && !path.hasPrefix(homePath + "/") {
            return "That's a system folder. Pick one of your own folders."
        }
        let homeLibrary = homePath + "/Library"
        if path == homeLibrary || path.hasPrefix(homeLibrary + "/") { return "Pick a folder outside Library." }
        return nil
    }
}

// MARK: - One mate's settings

nonisolated struct MateAgentSettings: Codable, Equatable, Sendable {
    var approval: MateApprovalOverride = .inherit
    var quietHours = MateQuietHours()
    var notifications = MateNotificationPreferences()
    var limits = MateAgentLimits()
    /// Whether the live browser panel in this mate's chat starts open.
    var browserPanelStartsOpen = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        approval = (try? container.decodeIfPresent(MateApprovalOverride.self, forKey: .approval)) ?? .inherit
        quietHours = (try? container.decodeIfPresent(MateQuietHours.self, forKey: .quietHours)) ?? MateQuietHours()
        notifications = (try? container.decodeIfPresent(MateNotificationPreferences.self, forKey: .notifications))
            ?? MateNotificationPreferences()
        limits = (try? container.decodeIfPresent(MateAgentLimits.self, forKey: .limits)) ?? MateAgentLimits()
        browserPanelStartsOpen = (try? container.decodeIfPresent(Bool.self, forKey: .browserPanelStartsOpen)) ?? true
    }
}

/// The whole file: settings and today's counts, keyed by mate UUID string.
nonisolated struct MateAgentSettingsFile: Codable, Equatable, Sendable {
    var mates: [String: MateAgentSettings] = [:]
    var activity: [String: MateActivityDay] = [:]

    init(mates: [String: MateAgentSettings] = [:], activity: [String: MateActivityDay] = [:]) {
        self.mates = mates
        self.activity = activity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mates = (try? container.decodeIfPresent([String: MateAgentSettings].self, forKey: .mates)) ?? [:]
        activity = (try? container.decodeIfPresent([String: MateActivityDay].self, forKey: .activity)) ?? [:]
    }
}
