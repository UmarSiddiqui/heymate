//
//  HeadlessExecutorSignIn.swift
//  leanring-buddy
//
//  Getting a CLI signed in, from a button.
//
//  Every executor HeyMate spawns runs on a sign-in the user already pays for,
//  which is the whole point — but until now there was nowhere in the app to
//  *do* that sign-in, only a red dot telling you it had not happened.
//
//  The sign-in itself is an OAuth flow the CLI owns: it prints a URL, opens a
//  browser, waits on a local callback, and writes the credential to the
//  Keychain or its own auth file. HeyMate never sees a password or a token,
//  and must not — so rather than reimplement any of that, this opens Terminal
//  running the CLI's own login command and lets the user finish it there.
//
//  OpenClicky does something more elegant for Codex specifically: it asks the
//  codex app-server for `account/login/start`, gets back an `authUrl`, and
//  opens that directly. That needs the app-server JSON-RPC client, and it only
//  works for Codex. This works for every CLI today, including ones added
//  later.
//

import AppKit
import Foundation

nonisolated enum HeadlessExecutorSignIn {

    /// The CLI's own login command, keyed by executable name so an executor
    /// added later only needs a row here.
    ///
    /// `claude auth login --claudeai` is the subscription sign-in; the
    /// `--console` variant would bill the API instead, which is exactly what
    /// `HeadlessExecutor.environmentKeysToRemove` exists to prevent.
    static let commandsByExecutableName: [String: String] = [
        "claude": "claude auth login --claudeai",
        "opencode": "opencode auth login",
        "codex": "codex login"
    ]

    static func command(forExecutableNamed executableName: String) -> String? {
        commandsByExecutableName[executableName]
    }

    static func command(for executor: HeadlessExecutor) -> String? {
        command(forExecutableNamed: executor.executableName)
    }

    /// What the user is about to be shown, so the button can say it rather
    /// than opening a terminal without warning.
    static func signInDescription(for executor: HeadlessExecutor) -> String {
        switch executor {
        case .claudeCode:
            return "Opens Terminal and signs in to your Claude subscription in the browser."
        case .openCode:
            return "Opens Terminal so you can pick a provider and paste its key."
        case .codex:
            return "Opens Terminal and runs `codex login`. The ChatGPT app being signed in does not log the CLI in."
        }
    }

    /// AppleScript that opens Terminal and runs one command. Pure so the
    /// escaping can be tested without launching anything.
    static func terminalAppleScript(runningCommand command: String) -> String {
        let quotedCommand = HeyMateLocalAutomation.appleScriptStringLiteral(command)
        return """
        tell application "Terminal"
            activate
            do script \(quotedCommand)
        end tell
        """
    }

    /// Runs the CLI's login in Terminal. Returns false when there is no known
    /// command for that executable, so the caller can stay quiet rather than
    /// opening an empty window.
    @MainActor
    @discardableResult
    static func beginSignIn(for executor: HeadlessExecutor) -> Bool {
        beginSignIn(executableName: executor.executableName)
    }

    @MainActor
    @discardableResult
    static func beginSignIn(executableName: String) -> Bool {
        guard let command = command(forExecutableNamed: executableName) else { return false }
        let result = HeyMateLocalAutomation.runAppleScript(
            terminalAppleScript(runningCommand: command)
        )
        return result.succeeded
    }
}
