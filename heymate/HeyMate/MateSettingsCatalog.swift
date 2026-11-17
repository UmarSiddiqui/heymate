//
//  MateSettingsCatalog.swift
//  HeyMate
//
//  The agent settings sections and a search index over their controls, in the
//  same shape as SettingsCatalog for the app settings window: a rail of
//  sections, and search across titles and synonyms that opens the section and
//  scrolls to the control. No UI here.
//

import Foundation

nonisolated enum MateSettingsSection: String, CaseIterable, Identifiable, Sendable {
    case profile
    case brain
    case permissions
    case proactive
    case notifications
    case memory
    case files
    case apps
    case limits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: "Profile"
        case .brain: "Brain"
        case .permissions: "Permissions"
        case .proactive: "Proactive"
        case .notifications: "Notifications"
        case .memory: "Memory"
        case .files: "Files & Browser"
        case .apps: "Apps & Skills"
        case .limits: "Limits"
        }
    }

    var symbolName: String {
        switch self {
        case .profile: "person.crop.circle"
        case .brain: "cpu"
        case .permissions: "hand.raised"
        case .proactive: "clock.arrow.circlepath"
        case .notifications: "bell"
        case .memory: "brain"
        case .files: "folder"
        case .apps: "puzzlepiece.extension"
        case .limits: "gauge.with.dots.needle.33percent"
        }
    }
}

/// One searchable control. `anchor` is the scroll id on its row.
nonisolated struct MateSettingsItem: Equatable, Identifiable, Sendable {
    let anchor: String
    let title: String
    let section: MateSettingsSection
    let keywords: String
    /// Hidden for the default mate, which conducts the others.
    var hiddenForConductor = false

    var id: String { anchor }
}

nonisolated enum MateSettingsCatalog {
    static let items: [MateSettingsItem] = [
        .init(anchor: "profile.picture", title: "Picture", section: .profile, keywords: "face character avatar image look"),
        .init(anchor: "profile.name", title: "Name and job", section: .profile, keywords: "rename title role what it does"),
        .init(anchor: "profile.soul", title: "Personality", section: .profile, keywords: "soul tone voice behaves talks"),
        .init(anchor: "profile.howItWorks", title: "How it works", section: .profile, keywords: "habits rules always"),
        .init(anchor: "profile.asksFirst", title: "Asks you before", section: .profile, keywords: "asks first never without yes confirm"),
        .init(anchor: "profile.duplicate", title: "Duplicate", section: .profile, keywords: "copy clone", hiddenForConductor: true),
        .init(anchor: "profile.archive", title: "Archive", section: .profile, keywords: "hide retire", hiddenForConductor: true),
        .init(anchor: "profile.delete", title: "Delete", section: .profile, keywords: "remove erase", hiddenForConductor: true),

        .init(anchor: "brain.provider", title: "Brain", section: .brain, keywords: "ai provider claude chatgpt engine"),
        .init(anchor: "brain.model", title: "Model", section: .brain, keywords: "sonnet opus gpt model version"),
        .init(anchor: "brain.effort", title: "Effort", section: .brain, keywords: "thinking reasoning depth speed"),
        .init(anchor: "brain.backup", title: "Backup brain", section: .brain, keywords: "usage limit failover fallback"),

        .init(anchor: "permissions.mode", title: "Approval mode", section: .permissions, keywords: "ask me full access always ask approve stricter"),
        .init(anchor: "permissions.rules", title: "Allow, ask and deny rules", section: .permissions, keywords: "permissions always allow remembered command write edit"),
        .init(anchor: "permissions.floor", title: "Always asks", section: .permissions, keywords: "floor send delete money password publish"),
        .init(anchor: "permissions.reach", title: "What it can reach", section: .permissions, keywords: "access folder apps browser skills"),

        .init(anchor: "proactive.heartbeat", title: "Check-ins", section: .proactive, keywords: "heartbeat propose ideas suggestions check now"),
        .init(anchor: "proactive.quiet", title: "Quiet hours", section: .proactive, keywords: "night do not disturb sleep silence"),
        .init(anchor: "proactive.wake", title: "Offers to help when", section: .proactive, keywords: "wake trigger app opened file mail"),
        .init(anchor: "proactive.routines", title: "Routines", section: .proactive, keywords: "schedule every morning daily recurring"),

        .init(anchor: "notifications.proposals", title: "Proposals", section: .notifications, keywords: "notify ideas check-in alert"),
        .init(anchor: "notifications.finished", title: "Finished work", section: .notifications, keywords: "notify done complete alert"),
        .init(anchor: "notifications.needsInput", title: "Needs your input", section: .notifications, keywords: "notify question approval waiting alert"),
        .init(anchor: "notifications.failed", title: "Failed routine", section: .notifications, keywords: "notify error stopped alert"),

        .init(anchor: "memory.note", title: "Notes", section: .memory, keywords: "memory remember note dated"),
        .init(anchor: "memory.standing", title: "Standing preferences", section: .memory, keywords: "agents.md habits memory"),
        .init(anchor: "memory.everything", title: "Everything HeyMate remembers", section: .memory, keywords: "memories all shared"),

        .init(anchor: "files.folder", title: "Folder", section: .files, keywords: "directory workspace reveal change finder", hiddenForConductor: true),
        .init(anchor: "files.history", title: "File history", section: .files, keywords: "versions storage clear", hiddenForConductor: true),
        .init(anchor: "files.browser", title: "Browser profile", section: .files, keywords: "chrome sign in sign out cookies persistent"),
        .init(anchor: "files.livePanel", title: "Live browser panel", section: .files, keywords: "watch view screen"),

        .init(anchor: "apps.integrations", title: "Integrations", section: .apps, keywords: "connected apps gmail slack github composio"),
        .init(anchor: "apps.skills", title: "Skills", section: .apps, keywords: "instructions abilities"),

        .init(anchor: "limits.continuations", title: "Continuations per task", section: .limits, keywords: "long run turns steps cap"),
        .init(anchor: "limits.routine", title: "Routine time limit", section: .limits, keywords: "minutes timeout stop cap"),
        .init(anchor: "limits.heartbeats", title: "Check-ins per day", section: .limits, keywords: "heartbeats cap daily"),
        .init(anchor: "limits.today", title: "Today", section: .limits, keywords: "activity usage count turns runs"),
    ]

    static func items(in section: MateSettingsSection, conductsOthers: Bool) -> [MateSettingsItem] {
        items.filter { $0.section == section && !(conductsOthers && $0.hiddenForConductor) }
    }

    static func item(anchor: String) -> MateSettingsItem? { items.first { $0.anchor == anchor } }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Controls matching every word, best first: title prefix, title contains,
    /// all words in the title, then synonym or section matches. Ties keep order.
    static func results(for query: String, conductsOthers: Bool) -> [MateSettingsItem] {
        let words = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let whole = words.joined(separator: " ")
        var scored: [(item: MateSettingsItem, score: Int, order: Int)] = []
        for (order, item) in items.enumerated() where !(conductsOthers && item.hiddenForConductor) {
            let title = normalized(item.title)
            let haystack = [title, normalized(item.keywords), normalized(item.section.title)].joined(separator: " ")
            guard words.allSatisfy({ haystack.contains($0) }) else { continue }
            let score = title.hasPrefix(whole) ? 0 : title.contains(whole) ? 1 : words.allSatisfy({ title.contains($0) }) ? 2 : 3
            scored.append((item, score, order))
        }
        return scored.sorted { ($0.score, $0.order) < ($1.score, $1.order) }.map(\.item)
    }
}

// MARK: - Dated notes in AGENTS.md

/// One note row. `date` is "YYYY-MM-DD" when the note starts with one.
nonisolated struct MateMemoryNote: Equatable, Sendable {
    var date: String?
    var text: String
}

nonisolated enum MateMemoryNotes {
    private static let datePattern = #"^(\d{4}-\d{2}-\d{2}):\s*"#

    /// Splits a Notes body into rows: each "YYYY-MM-DD:" line starts a note,
    /// following lines continue it, and text before the first date is one undated note.
    static func parse(_ body: String) -> [MateMemoryNote] {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != MateWorkspaceMemory.notesPlaceholder else { return [] }
        var notes: [MateMemoryNote] = []
        for line in trimmed.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if let range = text.range(of: datePattern, options: .regularExpression) {
                let date = String(text[range].prefix(10))
                notes.append(MateMemoryNote(date: date, text: String(text[range.upperBound...])))
            } else if notes.isEmpty {
                notes.append(MateMemoryNote(date: nil, text: text))
            } else {
                notes[notes.count - 1].text += "\n" + text
            }
        }
        return notes
            .map { MateMemoryNote(date: $0.date, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
    }

    static func render(_ notes: [MateMemoryNote]) -> String {
        notes
            .map { MateMemoryNote(date: $0.date, text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
            .map { note in note.date.map { "\($0): \(note.text)" } ?? note.text }
            .joined(separator: "\n")
    }

    /// A new note stamped with today's date, after the existing ones.
    static func appending(_ text: String, to notes: [MateMemoryNote], now: Date,
                          calendar: Calendar = .current) -> [MateMemoryNote] {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return notes }
        return notes + [MateMemoryNote(date: MateActivityDay.key(for: now, calendar: calendar), text: cleaned)]
    }
}
