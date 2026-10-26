//
//  MateHomeLayout.swift
//  HeyMate
//
//  Pure layout decisions for the chat home. The view asks these instead of
//  inventing a second information architecture.
//

import CoreGraphics
import Foundation

enum MateHomeColumn: Equatable {
    case rail
    case conversation
    case drawer
}

enum MatePresence: String, Equatable {
    case working
    case pausedRoutine
    case idle

    var label: String {
        switch self {
        case .working: return "Working"
        case .pausedRoutine: return "Paused"
        case .idle: return "Idle"
        }
    }
}

enum MateHomeLayout {
    static let railWidth: CGFloat = 237
    static let drawerWidth: CGFloat = 280
    static let readingMeasure: CGFloat = 680
    static let minimumConversationWidth: CGFloat = 320
    static let comfortableConversationWidth: CGFloat = 480

    /// The gear menu mirrors the window sidebar: Apps and Settings. Jobs
    /// has its own header button; skills and memory live in a mate's sheet.
    static let workspaceSections: [DesktopSection] = DesktopSection.sidebarSections

    static func visibleColumns(
        isCompact: Bool, isDrawerOpen: Bool,
        availableWidth: CGFloat = .infinity, detailWidth: CGFloat = drawerWidth
    ) -> [MateHomeColumn] {
        if isCompact { return [.conversation] }
        let sideWidth = isDrawerOpen ? detailWidth : railWidth
        guard availableWidth >= minimumConversationWidth + sideWidth + 1 else { return [.conversation] }
        // Profile and file details take the rail's place; they never squeeze
        // the conversation between two fixed-width sidebars.
        return isDrawerOpen ? [.conversation, .drawer] : [.rail, .conversation]
    }

    static func shouldFollowLatest(isNearBottom: Bool) -> Bool {
        isNearBottom
    }

    static let messagePageSize = 40

    /// Newest messages stay on screen. `extraRevealed` pulls older pages in
    /// from the top as the reader asks for them.
    static func visibleMessages(
        _ messages: [ChatMessage],
        extraRevealed: Int
    ) -> (hiddenCount: Int, visible: [ChatMessage]) {
        let keep = messagePageSize + max(0, extraRevealed)
        guard messages.count > keep else { return (0, messages) }
        let hiddenCount = messages.count - keep
        return (hiddenCount, Array(messages.suffix(keep)))
    }

    static func presence(
        for mateID: UUID,
        routines: [MateRoutine],
        isWorking: Bool
    ) -> MatePresence {
        if isWorking { return .working }
        let paused = routines.contains { $0.mateID == mateID && $0.pausedReason != nil }
        return paused ? .pausedRoutine : .idle
    }
}

/// Jobs are the work a mate does over time (an agent run underneath). They
/// belong to the mate that asked for them, so chat shows them in place
/// instead of on a separate page the user has to know about.
enum MateJobs {
    /// Anything still running or waiting on the user. This is the Jobs badge.
    static func activeCount(in runs: [AgentRun]) -> Int {
        runs.filter { !$0.status.isTerminal }.count
    }

    /// Jobs blocked on the user: a plan to approve or a step to allow.
    static func needsYouCount(in runs: [AgentRun]) -> Int {
        runs.filter(\.status.needsUser).count
    }

    /// A mate's jobs, newest first: the runs it asked for this session, plus
    /// any run that worked in the mate's own folder, which still links them
    /// after a relaunch.
    static func runs(
        for mate: Mate,
        in runs: [AgentRun],
        owners: [UUID: UUID]
    ) -> [AgentRun] {
        let folderPath = mate.folderPath.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
        }
        return runs
            .filter { run in
                if owners[run.id] == mate.id { return true }
                guard let folderPath else { return false }
                return run.workspaceURL.standardizedFileURL.path == folderPath
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Short status words for a job row in chat. Plain language, no
    /// "agent", "executor", or "sandbox".
    static func statusLabel(for status: AgentRunStatus) -> String {
        switch status {
        case .queued: return "Starting"
        case .planning: return "Planning"
        case .awaitingPlanApproval: return "Plan ready"
        case .running: return "Working"
        case .waitingForApproval: return "Needs your OK"
        case .succeeded: return "Done"
        case .failed: return "Stopped"
        case .cancelled: return "Cancelled"
        }
    }
}

enum MateStarterPrompts {
    static func lines(for job: String) -> [String] {
        let jobText = job.trimmingCharacters(in: .whitespacesAndNewlines)
        let focus = jobText.isEmpty ? "general chat" : jobText
        return [
            "Take this on: \(focus).",
            "What should I know before I start?",
            "What's the first useful step?"
        ]
    }
}

enum MateSearch {
    static func filter(
        mates: [Mate],
        sessions: [ChatSession],
        query: String,
        defaultMateID: UUID
    ) -> [Mate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return mates.filter { !$0.archived }
        }
        return mates.filter { mate in
            if mate.name.localizedCaseInsensitiveContains(trimmed) { return true }
            if mate.job.localizedCaseInsensitiveContains(trimmed) { return true }
            return sessions.contains { session in
                let owner = session.mateID ?? defaultMateID
                guard owner == mate.id else { return false }
                if session.title.localizedCaseInsensitiveContains(trimmed) { return true }
                return session.messages.contains { $0.text.localizedCaseInsensitiveContains(trimmed) }
            }
        }
    }
}

enum MateRailOrder {
    static func split(
        mates: [Mate],
        sessions: [ChatSession],
        query: String,
        defaultMateID: UUID
    ) -> (pinned: [Mate], others: [Mate]) {
        let matches = MateSearch.filter(
            mates: mates,
            sessions: sessions,
            query: query,
            defaultMateID: defaultMateID
        )
        let pinned = matches.filter(\.pinned).sorted { $0.updatedAt > $1.updatedAt }
        let others = matches.filter { !$0.pinned }.sorted { $0.updatedAt > $1.updatedAt }
        return (pinned, others)
    }
}

/// The two tabs at the top of the desktop rail. Chats is the user's own
/// conversations with HeyMate; Mates is the only place mates are listed.
enum MateRailTab: String, CaseIterable, Identifiable {
    case chats
    case mates

    /// The `@AppStorage` key the rail reads to remember its tab.
    static let storageKey = "mateHome.railTab"
    static let defaultTab: MateRailTab = .chats

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: return "Chats"
        case .mates: return "Mates"
        }
    }

    var searchPrompt: String {
        switch self {
        case .chats: return "Search chats"
        case .mates: return "Search mates"
        }
    }

    /// Unknown or missing stored values fall back to Chats.
    static func stored(_ rawValue: String) -> MateRailTab {
        MateRailTab(rawValue: rawValue) ?? defaultTab
    }
}

/// The Chats tab: every session that belongs to main HeyMate (the default
/// mate), newest first. Sessions saved before mates existed have no mate id
/// and count as main HeyMate's.
enum MainChatList {
    static func sessions(
        saved: [ChatSession],
        current: ChatSession,
        defaultMateID: UUID,
        query: String
    ) -> [ChatSession] {
        func isMain(_ session: ChatSession) -> Bool {
            (session.mateID ?? defaultMateID) == defaultMateID
        }
        var mains = saved.filter(isMain)
        // A fresh main chat isn't saved until it has a message; list it so
        // the open conversation is always visible and selected.
        if isMain(current), !mains.contains(where: { $0.id == current.id }) {
            mains.append(current)
        }
        mains.sort { $0.updatedAt > $1.updatedAt }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return mains }
        return mains.filter { session in
            session.title.localizedStandardContains(trimmed)
                || session.messages.contains { $0.text.localizedStandardContains(trimmed) }
        }
    }

    /// The row to highlight: the open chat, but only while main HeyMate is
    /// the active mate. A mate's chat never selects a main row.
    static func selectedID(
        current: ChatSession,
        activeMateID: UUID?,
        defaultMateID: UUID
    ) -> UUID? {
        guard (activeMateID ?? defaultMateID) == defaultMateID else { return nil }
        guard (current.mateID ?? defaultMateID) == defaultMateID else { return nil }
        return current.id
    }
}

/// What a rail row shows under a mate's name: the newest line of its newest
/// chat, like a messages inbox, with the job as the fallback for a mate that
/// hasn't said anything yet.
nonisolated struct MateRailPreview: Equatable {
    let text: String
    let date: Date?

    static func make(
        for mate: Mate,
        sessions: [ChatSession],
        defaultMateID: UUID
    ) -> MateRailPreview {
        let latest = sessions
            .filter { ($0.mateID ?? defaultMateID) == mate.id }
            .compactMap { $0.messages.last }
            .max { $0.createdAt < $1.createdAt }
        guard let latest else { return MateRailPreview(text: mate.job, date: nil) }
        // Replies are Markdown; a one-line preview shows the words, not the marks.
        let plain = (try? AttributedString(
            markdown: latest.text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )).map { String($0.characters) } ?? latest.text
        let flattened = plain
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return MateRailPreview(text: flattened.isEmpty ? mate.job : flattened, date: latest.createdAt)
    }

    /// "12:15 am" today, "Yesterday", the weekday within a week, else a date.
    static func timestamp(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
           days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
