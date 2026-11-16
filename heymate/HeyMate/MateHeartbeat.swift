//
//  MateHeartbeat.swift
//  HeyMate
//
//  A mate's heartbeat: a short, read-only look at its own context, at most
//  twice a day, that may come back with up to three proposals for work. This
//  file is the pure part: when one is due, skip fatigue, parsing the model's
//  answer, dedupe, and the context the turn is given. No UI, no timers, no
//  model calls. Replaces DailySuggestions' string templates; its approve /
//  skip / adjust actions and skip-twice fatigue live on here.
//

import Foundation

/// What the person can do with a proposal.
nonisolated enum MateHeartbeatAction: String, Equatable, CaseIterable, Sendable {
    case approve
    case skip
    case adjust
}

/// One proposal, as stored in the Inbox.
nonisolated struct MateHeartbeatProposal: Codable, Equatable, Sendable {
    static let lifetime: TimeInterval = 24 * 3600

    var id: UUID
    var title: String
    var whyNow: String
    var prompt: String
    var needsApproval: String?
    var createdAt: Date
    var expiresAt: Date

    func isExpired(now: Date = Date()) -> Bool { now >= expiresAt }
}

/// The record a mate keeps of what it proposed and what happened to it.
nonisolated struct MateHeartbeatRecord: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case open, approved, skipped, adjusted, expired

        var title: String {
            switch self {
            case .open: "still open"
            case .approved: "approved"
            case .skipped: "skipped"
            case .adjusted: "edited, then sent by the person"
            case .expired: "expired unanswered"
            }
        }
    }

    var id: UUID
    var title: String
    var createdAt: Date
    var outcome: Outcome
    var resolvedAt: Date?

    var normalizedTitle: String { MateHeartbeatText.normalized(title) }
}

/// Per-mate heartbeat settings and history.
nonisolated struct MateHeartbeatMateState: Codable, Equatable, Sendable {
    /// Nil follows the default (on for a mate with a folder or a connected app).
    var enabledOverride: Bool?
    var lastRunAt: Date?
    var runCount = 0
    var lastStatus: String?
    /// The hidden agent session a heartbeat runs in, apart from the visible chat.
    var sessionChatID = UUID()
    var records: [MateHeartbeatRecord] = []

    static let keptRecords = 60

    mutating func append(_ record: MateHeartbeatRecord) {
        records.append(record)
        if records.count > Self.keptRecords { records.removeFirst(records.count - Self.keptRecords) }
    }

    mutating func resolve(_ id: UUID, _ outcome: MateHeartbeatRecord.Outcome, now: Date) {
        guard let index = records.firstIndex(where: { $0.id == id && $0.outcome == .open }) else { return }
        records[index].outcome = outcome
        records[index].resolvedAt = now
    }
}

nonisolated struct MateHeartbeatState: Codable, Equatable, Sendable {
    var globalEnabled = true
    var mates: [UUID: MateHeartbeatMateState] = [:]
}

// MARK: - Who gets one

nonisolated enum MateHeartbeatEligibility {
    /// Archived mates never run. The default mate (which conducts others)
    /// stays off unless the person turns it on.
    static func isEnabled(
        globalEnabled: Bool, override: Bool?, archived: Bool, conductsOthers: Bool,
        hasFolder: Bool, hasConnectedApp: Bool
    ) -> Bool {
        guard globalEnabled, !archived else { return false }
        if let override { return override }
        return !conductsOthers && (hasFolder || hasConnectedApp)
    }
}

// MARK: - When

nonisolated enum MateHeartbeatSchedule {
    static let morningHour = 7
    static let afternoonHour = 14
    /// No heartbeat starts at or after this hour, so nothing arrives at night.
    static let quietHour = 21
    static let minimumGap: TimeInterval = 3 * 3600
    static let backoffInterval: TimeInterval = 3 * 24 * 3600
    /// Seconds without keyboard or mouse input after which the person is away.
    static let idleLimit: TimeInterval = 10 * 60

    /// The newest slot start at or before `now`: today 14:00, today 07:00, or nil before 07:00.
    static func latestSlot(now: Date, calendar: Calendar) -> Date? {
        let day = calendar.startOfDay(for: now)
        for hour in [afternoonHour, morningHour] {
            if let slot = calendar.date(byAdding: .hour, value: hour, to: day), slot <= now { return slot }
        }
        return nil
    }

    /// Due at the first activity after a slot opens. Missed slots and missed
    /// days collapse into one run; a backed-off mate waits three days.
    static func isDue(
        now: Date, lastRunAt: Date?, backedOff: Bool, userActive: Bool, calendar: Calendar
    ) -> Bool {
        guard userActive, calendar.component(.hour, from: now) < quietHour,
              let slot = latestSlot(now: now, calendar: calendar) else { return false }
        guard let lastRunAt else { return true }
        if lastRunAt >= slot { return false }
        let since = now.timeIntervalSince(lastRunAt)
        if since < minimumGap { return false }
        if backedOff, since < backoffInterval { return false }
        return true
    }
}

// MARK: - Fatigue

nonisolated enum MateHeartbeatFatigue {
    static let skipThreshold = 2
    static let suppression: TimeInterval = 30 * 24 * 3600
    static let backoffWindow = 5

    /// Titles skipped twice in the last 30 days, as last proposed.
    static func suppressedTitles(_ records: [MateHeartbeatRecord], now: Date) -> [String] {
        var skips: [String: (count: Int, last: Date, title: String)] = [:]
        for record in records where record.outcome == .skipped {
            let key = record.normalizedTitle
            guard !key.isEmpty else { continue }
            let at = record.resolvedAt ?? record.createdAt
            if let previous = skips[key] {
                skips[key] = (previous.count + 1, max(previous.last, at), at >= previous.last ? record.title : previous.title)
            } else {
                skips[key] = (1, at, record.title)
            }
        }
        return skips.values
            .filter { $0.count >= skipThreshold && now.timeIntervalSince($0.last) < suppression }
            .sorted { $0.last > $1.last }
            .map(\.title)
    }

    /// The last five proposals were all skipped or expired.
    static func isBackedOff(_ records: [MateHeartbeatRecord]) -> Bool {
        let latest = records.sorted { $0.createdAt > $1.createdAt }.prefix(backoffWindow)
        return latest.count == backoffWindow && latest.allSatisfy { $0.outcome == .skipped || $0.outcome == .expired }
    }
}

// MARK: - Text

nonisolated enum MateHeartbeatText {
    /// Lowercased letters and digits, single-spaced, for comparing titles.
    static func normalized(_ text: String) -> String {
        let scalars = text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    static func oneLine(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}

// MARK: - Parsing

nonisolated enum MateHeartbeatParser {
    struct Draft: Equatable, Sendable {
        let title: String
        let whyNow: String
        let prompt: String
        let needsApproval: String?
    }

    static let maxProposals = 3
    static let titleLimit = 80
    static let whyLimit = 240
    static let promptLimit = 2_000
    private static let keys: Set<String> = ["title", "why_now", "prompt", "needs_approval"]

    /// The proposals in a heartbeat reply, or nil when it is not exactly the
    /// requested structure. Malformed output is dropped whole, never repaired.
    static func parse(_ reply: String) -> [Draft]? {
        guard let json = jsonText(in: reply), let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any], Set(root.keys) == ["proposals"],
              let list = root["proposals"] as? [Any], list.count <= maxProposals else { return nil }
        var drafts: [Draft] = []
        for entry in list {
            guard let fields = entry as? [String: Any], Set(fields.keys).isSubset(of: keys),
                  let title = line(fields["title"], limit: titleLimit),
                  let why = line(fields["why_now"], limit: whyLimit),
                  let prompt = (fields["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !prompt.isEmpty, prompt.count <= promptLimit else { return nil }
            var approval: String?
            switch fields["needs_approval"] {
            case nil, is NSNull: approval = nil
            case let text as String:
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { approval = nil }
                else if let value = line(trimmed, limit: whyLimit) { approval = value }
                else { return nil }
            default: return nil
            }
            drafts.append(Draft(title: title, whyNow: why, prompt: prompt, needsApproval: approval))
        }
        return drafts
    }

    private static func line(_ value: Any?, limit: Int) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= limit, !text.contains(where: \.isNewline) else { return nil }
        return text
    }

    /// The last fenced JSON block, or else the outermost braces.
    private static func jsonText(in reply: String) -> String? {
        let parts = reply.components(separatedBy: "```")
        if parts.count >= 3 {
            var fenced = parts[parts.count - 2].trimmingCharacters(in: .whitespacesAndNewlines)
            if fenced.lowercased().hasPrefix("json") { fenced = String(fenced.dropFirst(4)) }
            return fenced.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else { return nil }
        return String(reply[start...end])
    }
}

// MARK: - Dedupe

nonisolated enum MateHeartbeatDedupe {
    static let containmentMinimum = 12

    /// Drops drafts that repeat a blocked title (suppressed or already
    /// proposed and open), match an open Inbox item or a running job, or
    /// repeat each other.
    static func filter(
        _ drafts: [MateHeartbeatParser.Draft], blockedTitles: [String], busyTexts: [String]
    ) -> [MateHeartbeatParser.Draft] {
        let blocked = Set(blockedTitles.map(MateHeartbeatText.normalized).filter { !$0.isEmpty })
        let busy = busyTexts.map(MateHeartbeatText.normalized).filter { !$0.isEmpty }
        var seen = Set<String>()
        return drafts.filter { draft in
            let key = MateHeartbeatText.normalized(draft.title)
            guard !key.isEmpty, !blocked.contains(key), seen.insert(key).inserted else { return false }
            return !busy.contains { overlaps(key, $0) }
        }
    }

    static func overlaps(_ left: String, _ right: String) -> Bool {
        if left == right { return true }
        let (short, long) = left.count <= right.count ? (left, right) : (right, left)
        return short.count >= containmentMinimum && long.contains(short)
    }
}

// MARK: - Context

nonisolated enum MateHeartbeatContext {
    struct FolderEntry: Equatable, Sendable {
        let name: String
        let modified: Date
        let isDirectory: Bool
    }

    struct Inputs: Sendable {
        var mateName: String
        var job: String
        var soul: String
        var memory: String?
        var folderPath: String?
        var folder: [FolderEntry] = []
        var unfinishedJobs: [String] = []
        var failedJobs: [String] = []
        var unansweredItems: [String] = []
        var unreadRoutineResults: [String] = []
        /// Nil when Calendar is not connected for this mate (or is excluded).
        var calendarToday: [String]?
        /// Nil when Mail is not connected for this mate (or is excluded).
        var unreadMail: [String]?
        var recentProposals: [MateHeartbeatRecord] = []
        var doNotPropose: [String] = []
        var now: Date
    }

    static let memoryLimit = 6_000
    static let folderLimit = 40
    static let listLimit = 10

    /// Names and modified dates only, newest first. Never file contents.
    static func folderEntries(at path: String?, limit: Int = folderLimit) -> [FolderEntry] {
        guard let path else { return [] }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: path, isDirectory: true), includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url -> FolderEntry? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return FolderEntry(name: url.lastPathComponent, modified: values?.contentModificationDate ?? .distantPast,
                               isDirectory: values?.isDirectory == true)
        }
        .sorted { $0.modified > $1.modified }
        .prefix(limit)
        .map { $0 }
    }

    /// Mail and Calendar are read only when their Mac app is not on the
    /// excluded-apps privacy list.
    static func allowsSource(bundleID: String, excluded: [String]) -> Bool {
        !excluded.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    static func render(_ inputs: Inputs) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "EEE d MMM HH:mm"
        var sections: [String] = ["Now: \(stamp.string(from: inputs.now))."]
        if let memory = inputs.memory?.trimmingCharacters(in: .whitespacesAndNewlines), !memory.isEmpty {
            let clipped = memory.count > memoryLimit ? String(memory.prefix(memoryLimit)) + "\n…" : memory
            sections.append("Your AGENTS.md memory:\n\(clipped)")
        }
        if let folderPath = inputs.folderPath {
            let lines = inputs.folder.map { "- \($0.name)\($0.isDirectory ? "/" : "") (modified \(stamp.string(from: $0.modified)))" }
            sections.append("Your folder \(folderPath) (names and dates only; use read for a file you need):\n"
                + (lines.isEmpty ? "- empty" : lines.joined(separator: "\n")))
        }
        func list(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            sections.append(title + "\n" + items.prefix(listLimit).map { "- " + MateHeartbeatText.oneLine($0, limit: 200) }.joined(separator: "\n"))
        }
        list("Your unfinished jobs (already running or waiting; do not propose them again):", inputs.unfinishedJobs)
        list("Your recently failed jobs:", inputs.failedJobs)
        list("Questions you asked the person that are still unanswered (do not repeat them):", inputs.unansweredItems)
        list("Routine results nobody has read yet:", inputs.unreadRoutineResults)
        if let calendar = inputs.calendarToday {
            sections.append("Today's calendar (titles only):\n" + (calendar.isEmpty ? "- nothing else today"
                : calendar.prefix(listLimit).map { "- " + MateHeartbeatText.oneLine($0, limit: 160) }.joined(separator: "\n")))
        }
        if let mail = inputs.unreadMail {
            sections.append("Unread mail (sender and subject only):\n" + (mail.isEmpty ? "- none"
                : mail.prefix(listLimit).map { "- " + MateHeartbeatText.oneLine($0, limit: 160) }.joined(separator: "\n")))
        }
        let recent = inputs.recentProposals.filter { inputs.now.timeIntervalSince($0.createdAt) < 7 * 24 * 3600 }
        list("What you proposed in the last 7 days and what happened:", recent.map { "\($0.title) (\($0.outcome.title))" })
        list("Do not propose (the person skipped these twice):", inputs.doNotPropose)
        return sections.joined(separator: "\n\n")
    }
}

// MARK: - Instructions

nonisolated enum MateHeartbeatPrompt {
    static func system(mateName: String, job: String, soul: String) -> String {
        var identity = "You are \(mateName), one of the person's HeyMate agents. Your job: \(job)."
        let trimmedSoul = soul.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSoul.isEmpty { identity += " Your personality: \(trimmedSoul)." }
        return identity + """


        This is your heartbeat: a short, private check-in the person did not ask for. Look at the context \
        you are given and decide whether there is work you could start for them now. You can read files in \
        your own folder and search or read the web. You cannot change anything, message anyone or start work here.

        Propose work only when the evidence in front of you makes it clearly useful today. Proposing \
        nothing beats proposing filler, and nothing is the most common right answer. Never repeat an open \
        question, a running job, or anything on the do-not-propose list.
        """
    }

    static let reply = """
    Reply with only this JSON, no other text:
    {"proposals": []}
    or with one to three items:
    {"proposals": [{"title": "Short imperative title, under 80 characters", \
    "why_now": "One line citing the evidence you saw", \
    "prompt": "The exact message that would start this work in your chat", \
    "needs_approval": "What would need the person's yes, or null"}]}
    """

    static func turn(context: String) -> String {
        context + "\n\n" + reply
    }
}
