//
//  HeadlessExecutorReadiness.swift
//  HeyMate
//
//  Answers "can this CLI actually do a job right now" before a job is spawned.
//  Checking `PATH` alone is not enough: a signed-out `claude -p` exits
//  non-zero and streams a result line that is an error and is labelled
//  `"subtype": "success"` at the same time, so a job that never had a chance
//  looked to the user like a job that ran and did nothing.
//

import Foundation

/// What a preflight found, plus the sentence to show the user when it is bad.
nonisolated struct HeadlessExecutorReadiness: Equatable, Sendable {

    enum State: Equatable, Sendable {
        /// Installed and signed in on the subscription HeyMate expects.
        case ready
        /// Installed and signed in, but billing an API key rather than the
        /// subscription. Jobs still run — this is a warning, not a blocker.
        case usingAPIKey
        case notInstalled
        case notSignedIn
        /// The probe itself failed (timed out, unparseable output). Jobs are
        /// allowed through: a broken probe must not become a broken app.
        case indeterminate
    }

    var state: State
    /// Short status for a settings row: "Claude Pro · you@example.com".
    var detail: String
    /// What the user should do about it. Empty when there is nothing to do.
    var remedy: String

    /// Whether a job may be spawned. Only a definite negative blocks.
    var allowsLaunch: Bool {
        switch state {
        case .ready, .usingAPIKey, .indeterminate:
            return true
        case .notInstalled, .notSignedIn:
            return false
        }
    }

    static func ready(detail: String) -> Self {
        HeadlessExecutorReadiness(state: .ready, detail: detail, remedy: "")
    }

    static func indeterminate(detail: String = "Status unknown") -> Self {
        HeadlessExecutorReadiness(state: .indeterminate, detail: detail, remedy: "")
    }
}

nonisolated enum HeadlessExecutorReadinessProbe {

    /// Probes spawn a CLI, so they must not run on the main actor. Callers
    /// hop to a background queue; the work here is synchronous and bounded.
    static let probeTimeout: TimeInterval = 10

    static func probe(_ executor: HeadlessExecutor) -> HeadlessExecutorReadiness {
        guard let executableURL = LoginShellExecutableResolver.resolveExecutable(
            named: executor.executableName
        ) else {
            return HeadlessExecutorReadiness(
                state: .notInstalled,
                detail: "Not installed",
                remedy: SubscriptionSignInCopy.notInstalledRemedy(for: executor)
            )
        }

        switch executor {
        case .claudeCode:
            return probeClaudeCode(executableURL: executableURL)
        case .openCode:
            return probeOpenCode(executableURL: executableURL)
        case .codex:
            return probeCodex(executableURL: executableURL)
        }
    }

    // MARK: - Claude Code

    /// `claude auth status` prints JSON and does not start a turn, so this
    /// costs nothing against the subscription.
    private static func probeClaudeCode(executableURL: URL) -> HeadlessExecutorReadiness {
        guard let result = runCapturingOutput(
            executableURL: executableURL,
            arguments: ["auth", "status", "--json"],
            environmentKeysToRemove: HeadlessExecutor.claudeCode.environmentKeysToRemove
        ) else {
            return .indeterminate(detail: "Could not read auth status")
        }

        guard let statusData = result.output.data(using: .utf8),
              let status = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any] else {
            return .indeterminate(detail: "Could not read auth status")
        }

        let isLoggedIn = (status["loggedIn"] as? Bool) ?? false
        guard isLoggedIn else {
            return HeadlessExecutorReadiness(
                state: .notSignedIn,
                detail: "Signed out",
                remedy: SubscriptionSignInCopy.signInRemedy(for: .claudeCode)
            )
        }

        let authenticationMethod = (status["authMethod"] as? String) ?? ""
        let subscriptionType = (status["subscriptionType"] as? String) ?? ""
        let accountEmail = (status["email"] as? String) ?? ""

        // "claude.ai" is the subscription sign-in. Anything else means the CLI
        // resolved an API key, which bills separately from the plan.
        let isSubscriptionSignIn = authenticationMethod == "claude.ai"
        let planLabel = subscriptionType.isEmpty
            ? "Claude Code"
            : "Claude \(subscriptionType.capitalized)"
        let detail = accountEmail.isEmpty ? planLabel : "\(planLabel) · \(accountEmail)"

        guard isSubscriptionSignIn else {
            return HeadlessExecutorReadiness(
                state: .usingAPIKey,
                detail: "API key (\(authenticationMethod.isEmpty ? "not claude.ai" : authenticationMethod))",
                remedy: "This Claude sign-in may bill an API account instead of your plan. Sign out, then sign in to Claude again from Settings → AI & Accounts."
            )
        }

        return .ready(detail: detail)
    }

    // MARK: - OpenCode

    /// OpenCode is never blocked on sign-in: its free `opencode/*` models run
    /// with no credentials at all. The probe reports what is connected so the
    /// settings row can say whether a real provider is available.
    private static func probeOpenCode(executableURL: URL) -> HeadlessExecutorReadiness {
        guard let result = runCapturingOutput(
            executableURL: executableURL,
            arguments: ["auth", "list"],
            environmentKeysToRemove: HeadlessExecutor.openCode.environmentKeysToRemove
        ), result.exitStatus == 0 else {
            return .indeterminate(detail: "Installed")
        }

        let credentialCount = parsedCredentialCount(from: result.output)
        guard credentialCount > 0 else {
            return HeadlessExecutorReadiness(
                state: .ready,
                detail: "No providers connected",
                remedy: "Add a provider from Settings → AI & Accounts. Free models still work without one."
            )
        }

        let pluralSuffix = credentialCount == 1 ? "" : "s"
        return .ready(detail: "\(credentialCount) provider\(pluralSuffix) connected")
    }

    // MARK: - Codex

    /// `codex login status` is cheap and starts no turn. The ChatGPT macOS
    /// app being signed in is a *different* credential store — this probe
    /// reports the CLI, which is what HeyMate actually spawns.
    static func probeCodex(
        executableURL: URL,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HeadlessExecutorReadiness {
        guard let result = runCapturingOutput(
            executableURL: executableURL,
            arguments: ["login", "status"],
            includeStandardError: true,
            environmentKeysToRemove: HeadlessExecutor.codex.environmentKeysToRemove,
            processEnvironment: processEnvironment
        ) else {
            return .indeterminate(detail: "Could not read login status")
        }

        return codexReadiness(from: result.output, exitStatus: result.exitStatus)
    }

    nonisolated static func codexReadiness(
        from output: String,
        exitStatus: Int32
    ) -> HeadlessExecutorReadiness {
        let lowered = output.lowercased()
        if lowered.contains("not logged in") {
            return HeadlessExecutorReadiness(
                state: .notSignedIn,
                detail: "Signed out of the Codex CLI",
                remedy: "The ChatGPT app being signed in is not enough. " + SubscriptionSignInCopy.signInRemedy(for: .codex)
            )
        }
        if lowered.contains("chatgpt") {
            return .ready(detail: "Codex · ChatGPT subscription")
        }
        // Environment API keys were removed before this probe. These strings
        // therefore identify a credential persisted by the Codex CLI itself;
        // the child will use it too, so present an explicit billing warning.
        let meteredCredentialMarkers = [
            "logged in using an api key",
            "logged in using api key",
            "access token",
            "personal token",
            "personal access token",
            "bedrock",
            "azure",
            "vertex"
        ]
        if meteredCredentialMarkers.contains(where: lowered.contains) || lowered.contains("logged in") {
            return HeadlessExecutorReadiness(
                state: .usingAPIKey,
                detail: "Codex · non-ChatGPT credential",
                remedy: "This Codex sign-in may bill an API or provider account instead of your plan. Sign out, then sign in to ChatGPT again from Settings → AI & Accounts."
            )
        }
        if exitStatus != 0 {
            return HeadlessExecutorReadiness(
                state: .notSignedIn,
                detail: "Signed out",
                remedy: SubscriptionSignInCopy.signInRemedy(for: .codex)
            )
        }
        return .indeterminate(detail: "Installed")
    }

    /// `opencode auth list` renders a box-drawn list ending in "N credentials".
    /// Its output is a TUI, not a contract, so a miss returns zero rather than
    /// failing the probe.
    private static func parsedCredentialCount(from output: String) -> Int {
        let pattern = #"(\d+)\s+credential"#
        guard let match = output.range(of: pattern, options: .regularExpression) else { return 0 }
        let digits = output[match].prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    // MARK: - Process helper

    private struct CapturedOutput {
        let output: String
        let exitStatus: Int32
    }

    /// Runs a short-lived probe command. Most probes discard stderr so an
    /// unread pipe can never block the child. Codex is the exception: current
    /// releases print `login status` to stderr even on a successful exit, so
    /// that probe merges both streams into the pipe it parses.
    private static func runCapturingOutput(
        executableURL: URL,
        arguments: [String],
        includeStandardError: Bool = false,
        environmentKeysToRemove: [String],
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CapturedOutput? {
        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = HeadlessChildEnvironment.build(
            stripping: environmentKeysToRemove,
            processEnvironment: processEnvironment
        )
        process.standardOutput = outputPipe
        process.standardError = includeStandardError ? outputPipe : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + probeTimeout, execute: watchdog)

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        return CapturedOutput(
            output: String(data: outputData, encoding: .utf8) ?? "",
            exitStatus: process.terminationStatus
        )
    }
}
