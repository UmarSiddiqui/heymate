//
//  AgentTerminalTakeover.swift
//  leanring-buddy
//
//  Handing a running agent job over to the user, in a real terminal.
//
//  HeyMate spawns its CLIs headless, which is what makes the plan/approve
//  gate possible — but it also means the only way to say something to a
//  working agent is `sendFollowUp`, and that queues the turn until the
//  current leg finishes. There is no way to interrupt, argue, or drive.
//
//  Every executor already stores the session both legs share, and every one
//  of them can reopen that session interactively from a shell. So rather
//  than build a second, worse terminal inside the app, this closes HeyMate's
//  headless process and opens Terminal on the same session in the same
//  folder. From that point the user is driving the identical conversation,
//  with their own sign-in, on a real TTY.
//
//  Nothing secret goes into the command line: Terminal inherits the user's
//  own login shell environment, and the session identifier is not a
//  credential.
//

import AppKit
import Foundation

nonisolated enum AgentTerminalTakeover {

    /// Why a job cannot be taken over, in the words the button should use.
    enum Unavailability: Error, Equatable {
        /// Leg one has not told us its session id yet. OpenCode and Codex
        /// mint their own and only report it partway through the stream, so
        /// a job can genuinely be running with nothing to hand over.
        case sessionNotStartedYet
        case runNotFound

        var explanation: String {
            switch self {
            case .sessionNotStartedYet:
                return "This job hasn't reported its session yet. Give it a moment and try again."
            case .runNotFound:
                return "That job is no longer around."
            }
        }
    }

    /// The interactive resume command for each executor, keyed by executable
    /// name so an executor added later only needs a row here.
    ///
    /// These are deliberately the *interactive* forms, not the headless ones
    /// in `HeadlessCLIAdapter`: `claude --resume` opens the TUI on the stored
    /// session, where `claude -p --resume` would run one more silent turn.
    static func interactiveResumeArguments(
        forExecutableNamed executableName: String,
        sessionIdentifier: String
    ) -> [String]? {
        switch executableName {
        case "claude":
            return ["--resume", sessionIdentifier]
        case "opencode":
            return ["--session", sessionIdentifier]
        case "codex":
            return ["resume", sessionIdentifier]
        default:
            return nil
        }
    }

    /// `cd <workspace> && <cli> <resume args>`, shell-quoted.
    ///
    /// Pure, so the quoting can be tested without launching anything. Returns
    /// nil for an unknown executable or an empty session id rather than
    /// opening a terminal on a command that cannot work.
    static func shellCommand(
        executableName: String,
        sessionIdentifier: String,
        workspacePath: String
    ) -> String? {
        let trimmedSessionIdentifier = sessionIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionIdentifier.isEmpty, !workspacePath.isEmpty else { return nil }
        guard let resumeArguments = interactiveResumeArguments(
            forExecutableNamed: executableName,
            sessionIdentifier: trimmedSessionIdentifier
        ) else { return nil }

        let quotedArguments = ([executableName] + resumeArguments)
            .map(singleQuotedShellArgument)
            .joined(separator: " ")
        return "cd \(singleQuotedShellArgument(workspacePath)) && \(quotedArguments)"
    }

    static func shellCommand(for run: AgentRun) -> String? {
        shellCommand(
            executableName: run.executor.executableName,
            sessionIdentifier: run.sessionIdentifier,
            workspacePath: run.workspacePath
        )
    }

    /// Wraps `value` in single quotes, ending and reopening the quoted run
    /// around any single quote inside it. A workspace path is user-chosen and
    /// can contain spaces, quotes, and `$`; single quotes are the only form
    /// where none of that is interpreted.
    static func singleQuotedShellArgument(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What the user is about to be shown, so the button can warn rather than
    /// silently killing their job and opening a window.
    static func takeoverDescription(for executor: HeadlessExecutor) -> String {
        "Stops HeyMate's \(executor.displayName) process and reopens the same session in Terminal, "
            + "where you drive it yourself. HeyMate stops tracking the job from that point."
    }

    /// Opens Terminal on the job's session. Returns false when the AppleScript
    /// did not run, so the caller can surface that instead of assuming a
    /// window appeared.
    @MainActor
    @discardableResult
    static func openInTerminal(command: String) -> Bool {
        let result = HeyMateLocalAutomation.runAppleScript(
            HeadlessExecutorSignIn.terminalAppleScript(runningCommand: command)
        )
        return result.succeeded
    }
}
