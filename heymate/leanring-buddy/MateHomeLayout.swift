//
//  MateHomeLayout.swift
//  leanring-buddy
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
    static let railWidth: CGFloat = 248
    static let drawerWidth: CGFloat = 280
    static let readingMeasure: CGFloat = 680

    static let workspaceSections: [DesktopSection] = [
        .agents, .connectors, .notch, .skills, .memory, .privacy, .settings
    ]

    static func visibleColumns(isCompact: Bool, isDrawerOpen: Bool) -> [MateHomeColumn] {
        if isCompact { return [.conversation] }
        return isDrawerOpen ? [.rail, .conversation, .drawer] : [.rail, .conversation]
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
