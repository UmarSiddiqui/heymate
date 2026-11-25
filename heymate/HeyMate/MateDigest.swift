//
//  MateDigest.swift
//  HeyMate
//
//  What needs the person right now, across every agent: a job waiting for
//  a yes, a routine that stopped, work the agent proposed on its own, or a
//  result nobody has read. One line per
//  agent, most urgent first. Built only from state the app already keeps,
//  so nothing here calls a model, and a line leaves when its cause does.
//

import Foundation

nonisolated struct MateDigestItem: Equatable, Identifiable {
    enum Kind: String, Equatable {
        /// A plan to approve or a step to allow.
        case needsOK
        /// A routine paused itself after failing.
        case routineStopped
        /// The agent proposed work on its heartbeat.
        case proposal
        /// A reply or result that has not been opened.
        case unread
    }

    var id: String { "\(kind.rawValue)-\(mateID.uuidString)" }

    /// Two or three words for a tight row, such as the notch peek.
    var badge: String {
        switch kind {
        case .needsOK: return "Needs your OK"
        case .routineStopped: return "Routine stopped"
        case .proposal: return "Has an idea"
        case .unread: return "New"
        }
    }
    let mateID: UUID
    let mateName: String
    let kind: Kind
    let title: String
    let detail: String
    var targetID: UUID? = nil
}

enum MateDigest {
    static let maxItems = 4

    /// The lines to show and how many more agents are waiting behind them.
    static func make(
        mates: [Mate],
        routines: [MateRoutine],
        runs: [AgentRun],
        owners: [UUID: UUID],
        sessions: [ChatSession],
        defaultMateID: UUID,
        activeMateID: UUID?,
        includesUnread: Bool = true,
        proposals: [MateInboxItem] = [],
        inboxItems: [MateInboxItem] = []
    ) -> (items: [MateDigestItem], hiddenCount: Int) {
        var needsOK: [MateDigestItem] = []
        var stopped: [MateDigestItem] = []
        var proposed: [MateDigestItem] = []
        var unread: [MateDigestItem] = []

        for mate in mates where !mate.archived {
            let waiting = MateJobs.runs(for: mate, in: runs, owners: owners).filter(\.status.needsUser)
            if let first = waiting.first {
                let more = waiting.count - 1
                needsOK.append(MateDigestItem(
                    mateID: mate.id,
                    mateName: mate.name,
                    kind: .needsOK,
                    title: "\(mate.name) needs your OK",
                    detail: more > 0 ? "\(first.title) and \(more) more" : first.title,
                    targetID: first.id
                ))
                continue
            }
            let pending = inboxItems.lazy.filter { $0.mateID == mate.id && $0.isPendingAttention }
            let question = pending.compactMap { item -> (UUID, String)? in
                    switch item.kind {
                    case .question(let prompt, _, _): return (item.id, prompt)
                    case .signIn(let site, _, _, _): return (item.id, "Sign in to \(site)")
                    default: return nil
                    }
                }.first
            if let question {
                needsOK.append(MateDigestItem(mateID: mate.id, mateName: mate.name, kind: .needsOK,
                                              title: "\(mate.name) needs you", detail: question.1,
                                              targetID: question.0))
                continue
            }
            if let routine = routines.first(where: { $0.mateID == mate.id && stoppedItself($0) }) {
                let failure = pending.first {
                    if case .routineFailed(let id, _) = $0.kind { return id == routine.id }
                    return false
                }
                stopped.append(MateDigestItem(
                    mateID: mate.id,
                    mateName: mate.name,
                    kind: .routineStopped,
                    title: "\(mate.name)'s routine stopped",
                    detail: routine.lastStatusMessage ?? routine.pausedReason ?? routine.task,
                    targetID: failure?.id
                ))
                continue
            }
            let open = proposals.filter { $0.mateID == mate.id && $0.isPendingAttention }
                .compactMap { item in item.proposal.map { (item.id, $0) } }
                .sorted { $0.1.createdAt > $1.1.createdAt }
            if let (itemID, first) = open.first {
                let more = open.count - 1
                proposed.append(MateDigestItem(
                    mateID: mate.id,
                    mateName: mate.name,
                    kind: .proposal,
                    title: "\(mate.name) proposes work",
                    detail: more > 0 ? "\(first.title) and \(more) more" : first.title,
                    targetID: itemID
                ))
                continue
            }
            // The open chat is already being read.
            if includesUnread, mate.unreadCount > 0, mate.id != activeMateID {
                let preview = MateRailPreview.make(for: mate, sessions: sessions, defaultMateID: defaultMateID)
                unread.append(MateDigestItem(
                    mateID: mate.id,
                    mateName: mate.name,
                    kind: .unread,
                    title: "\(mate.name) has something for you",
                    detail: preview.text
                ))
            }
        }

        let all = needsOK + stopped + proposed + unread
        return (Array(all.prefix(maxItems)), max(0, all.count - maxItems))
    }

    /// Paused by its own failures. A pause the person chose, or one that
    /// follows from archiving the agent, is not news.
    nonisolated static func stoppedItself(_ routine: MateRoutine) -> Bool {
        guard let reason = routine.pausedReason else { return false }
        return reason != MateRoutineAccounting.manualPauseReason
            && reason != MateRoutineAccounting.archivedPauseReason
    }
}
