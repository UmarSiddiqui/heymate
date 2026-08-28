//
//  HeadlessExecutorSignInTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct HeadlessExecutorSignInTests {

    /// `--claudeai` is the subscription sign-in. `--console` would bill the
    /// API instead, which is the exact outcome the whole executor auth policy
    /// exists to prevent.
    @Test func claudeSignsInToTheSubscriptionNotTheAPIConsole() {
        let command = HeadlessExecutorSignIn.command(for: .claudeCode)
        #expect(command == "claude auth login --claudeai")
        #expect(command?.contains("--console") == false)
    }

    @Test func openCodeUsesItsOwnProviderLogin() {
        #expect(HeadlessExecutorSignIn.command(for: .openCode) == "opencode auth login")
    }

    /// Codex is not an executor yet, but the command table is keyed by
    /// executable name so it costs nothing to have the row ready.
    @Test func codexHasACommandWaitingForItsExecutor() {
        #expect(HeadlessExecutorSignIn.command(forExecutableNamed: "codex") == "codex login")
    }

    @Test func anUnknownCLIHasNoSignInCommand() {
        #expect(HeadlessExecutorSignIn.command(forExecutableNamed: "gemini") == nil)
    }

    @Test func everyExecutorCanBeSignedIn() {
        for executor in HeadlessExecutor.allCases {
            #expect(HeadlessExecutorSignIn.command(for: executor) != nil)
        }
    }

    @Test func codexSignsInThroughTheCLI() {
        #expect(HeadlessExecutorSignIn.command(for: .codex) == "codex login")
    }

    @Test func theScriptOpensTerminalAndRunsTheCommand() {
        let script = HeadlessExecutorSignIn.terminalAppleScript(runningCommand: "claude auth login --claudeai")
        #expect(script.contains("tell application \"Terminal\""))
        #expect(script.contains("activate"))
        #expect(script.contains(#"do script "claude auth login --claudeai""#))
    }

    /// The command is interpolated into an AppleScript string literal, so a
    /// quote in it would otherwise end the literal early.
    @Test func quotesInTheCommandAreEscaped() {
        let script = HeadlessExecutorSignIn.terminalAppleScript(runningCommand: #"echo "hi""#)
        #expect(script.contains(#"\"hi\""#))
    }
}
