//
//  HeadlessCodingAgent.swift
//  leanring-buddy
//
//  Shared types for local coding-agent jobs. The HTTP OpenCodeClient is a
//  different path (onboarding demo / Settings) and must not import these —
//  agents are child processes bound to a folder, not scratch chat sessions.
//

import Foundation

/// Which headless CLI HeyMate spawns for an agent job.
nonisolated enum HeadlessExecutor: String, Codable, CaseIterable, Equatable {
    case openCode
    case claudeCode
    case codex

    var displayName: String {
        switch self {
        case .openCode: return "OpenCode"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var executableName: String {
        switch self {
        case .openCode: return "opencode"
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }

    /// True when this CLI runs on a sign-in the user already pays for rather
    /// than on a key HeyMate supplies.
    var usesSubscriptionSignIn: Bool {
        switch self {
        case .claudeCode, .codex: return true
        case .openCode: return false
        }
    }

    /// Environment variables removed from this executor's child process.
    ///
    /// `claude` prefers `ANTHROPIC_API_KEY` over its stored subscription
    /// credential when both are visible, so leaking one in from
    /// `~/.config/heymate/secrets.env` would move every agent job onto metered
    /// API billing without changing anything the user can see.
    /// `ANTHROPIC_BASE_URL` is stripped for the same reason — it redirects the
    /// CLI away from the account it is signed in to.
    ///
    /// OpenCode strips nothing: bringing your own provider keys is the whole
    /// point of that executor.
    var environmentKeysToRemove: [String] {
        switch self {
        case .claudeCode:
            return ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL"]
        case .codex:
            return ["OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_API_BASE"]
        case .openCode:
            return []
        }
    }

    /// Claude Code is the default because it is the subscription the user is
    /// already paying for, and because its `stream-json` output is the most
    /// stable of the CLIs HeyMate spawns. Only fresh installs land here — an
    /// existing choice in UserDefaults always wins.
    static func fromUserDefaults() -> HeadlessExecutor {
        let storedRawValue = UserDefaults.standard.string(forKey: "defaultHeadlessExecutor")
        return HeadlessExecutor(rawValue: storedRawValue ?? "") ?? .claudeCode
    }

    /// Honors an explicit executor instruction without treating a product name
    /// elsewhere in the task as routing. "Build an OpenCode dashboard" stays
    /// on the selected executor; "use OpenCode to build it" routes OpenCode.
    static func explicitlyRequested(in prompt: String) -> HeadlessExecutor? {
        let normalizedPrompt = prompt
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        let executorPhrases: [(executor: HeadlessExecutor, phrases: [String])] = [
            (.openCode, ["use opencode", "using opencode", "with opencode", "run in opencode"]),
            (.claudeCode, ["use claude code", "using claude code", "with claude code", "run in claude code"]),
            (.codex, ["use codex", "using codex", "with codex", "run in codex"])
        ]
        for executorPhrase in executorPhrases {
            if executorPhrase.phrases.contains(where: normalizedPrompt.contains) {
                return executorPhrase.executor
            }
        }
        return nil
    }
}

/// Whether the job minted a sandbox or attached to a user-chosen folder.
nonisolated enum AgentRunOrigin: String, Codable, Equatable {
    case sandbox
    case attached
}

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

/// Which half of the two-leg approval gate a spawn belongs to.
///
/// Leg one runs read-only and produces a plan. Nothing is written until the
/// user approves it and leg two resumes the *same* CLI session with write
/// permission — which is what makes the approval mean something: the model
/// that acts is the model that wrote the plan you read.
nonisolated enum AgentRunLeg: Equatable {
    /// Read-only. `prompt` is the original task.
    case plan(prompt: String)
    /// Write-enabled, resuming the approved session.
    case execute
    /// Read-only again, in the same session, with the user's objection.
    case replan(feedback: String)
    /// Read-only, in the session of a job that already finished: "also make
    /// it dark mode". Goes through the same gate as everything else, so more
    /// work still means another plan to approve.
    case followUp(instruction: String)

    var isReadOnly: Bool {
        switch self {
        case .plan, .replan, .followUp: return true
        case .execute: return false
        }
    }

    /// Whether this leg continues an existing CLI session rather than opening
    /// one. Only the first plan of a job starts fresh.
    var resumesSession: Bool {
        switch self {
        case .plan: return false
        case .execute, .replan, .followUp: return true
        }
    }
}

/// Events adapters emit after mapping CLI stdout. Unknown JSON is dropped
/// before it reaches this enum so the rest of the app never sees raw logs.
nonisolated enum AgentEvent: Equatable {
    case started
    /// The CLI told us which session this is. Claude Code echoes back the id
    /// HeyMate minted; OpenCode assigns its own, so this is how leg two learns
    /// what to resume.
    case sessionIdentified(String)
    case tool(summary: String)
    case text(String)
    /// Leg one finished. Nothing has been written; the user decides next.
    case planReady(text: String)
    case approvalRequested(id: String, summary: String)
    case finished(summary: String)
    case failed(message: String)
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
    /// Persistent, user-facing task conversation and progress timeline.
    var activity: [AgentActivityEntry]
    /// Follow-ups sent while a process is busy. They resume this same session
    /// in order after the current write leg finishes.
    var queuedFollowUpInstructions: [String]

    var workspaceURL: URL {
        URL(fileURLWithPath: workspacePath, isDirectory: true)
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
            sessionIdentifier: sessionIdentifier,
            planText: "",
            undoEntryIdentifier: "",
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
        sessionIdentifier = try container.decodeIfPresent(String.self, forKey: .sessionIdentifier) ?? ""
        planText = try container.decodeIfPresent(String.self, forKey: .planText) ?? ""
        undoEntryIdentifier = try container.decodeIfPresent(String.self, forKey: .undoEntryIdentifier) ?? ""
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
