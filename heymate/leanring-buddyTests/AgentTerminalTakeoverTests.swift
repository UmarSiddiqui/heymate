//
//  AgentTerminalTakeoverTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct AgentTerminalTakeoverTests {

    /// The interactive resume forms, not the headless ones. `claude -p
    /// --resume` would run one more silent turn and exit; the whole point of
    /// a takeover is landing in the TUI with the transcript on screen.
    @Test func eachExecutorResumesItsSessionInteractively() {
        #expect(
            AgentTerminalTakeover.interactiveResumeArguments(
                forExecutableNamed: "claude",
                sessionIdentifier: "abc"
            ) == ["--resume", "abc"]
        )
        #expect(
            AgentTerminalTakeover.interactiveResumeArguments(
                forExecutableNamed: "opencode",
                sessionIdentifier: "ses_1"
            ) == ["--session", "ses_1"]
        )
        #expect(
            AgentTerminalTakeover.interactiveResumeArguments(
                forExecutableNamed: "codex",
                sessionIdentifier: "thread_1"
            ) == ["resume", "thread_1"]
        )
        #expect(
            AgentTerminalTakeover.interactiveResumeArguments(
                forExecutableNamed: "claude",
                sessionIdentifier: "abc"
            )?.contains("-p") == false
        )
    }

    @Test func unknownExecutableHasNoCommand() {
        #expect(
            AgentTerminalTakeover.shellCommand(
                executableName: "aider",
                sessionIdentifier: "abc",
                workspacePath: "/tmp/work"
            ) == nil
        )
    }

    /// A job whose first leg has not reported a session yet must not open a
    /// terminal on `claude --resume ''`.
    @Test func missingSessionIdentifierHasNoCommand() {
        #expect(
            AgentTerminalTakeover.shellCommand(
                executableName: "claude",
                sessionIdentifier: "   ",
                workspacePath: "/tmp/work"
            ) == nil
        )
    }

    @Test func commandChangesIntoTheWorkspaceFirst() {
        let command = AgentTerminalTakeover.shellCommand(
            executableName: "claude",
            sessionIdentifier: "1234",
            workspacePath: "/Users/someone/Projects/heymate/landing-page"
        )
        #expect(
            command == "cd '/Users/someone/Projects/heymate/landing-page' && 'claude' '--resume' '1234'"
        )
    }

    /// Workspace folders are named from the user's own task text, so spaces,
    /// quotes and `$` all turn up in real paths. Single quotes are the only
    /// form where none of it is interpreted.
    @Test func workspacePathWithQuotesAndSpacesStaysOneArgument() {
        let command = AgentTerminalTakeover.shellCommand(
            executableName: "claude",
            sessionIdentifier: "1234",
            workspacePath: "/tmp/Sam's $HOME notes; rm -rf /"
        )
        #expect(
            command == "cd '/tmp/Sam'\\''s $HOME notes; rm -rf /' && 'claude' '--resume' '1234'"
        )
    }

    @Test func sessionIdentifierIsQuotedToo() {
        let command = AgentTerminalTakeover.shellCommand(
            executableName: "codex",
            sessionIdentifier: "abc'; rm -rf ~",
            workspacePath: "/tmp/work"
        )
        #expect(command?.contains("'abc'\\''; rm -rf ~'") == true)
    }
}
