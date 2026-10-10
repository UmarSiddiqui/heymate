//
//  HeadlessCodingAgent.swift
//  HeyMate
//
//  Shared types for local coding-agent jobs. The HTTP OpenCodeClient is a
//  different path (onboarding demo / Settings) and must not import these —
//  agents are child processes bound to a folder, not scratch chat sessions.
//

import Foundation

nonisolated enum AgentRunStatus: String, Codable, Equatable {
    case queued
    /// Leg one: the agent is reading and thinking, with writes turned off.
    case planning
    /// Leg one finished. The plan is on the card and nothing happens until
    /// the user approves it.
    case awaitingPlanApproval
    case running
    /// A single tool inside leg two is asking permission (attached folders).
    case waitingForApproval
    case succeeded
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            return true
        case .queued, .planning, .awaitingPlanApproval, .running, .waitingForApproval:
            return false
        }
    }

    /// True while the job is waiting on the user rather than on a model.
    /// These are the only states allowed to interrupt.
    var needsUser: Bool {
        switch self {
        case .awaitingPlanApproval, .waitingForApproval:
            return true
        case .queued, .planning, .running, .succeeded, .failed, .cancelled:
            return false
        }
    }
}

nonisolated enum AgentFollowUpIntent {
    case statusQuestion
    case workInstruction

    static func classify(_ text: String) -> Self {
        let normalizedText = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let statusPhrases = [
            "what are you doing",
            "what are you up to",
            "what are you upto",
            "is it done",
            "are you done",
            "how is it going",
            "hows it going",
            "status",
            "progress"
        ]
        return statusPhrases.contains(where: normalizedText.contains)
            ? .statusQuestion
            : .workInstruction
    }
}

/// One user-visible turn in an agent job. This is a concise activity feed,
/// not raw model output or chain-of-thought.
nonisolated struct AgentActivityEntry: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, Equatable {
        case user
        case agent
        case progress
        case status
    }

    let id: UUID
    let kind: Kind
    let text: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
    }
}

/// One persisted agent job. Artifact bytes live in `workspacePath`, not here.
nonisolated struct AgentRun: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var prompt: String
    var workspacePath: String
    var executor: HeadlessExecutor
    var origin: AgentRunOrigin
    var status: AgentRunStatus
    var latestAction: String
    var summary: String
    var error: String
    var pendingApprovalID: String
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var pid: Int32?
    /// Active detached attempt. Empty means this run is still owned by app or
    /// has never entered runner mode. UUID is stored as text for migration
    /// compatibility with older persisted run records.
    var detachedAttemptIdentifier: String
    /// Highest durable runtime event merged into this card. Relaunch resumes
    /// after this sequence so progress and terminal events apply once.
    var lastDetachedJournalSequence: UInt64
    /// The CLI session both legs share. HeyMate mints this for Claude Code and
    /// learns it from the stream for OpenCode; either way leg two resumes it,
    /// so the model that executes is the one that wrote the approved plan.
    var sessionIdentifier: String
    /// What leg one said it was going to do, in prose. This is the thing the
    /// user actually approves.
    var planText: String
    /// Snapshot prepared immediately before current write-enabled leg. Empty
    /// means no approved work has started or snapshot preparation failed.
    var undoEntryIdentifier: String
    /// Privacy-bounded proof of files changed by the latest write-enabled
    /// leg. Paths are relative and capped; prompt, logs, workspace location,
    /// and CLI session data never enter this value.
    var workspaceChangeSummary: AgentWorkspaceChangeSummary?
    /// Persistent, user-facing task conversation and progress timeline.
    var activity: [AgentActivityEntry]
    /// Follow-ups sent while a process is busy. They resume this same session
    /// in order after the current write leg finishes.
    var queuedFollowUpInstructions: [String]

    var workspaceURL: URL {
        URL(fileURLWithPath: workspacePath, isDirectory: true)
    }

    var detachedAttemptID: UUID? {
        UUID(uuidString: detachedAttemptIdentifier)
    }

    static func queued(
        id: UUID,
        title: String,
        prompt: String,
        workspaceURL: URL,
        executor: HeadlessExecutor,
        origin: AgentRunOrigin,
        createdAt: Date = Date(),
        sessionIdentifier: String = ""
    ) -> AgentRun {
        AgentRun(
            id: id,
            title: title,
            prompt: prompt,
            workspacePath: workspaceURL.path,
            executor: executor,
            origin: origin,
            status: .queued,
            latestAction: "Queued",
            summary: "",
            error: "",
            pendingApprovalID: "",
            createdAt: createdAt,
            startedAt: nil,
            finishedAt: nil,
            pid: nil,
            detachedAttemptIdentifier: "",
            lastDetachedJournalSequence: 0,
            sessionIdentifier: sessionIdentifier,
            planText: "",
            undoEntryIdentifier: "",
            workspaceChangeSummary: nil,
            activity: [
                AgentActivityEntry(kind: .user, text: prompt, createdAt: createdAt),
                AgentActivityEntry(kind: .status, text: "Queued", createdAt: createdAt)
            ],
            queuedFollowUpInstructions: []
        )
    }
}

extension AgentRun {
    /// Decoded by hand only so that `sessionIdentifier` and `planText` can be
    /// absent. `FileAgentRunStore` falls back to an empty history when a
    /// decode throws, so a strict synthesized decoder would silently erase
    /// every job the user ran before the approval gate shipped.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        prompt = try container.decode(String.self, forKey: .prompt)
        workspacePath = try container.decode(String.self, forKey: .workspacePath)
        executor = try container.decode(HeadlessExecutor.self, forKey: .executor)
        origin = try container.decode(AgentRunOrigin.self, forKey: .origin)
        status = try container.decode(AgentRunStatus.self, forKey: .status)
        latestAction = try container.decode(String.self, forKey: .latestAction)
        summary = try container.decode(String.self, forKey: .summary)
        error = try container.decode(String.self, forKey: .error)
        pendingApprovalID = try container.decode(String.self, forKey: .pendingApprovalID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
        detachedAttemptIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .detachedAttemptIdentifier
        ) ?? ""
        lastDetachedJournalSequence = try container.decodeIfPresent(
            UInt64.self,
            forKey: .lastDetachedJournalSequence
        ) ?? 0
        sessionIdentifier = try container.decodeIfPresent(String.self, forKey: .sessionIdentifier) ?? ""
        planText = try container.decodeIfPresent(String.self, forKey: .planText) ?? ""
        undoEntryIdentifier = try container.decodeIfPresent(String.self, forKey: .undoEntryIdentifier) ?? ""
        workspaceChangeSummary = try container.decodeIfPresent(
            AgentWorkspaceChangeSummary.self,
            forKey: .workspaceChangeSummary
        )
        activity = try container.decodeIfPresent([AgentActivityEntry].self, forKey: .activity) ?? [
            AgentActivityEntry(kind: .user, text: prompt, createdAt: createdAt)
        ]
        queuedFollowUpInstructions = try container.decodeIfPresent(
            [String].self,
            forKey: .queuedFollowUpInstructions
        ) ?? []
    }

    mutating func appendActivity(
        kind: AgentActivityEntry.Kind,
        text: String,
        createdAt: Date = Date()
    ) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        if let lastEntry = activity.last,
           lastEntry.kind == kind,
           lastEntry.text == trimmedText {
            return
        }

        activity.append(AgentActivityEntry(kind: kind, text: trimmedText, createdAt: createdAt))
        if activity.count > 120 {
            activity.removeFirst(activity.count - 120)
        }
    }
}

/// Frontmost-app snapshot written into TASK.md. No screenshot bytes.
nonisolated struct AgentScreenContext: Equatable {
    var activeAppName: String
    var windowTitle: String
}
