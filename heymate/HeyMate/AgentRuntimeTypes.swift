//
//  AgentRuntimeTypes.swift
//  HeyMate
//
//  Minimal coding-agent types shared by HeyMate and its embedded runner.
//  Keep this file free of AppKit, SwiftUI, and app lifecycle dependencies.
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
    /// Subscription CLIs get no documented HeyMate app secret at all. Besides
    /// preventing accidental API billing, this keeps Worker, transcription,
    /// speech, and bridge credentials outside an agent-controlled shell.
    ///
    /// OpenCode may use provider auth persisted under approved XDG paths, but
    /// the shared child-environment allowlist excludes ambient provider and
    /// app credentials. HeyMate's local secrets file is never merged either.
    var environmentKeysToRemove: [String] {
        let appOnlySecrets = [
            "ASSEMBLYAI_API_KEY",
            "COMPOSIO_API_KEY",
            "ELEVENLABS_API_KEY",
            "ELEVENLABS_VOICE_ID",
            "GOG_KEYRING_PASSWORD",
            "HEYMATE_CLIENT_TOKEN",
            "HEYMATE_BRIDGE_TOKEN",
            "HEYMATE_SECRETS_FILE",
            "NOTION_API_KEY",
            "OPENCODE_SERVER_PASSWORD",
            "POSTHOG_API_KEY",
            "SLACK_API_KEY"
        ]
        switch self {
        case .claudeCode:
            return appOnlySecrets + [
                "ANTHROPIC_API_KEY",
                "ANTHROPIC_AUTH_TOKEN",
                "ANTHROPIC_BASE_URL",
                "OPENAI_API_KEY",
                "OPENAI_BASE_URL",
                "OPENAI_API_BASE"
            ]
        case .codex:
            return appOnlySecrets + [
                "ANTHROPIC_API_KEY",
                "ANTHROPIC_AUTH_TOKEN",
                "ANTHROPIC_BASE_URL",
                "OPENAI_API_KEY",
                "OPENAI_BASE_URL",
                "OPENAI_API_BASE"
            ]
        case .openCode:
            return appOnlySecrets + [
                // HeyMate supplies a complete, isolated OpenCode runtime
                // configuration. Ambient control variables must not redirect
                // it back to user or project configuration.
                "OPENCODE_CONFIG",
                "OPENCODE_CONFIG_CONTENT",
                "OPENCODE_CONFIG_DIR",
                "OPENCODE_DISABLE_CLAUDE_CODE",
                "OPENCODE_DISABLE_DEFAULT_PLUGINS",
                "OPENCODE_DISABLE_EXTERNAL_SKILLS",
                "OPENCODE_DISABLE_PROJECT_CONFIG",
                "OPENCODE_PERMISSION",
                "OPENCODE_TEST_HOME",
                "OPENCODE_TEST_MANAGED_CONFIG_DIR"
            ]
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
