//
//  HeadlessExecutorReadiness.swift
//  leanring-buddy
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
                remedy: "Install \(executor.displayName) and make sure `\(executor.executableName)` is on your PATH."
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
        guard let result = runCapturingStandardOutput(
            executableURL: executableURL,
            arguments: ["auth", "status", "--json"]
        ) else {
            return .indeterminate(detail: "Could not read auth status")
        }

        guard let statusData = result.standardOutput.data(using: .utf8),
              let status = try? JSONSerialization.jsonObject(with: statusData) as? [String: Any] else {
            return .indeterminate(detail: "Could not read auth status")
        }

        let isLoggedIn = (status["loggedIn"] as? Bool) ?? false
        guard isLoggedIn else {
            return HeadlessExecutorReadiness(
                state: .notSignedIn,
                detail: "Signed out",
                remedy: "Run `claude` in Terminal and sign in with /login, then try again."
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
                remedy: "Jobs will bill your API account, not your subscription. Remove ANTHROPIC_API_KEY from your environment to use the plan."
            )
        }

        return .ready(detail: detail)
    }

    // MARK: - OpenCode

    /// OpenCode is never blocked on sign-in: its free `opencode/*` models run
    /// with no credentials at all. The probe reports what is connected so the
    /// settings row can say whether a real provider is available.
    private static func probeOpenCode(executableURL: URL) -> HeadlessExecutorReadiness {
        guard let result = runCapturingStandardOutput(
            executableURL: executableURL,
            arguments: ["auth", "list"]
        ), result.exitStatus == 0 else {
            return .indeterminate(detail: "Installed")
        }

        let credentialCount = parsedCredentialCount(from: result.standardOutput)
        guard credentialCount > 0 else {
            return HeadlessExecutorReadiness(
                state: .ready,
                detail: "No providers connected",
                remedy: "Run `opencode auth login` to add a provider. Free models still work without one."
            )
        }

        let pluralSuffix = credentialCount == 1 ? "" : "s"
        return .ready(detail: "\(credentialCount) provider\(pluralSuffix) connected")
    }

    // MARK: - Codex

    /// `codex login status` is cheap and starts no turn. The ChatGPT macOS
    /// app being signed in is a *different* credential store — this probe
    /// reports the CLI, which is what HeyMate actually spawns.
    private static func probeCodex(executableURL: URL) -> HeadlessExecutorReadiness {
        guard let result = runCapturingStandardOutput(
            executableURL: executableURL,
            arguments: ["login", "status"]
        ) else {
            return .indeterminate(detail: "Could not read login status")
        }

        let output = result.standardOutput
        let lowered = output.lowercased()
        if lowered.contains("not logged in") {
            return HeadlessExecutorReadiness(
                state: .notSignedIn,
                detail: "Signed out of the Codex CLI",
                remedy: "The ChatGPT app being signed in is not enough. Tap Sign in — that runs `codex login` in Terminal."
            )
        }
        if lowered.contains("logged in") || lowered.contains("chatgpt") || output.contains("@") {
            let firstLine = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Codex"
            return .ready(detail: firstLine.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if result.exitStatus != 0 {
            return HeadlessExecutorReadiness(
                state: .notSignedIn,
                detail: "Signed out",
                remedy: "Tap Sign in to run `codex login` in Terminal."
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
        let standardOutput: String
        let exitStatus: Int32
    }

    /// Runs a short-lived probe command. stderr goes to the null device so an
    /// unread pipe can never block the child, and a watchdog terminates a
    /// command that hangs rather than letting a settings refresh wedge.
    private static func runCapturingStandardOutput(
        executableURL: URL,
        arguments: [String]
    ) -> CapturedOutput? {
        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = HeadlessChildEnvironment.build(stripping: [])
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
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
            standardOutput: String(data: outputData, encoding: .utf8) ?? "",
            exitStatus: process.terminationStatus
        )
    }
}
