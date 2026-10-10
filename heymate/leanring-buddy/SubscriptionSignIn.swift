//
//  SubscriptionSignIn.swift
//  leanring-buddy
//
//  One click from "I pay for Claude" to a CLI that answers.
//
//  HeyMate runs on the subscription the user already has, through the
//  vendor's own CLI. Until now that meant the user had to install the CLI,
//  put it on PATH, and sign in from Terminal before the first question
//  worked — which an ordinary Mac user will never do. This does all three:
//
//  1. Probe. `HeadlessExecutorReadinessProbe` already knows how to ask each
//     CLI whether it is installed and signed in without starting a turn.
//  2. Install, if missing, with the vendor's official installer. Both
//     install into `~/.local/bin`, which `LoginShellExecutableResolver`
//     always searches, so the new binary is found without a shell restart.
//       Claude: `curl -fsSL https://claude.ai/install.sh | bash`
//       Codex:  `curl -fsSL https://chatgpt.com/codex/install.sh | sh`
//               (`CODEX_NON_INTERACTIVE=1` so it never waits on a prompt)
//     Neither needs npm or Homebrew.
//  3. Sign in with the CLI's own browser login. Both run fine with no TTY:
//     `claude auth login --claudeai` and `codex login` each open the browser
//     and wait on a localhost callback, so the user only approves in the
//     browser. If that cannot start, Terminal opens with the one login
//     command already running.
//
//  Then it re-probes until the CLI says it is signed in. HeyMate never sees
//  a password or a token — the CLI owns the OAuth flow and its credential.
//

import AppKit
import Combine
import Foundation

extension Notification.Name {
    /// Asks HeyMate to install and sign in a subscription CLI.
    /// `userInfo["executor"]` is a `HeadlessExecutor.rawValue`. The Settings
    /// Accounts tab posts this by its string name, so the string is fixed.
    static let heyMateBeginSubscriptionSignIn = Notification.Name("heyMateBeginSubscriptionSignIn")
}

// MARK: - Phase

/// Where a sign-in stands. `statusLine` turns it into words.
nonisolated enum SubscriptionSignInPhase: Equatable, Sendable {
    case idle
    case checking
    case installing
    case waitingForBrowser
    case ready(detail: String)
    case failed(message: String)

    /// True while something is running and the UI should show progress.
    var isWorking: Bool {
        switch self {
        case .checking, .installing, .waitingForBrowser:
            return true
        case .idle, .ready, .failed:
            return false
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

// MARK: - Copy

/// Every sentence the sign-in flow shows, in one place, phrased for someone
/// who has never opened Terminal.
nonisolated enum SubscriptionSignInCopy {

    /// What the user pays for, not the CLI's name. Codex runs on ChatGPT.
    static func productName(for executor: HeadlessExecutor) -> String {
        switch executor {
        case .claudeCode: return "Claude"
        case .codex: return "ChatGPT"
        case .openCode: return "OpenCode"
        }
    }

    /// The tool that actually gets installed, for the one line that says so.
    static func toolName(for executor: HeadlessExecutor) -> String {
        switch executor {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex for ChatGPT"
        case .openCode: return "OpenCode"
        }
    }

    static func signInActionTitle(for executor: HeadlessExecutor) -> String {
        "Sign in to \(productName(for: executor))"
    }

    static func statusLine(for phase: SubscriptionSignInPhase, executor: HeadlessExecutor) -> String {
        let product = productName(for: executor)
        switch phase {
        case .idle:
            return ""
        case .checking:
            return "Checking \(product) on this Mac…"
        case .installing:
            return "Installing \(toolName(for: executor)). This takes about a minute…"
        case .waitingForBrowser:
            return "Finish signing in to \(product) in your browser."
        case .ready(let detail):
            return detail
        case .failed(let message):
            return message
        }
    }

    /// The fix to show next to a CLI that is not ready. Points at the
    /// one-click sign-in rather than at PATH or Terminal.
    static func signInRemedy(for executor: HeadlessExecutor) -> String {
        switch executor {
        case .claudeCode, .codex:
            return "\(signInActionTitle(for: executor)) from Settings → AI & Accounts."
        case .openCode:
            return "Sign in to OpenCode from Settings → AI & Accounts."
        }
    }

    static func notInstalledRemedy(for executor: HeadlessExecutor) -> String {
        switch executor {
        case .claudeCode, .codex:
            return "\(productName(for: executor)) isn't set up on this Mac yet. "
                + "\(signInActionTitle(for: executor)) from Settings → AI & Accounts and HeyMate sets it up for you."
        case .openCode:
            return "OpenCode isn't installed on this Mac. Get it from opencode.ai, then try again."
        }
    }

    /// Said in chat when a question failed because the CLI is signed out or
    /// missing. The notch shows the button this sentence names.
    static func signInNeededMessage(for executor: HeadlessExecutor) -> String {
        let product = productName(for: executor)
        return "\(product) isn't signed in on this Mac. Use “\(signInActionTitle(for: executor))” in the notch, "
            + "or open Settings → AI & Accounts. You can also switch this mate to another engine "
            + "from the menu under the message box."
    }

    static let neitherExplanation =
        "Chat works on this Mac. Questions about your screen need Claude or ChatGPT, which you can add later in Settings → AI & Accounts."
}

// MARK: - Install

nonisolated enum SubscriptionCLIInstallOutcome: Equatable, Sendable {
    case installed
    case failed(message: String)
}

/// The vendors' official installers. Each downloads a signed, checksummed
/// binary into `~/.local/bin`; neither needs npm, Homebrew, or sudo.
nonisolated enum SubscriptionCLIInstaller {

    static let installTimeout: TimeInterval = 5 * 60

    /// Shell line run by `/bin/bash -c`. `pipefail` so a failed download is
    /// a failed install rather than an empty script that "succeeded".
    static func installShellCommand(for executor: HeadlessExecutor) -> String? {
        switch executor {
        case .claudeCode:
            return "set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash"
        case .codex:
            return "set -o pipefail; curl -fsSL https://chatgpt.com/codex/install.sh | sh"
        case .openCode:
            return nil
        }
    }

    /// Codex's installer offers to launch Codex at the end. With no TTY it
    /// would decline on its own; this makes that explicit.
    static func environmentOverrides(for executor: HeadlessExecutor) -> [String: String] {
        switch executor {
        case .codex: return ["CODEX_NON_INTERACTIVE": "1"]
        case .claudeCode, .openCode: return [:]
        }
    }

    /// Where to send someone whose network or Mac refused the silent
    /// install, so the failure still ends in something to click.
    static func manualInstallURL(for executor: HeadlessExecutor) -> URL? {
        switch executor {
        case .claudeCode: return URL(string: "https://code.claude.com/docs/en/setup")
        case .codex: return URL(string: "https://developers.openai.com/codex/cli")
        case .openCode: return URL(string: "https://opencode.ai")
        }
    }

    /// Blocking. Call off the main actor.
    static func runInstall(for executor: HeadlessExecutor) -> SubscriptionCLIInstallOutcome {
        let toolName = SubscriptionSignInCopy.toolName(for: executor)
        guard let command = installShellCommand(for: executor) else {
            return .failed(message: "HeyMate can't install \(toolName) for you.")
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        // The same small allowlisted environment every CLI child gets, so no
        // API key reaches the installer or the `claude install` it runs.
        process.environment = HeadlessChildEnvironment.build(
            stripping: executor.environmentKeysToRemove,
            overrides: environmentOverrides(for: executor)
        )
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failed(message: "Couldn't start the \(toolName) installer.")
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + installTimeout, execute: watchdog)
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        HeyMateLog.log("📦 \(toolName) install exited \(process.terminationStatus): \(output.suffix(600))")

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            return .failed(
                message: "Couldn't install \(toolName). Check your internet connection and try again."
            )
        }
        return .installed
    }
}

// MARK: - Login

nonisolated enum SubscriptionCLILogin {

    /// The CLI's own browser login. `--claudeai` is the subscription; the
    /// `--console` variant would bill the API, which is never what we want.
    static func arguments(for executor: HeadlessExecutor) -> [String]? {
        switch executor {
        case .claudeCode: return ["auth", "login", "--claudeai"]
        case .codex: return ["login"]
        case .openCode: return nil
        }
    }

    /// A sign-in link the user can open themselves if the browser did not.
    ///
    /// Only a link whose redirect comes back to this Mac counts. Codex prints
    /// one (`redirect_uri=http://127.0.0.1:1455/…`). Claude prints a
    /// manual-code link instead, which ends on a page asking you to paste a
    /// code into a prompt nobody can see — so for Claude this returns nil and
    /// the UI offers Terminal, where that paste works.
    static func browserCompletableURL(in output: String) -> URL? {
        let pattern = #"https://[^\s"'<>]+"#
        var searchRange = output.startIndex..<output.endIndex
        while let match = output.range(of: pattern, options: .regularExpression, range: searchRange) {
            let candidate = String(output[match])
            let decoded = candidate.removingPercentEncoding ?? candidate
            if decoded.contains("redirect_uri=http://127.0.0.1")
                || decoded.contains("redirect_uri=http://localhost") {
                return URL(string: candidate)
            }
            searchRange = match.upperBound..<output.endIndex
        }
        return nil
    }

    /// Body of the `.command` file Terminal runs when the browser login
    /// cannot start on its own. Absolute path, because a CLI installed a
    /// moment ago is not on that Terminal's PATH until a new login shell.
    static func terminalScript(executablePath: String, executor: HeadlessExecutor) -> String? {
        guard let arguments = arguments(for: executor) else { return nil }
        let product = SubscriptionSignInCopy.productName(for: executor)
        let command = ([shellQuoted(executablePath)] + arguments).joined(separator: " ")
        let unsetKeys = executor.environmentKeysToRemove.joined(separator: " ")
        return """
        #!/bin/bash
        clear
        echo "HeyMate is signing you in to \(product)."
        echo "Approve it in your browser, then come back to HeyMate. You can close this window afterwards."
        echo
        unset \(unsetKeys)
        \(command)
        """
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Seams

/// A running CLI login. The coordinator only needs to know whether it ended
/// and whether it printed a link worth showing.
protocol SubscriptionLoginSession: AnyObject {
    /// Nil while the CLI is still waiting on the browser.
    var exitStatus: Int32? { get }
    var signInPageURL: URL? { get }
    func cancel()
}

/// Everything the coordinator does to the outside world, so tests can drive
/// the state machine without spawning, installing, or signing out of anything.
protocol SubscriptionSignInEnvironment {
    func probe(_ executor: HeadlessExecutor) async -> HeadlessExecutorReadiness
    func install(_ executor: HeadlessExecutor) async -> SubscriptionCLIInstallOutcome
    /// Nil when the CLI cannot be started headless (not found, spawn failed).
    func startBrowserLogin(_ executor: HeadlessExecutor) -> (any SubscriptionLoginSession)?
    /// Opens Terminal running the login command. False when it could not.
    func openTerminalLogin(_ executor: HeadlessExecutor) -> Bool
    func pause(seconds: TimeInterval) async
}

struct LiveSubscriptionSignInEnvironment: SubscriptionSignInEnvironment {

    func probe(_ executor: HeadlessExecutor) async -> HeadlessExecutorReadiness {
        await Task.detached(priority: .userInitiated) {
            HeadlessExecutorReadinessProbe.probe(executor)
        }.value
    }

    func install(_ executor: HeadlessExecutor) async -> SubscriptionCLIInstallOutcome {
        await Task.detached(priority: .userInitiated) {
            SubscriptionCLIInstaller.runInstall(for: executor)
        }.value
    }

    func startBrowserLogin(_ executor: HeadlessExecutor) -> (any SubscriptionLoginSession)? {
        LiveSubscriptionLoginSession(executor: executor)
    }

    func openTerminalLogin(_ executor: HeadlessExecutor) -> Bool {
        guard let executableURL = LoginShellExecutableResolver.resolveExecutable(named: executor.executableName),
              let script = SubscriptionCLILogin.terminalScript(
                executablePath: executableURL.path,
                executor: executor
              ) else {
            return false
        }
        // A `.command` file opens in Terminal by default and, unlike
        // `tell application "Terminal"`, needs no Automation permission.
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeyMate Sign In - \(SubscriptionSignInCopy.productName(for: executor)).command")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            return false
        }
        return NSWorkspace.shared.open(scriptURL)
    }

    func pause(seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }
}

/// `claude auth login` / `codex login` running headless. Standard input is a
/// pipe HeyMate holds open and never writes to: Claude's login reads a pasted
/// code from stdin as a fallback, and EOF there would end the login before
/// the browser had a chance to call back.
final class LiveSubscriptionLoginSession: SubscriptionLoginSession {

    private(set) var exitStatus: Int32?
    private(set) var signInPageURL: URL?

    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private var collectedOutput = ""

    init?(executor: HeadlessExecutor) {
        guard let arguments = SubscriptionCLILogin.arguments(for: executor),
              let executableURL = LoginShellExecutableResolver.resolveExecutable(named: executor.executableName) else {
            return nil
        }

        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = HeadlessChildEnvironment.build(stripping: executor.environmentKeysToRemove)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: chunk, as: UTF8.self)
            Task { @MainActor in self?.appendOutput(text) }
        }
        process.terminationHandler = { [weak self] finishedProcess in
            let status = finishedProcess.terminationStatus
            Task { @MainActor in self?.exitStatus = status }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
    }

    func cancel() {
        if process.isRunning { process.terminate() }
        try? inputPipe.fileHandleForWriting.close()
    }

    private func appendOutput(_ text: String) {
        collectedOutput += text
        if signInPageURL == nil {
            signInPageURL = SubscriptionCLILogin.browserCompletableURL(in: collectedOutput)
        }
    }
}

// MARK: - Coordinator

/// Owns one sign-in at a time and publishes where it stands.
final class SubscriptionSignInCoordinator: ObservableObject {

    @Published private(set) var phase: SubscriptionSignInPhase = .idle
    /// Which CLI the current or last run was for.
    @Published private(set) var executor: HeadlessExecutor?
    /// A link the user can open if the browser did not (Codex only).
    @Published private(set) var signInPageURL: URL?
    /// Where to install by hand after the silent install failed.
    @Published private(set) var manualInstallURL: URL?
    /// The login is running in Terminal rather than headless.
    @Published private(set) var isUsingTerminalFallback = false
    /// Set when a question failed because this CLI is not signed in, so the
    /// notch can offer the sign-in instead of an error.
    @Published private(set) var attentionExecutor: HeadlessExecutor?

    private let environment: any SubscriptionSignInEnvironment
    private let loginTimeout: TimeInterval
    private let pollInterval: TimeInterval
    /// Polls a successful CLI exit is allowed before the credential must show
    /// up in the probe. The CLI writes it before exiting, so this is slack.
    private let pollsAllowedAfterCleanExit = 3

    private var runTask: Task<Void, Never>?
    private var loginSession: (any SubscriptionLoginSession)?
    /// Bumped by every new run so a superseded run stops touching state.
    private var runGeneration = 0
    private var cancellables = Set<AnyCancellable>()

    init(
        environment: any SubscriptionSignInEnvironment = LiveSubscriptionSignInEnvironment(),
        loginTimeout: TimeInterval = 5 * 60,
        pollInterval: TimeInterval = 2,
        notificationCenter: NotificationCenter = .default
    ) {
        self.environment = environment
        self.loginTimeout = loginTimeout
        self.pollInterval = pollInterval

        notificationCenter.publisher(for: .heyMateBeginSubscriptionSignIn)
            .compactMap { $0.userInfo?["executor"] as? String }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rawValue in
                guard let executor = HeadlessExecutor(rawValue: rawValue) else { return }
                self?.begin(executor)
            }
            .store(in: &cancellables)
    }

    var statusLine: String {
        guard let executor else { return "" }
        return SubscriptionSignInCopy.statusLine(for: phase, executor: executor)
    }

    // MARK: Actions

    /// Checks, installs if needed, and signs in. Restarts if already running.
    func begin(_ executor: HeadlessExecutor) {
        stopCurrentRun()
        runTask = Task { [weak self] in
            await self?.run(executor)
        }
    }

    /// Drops whatever is running and forgets the last result.
    func cancel() {
        stopCurrentRun()
        runGeneration += 1
        phase = .idle
        executor = nil
        signInPageURL = nil
        manualInstallURL = nil
        isUsingTerminalFallback = false
    }

    /// The fallback for a browser that never opened or a login that failed
    /// headless: Terminal, with the one login command already running.
    func continueInTerminal() {
        guard let executor else { return }
        stopCurrentRun()
        runTask = Task { [weak self] in
            await self?.runTerminalSignIn(executor)
        }
    }

    /// A question failed because `executor` is signed out or missing.
    func noteSignInNeeded(for executor: HeadlessExecutor) {
        guard executor.usesSubscriptionSignIn else { return }
        attentionExecutor = executor
        // An earlier "ready" for this CLI is stale now — the CLI just said
        // otherwise — so the button comes back instead of a green check.
        if self.executor == executor, !phase.isWorking {
            phase = .idle
        }
    }

    func dismissAttention() {
        attentionExecutor = nil
    }

    /// Probes without installing or opening anything, and adopts the first
    /// CLI that is already signed in. Used to preselect an onboarding answer.
    /// Returns nil when none is ready or the user started something meanwhile.
    @discardableResult
    func adoptExistingSignIn(among executors: [HeadlessExecutor]) async -> HeadlessExecutor? {
        guard phase == .idle, executor == nil else { return nil }
        for candidate in executors where candidate.usesSubscriptionSignIn {
            let readiness = await environment.probe(candidate)
            guard phase == .idle, executor == nil else { return nil }
            if readiness.state == .ready || readiness.state == .usingAPIKey {
                executor = candidate
                phase = .ready(detail: readiness.detail)
                return candidate
            }
        }
        return nil
    }

    // MARK: State machine

    /// The whole flow. Exposed so tests can await it directly.
    func run(_ executor: HeadlessExecutor) async {
        runGeneration += 1
        let generation = runGeneration
        resetForRun(executor)

        guard executor.usesSubscriptionSignIn else {
            // OpenCode signs in to a provider of the user's choosing, which
            // is a picker in its own terminal UI. Nothing to automate.
            _ = HeadlessExecutorSignIn.beginSignIn(for: executor)
            phase = .idle
            return
        }

        phase = .checking
        var readiness = await environment.probe(executor)
        guard isCurrent(generation) else { return }

        if readiness.state == .notInstalled {
            phase = .installing
            let outcome = await environment.install(executor)
            guard isCurrent(generation) else { return }
            if case .failed(let message) = outcome {
                manualInstallURL = SubscriptionCLIInstaller.manualInstallURL(for: executor)
                phase = .failed(message: message)
                return
            }

            phase = .checking
            readiness = await environment.probe(executor)
            guard isCurrent(generation) else { return }
            if readiness.state == .notInstalled {
                manualInstallURL = SubscriptionCLIInstaller.manualInstallURL(for: executor)
                phase = .failed(
                    message: "\(SubscriptionSignInCopy.toolName(for: executor)) installed, but HeyMate can't find it yet. Quit and reopen HeyMate, then try again."
                )
                return
            }
        }

        switch readiness.state {
        case .ready, .usingAPIKey, .indeterminate:
            finishReady(readiness, executor: executor)
            return
        case .notSignedIn, .notInstalled:
            break
        }

        phase = .waitingForBrowser
        if let session = environment.startBrowserLogin(executor) {
            loginSession = session
            signInPageURL = session.signInPageURL
        } else if environment.openTerminalLogin(executor) {
            isUsingTerminalFallback = true
        } else {
            phase = .failed(
                message: "Couldn't start the \(SubscriptionSignInCopy.productName(for: executor)) sign-in. Try again."
            )
            return
        }
        await waitForSignIn(executor, generation: generation)
    }

    func runTerminalSignIn(_ executor: HeadlessExecutor) async {
        runGeneration += 1
        let generation = runGeneration
        resetForRun(executor)
        phase = .waitingForBrowser
        guard environment.openTerminalLogin(executor) else {
            phase = .failed(message: "Couldn't open Terminal. Try again.")
            return
        }
        isUsingTerminalFallback = true
        await waitForSignIn(executor, generation: generation)
    }

    /// Re-probes until the CLI reports a sign-in, the login gives up, or the
    /// timeout passes. Counted in polls rather than wall-clock time so a test
    /// with an instant `pause` still terminates.
    private func waitForSignIn(_ executor: HeadlessExecutor, generation: Int) async {
        let product = SubscriptionSignInCopy.productName(for: executor)
        let maximumPolls = max(1, Int((loginTimeout / max(pollInterval, 0.001)).rounded(.up)))
        var pollsSinceCleanExit = 0

        for _ in 0..<maximumPolls {
            await environment.pause(seconds: pollInterval)
            guard isCurrent(generation) else { return }

            if let session = loginSession, signInPageURL == nil {
                signInPageURL = session.signInPageURL
            }

            let readiness = await environment.probe(executor)
            guard isCurrent(generation) else { return }
            if readiness.state == .ready || readiness.state == .usingAPIKey {
                endLoginSession()
                finishReady(readiness, executor: executor)
                return
            }

            guard let exitStatus = loginSession?.exitStatus else { continue }
            if exitStatus != 0 {
                endLoginSession()
                phase = .failed(
                    message: "The \(product) sign-in didn't finish. Try again, or finish it in Terminal."
                )
                return
            }
            pollsSinceCleanExit += 1
            if pollsSinceCleanExit >= pollsAllowedAfterCleanExit {
                endLoginSession()
                phase = .failed(
                    message: "\(product) didn't confirm the sign-in. Try again, or finish it in Terminal."
                )
                return
            }
        }

        endLoginSession()
        phase = .failed(message: "The \(product) sign-in timed out. Try again when you're ready.")
    }

    // MARK: Helpers

    private func finishReady(_ readiness: HeadlessExecutorReadiness, executor: HeadlessExecutor) {
        let detail: String
        switch readiness.state {
        case .indeterminate:
            // The probe itself hiccuped. The CLI is installed and a job is
            // allowed through, so do not block the user on it.
            detail = "\(SubscriptionSignInCopy.toolName(for: executor)) is installed"
        default:
            detail = readiness.detail
        }
        signInPageURL = nil
        manualInstallURL = nil
        phase = .ready(detail: detail)
        clearAttentionSoon(for: executor)
    }

    /// Leaves the green check on screen for a moment before the notch
    /// banner that asked for this sign-in goes away.
    private func clearAttentionSoon(for executor: HeadlessExecutor) {
        guard attentionExecutor == executor else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.environment.pause(seconds: 4)
            if self.attentionExecutor == executor, self.phase.isReady {
                self.attentionExecutor = nil
            }
        }
    }

    private func resetForRun(_ executor: HeadlessExecutor) {
        endLoginSession()
        self.executor = executor
        signInPageURL = nil
        manualInstallURL = nil
        isUsingTerminalFallback = false
    }

    private func stopCurrentRun() {
        runTask?.cancel()
        runTask = nil
        endLoginSession()
    }

    private func endLoginSession() {
        loginSession?.cancel()
        loginSession = nil
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == runGeneration && !Task.isCancelled
    }
}
