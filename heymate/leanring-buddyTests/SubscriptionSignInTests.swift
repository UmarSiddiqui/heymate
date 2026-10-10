//
//  SubscriptionSignInTests.swift
//  leanring-buddyTests
//
//  The one-click sign-in state machine, driven through a fake environment so
//  nothing is installed, spawned, or signed out on the machine running tests.
//

import Combine
import Foundation
import Testing
@testable import HeyMate

@MainActor
private final class FakeLoginSession: SubscriptionLoginSession {
    var exitStatus: Int32?
    var signInPageURL: URL?
    private(set) var wasCancelled = false

    func cancel() { wasCancelled = true }
}

@MainActor
private final class FakeSignInEnvironment: SubscriptionSignInEnvironment {
    /// Answers handed out in order; the last one repeats.
    var probeResults: [HeadlessExecutorReadiness]
    var installOutcome: SubscriptionCLIInstallOutcome = .installed
    var loginSession: FakeLoginSession? = FakeLoginSession()
    var terminalOpens = true
    /// Runs before each probe after the first `n`, to simulate the CLI
    /// exiting partway through a login.
    var onPoll: ((Int) -> Void)?

    private(set) var probeCount = 0
    private(set) var installCount = 0
    private(set) var browserLoginCount = 0
    private(set) var terminalLoginCount = 0
    private(set) var pauseCount = 0

    init(probeResults: [HeadlessExecutorReadiness]) {
        self.probeResults = probeResults
    }

    func probe(_ executor: HeadlessExecutor) async -> HeadlessExecutorReadiness {
        let index = min(probeCount, probeResults.count - 1)
        probeCount += 1
        return probeResults[index]
    }

    func install(_ executor: HeadlessExecutor) async -> SubscriptionCLIInstallOutcome {
        installCount += 1
        return installOutcome
    }

    func startBrowserLogin(_ executor: HeadlessExecutor) -> (any SubscriptionLoginSession)? {
        browserLoginCount += 1
        return loginSession
    }

    func openTerminalLogin(_ executor: HeadlessExecutor) -> Bool {
        terminalLoginCount += 1
        return terminalOpens
    }

    func pause(seconds: TimeInterval) async {
        pauseCount += 1
        onPoll?(pauseCount)
    }
}

private extension HeadlessExecutorReadiness {
    static let notInstalled = HeadlessExecutorReadiness(state: .notInstalled, detail: "Not installed", remedy: "")
    static let signedOut = HeadlessExecutorReadiness(state: .notSignedIn, detail: "Signed out", remedy: "")
    static let claudeMax = HeadlessExecutorReadiness.ready(detail: "Claude Max · you@example.com")
}

@MainActor
struct SubscriptionSignInTests {

    private func makeCoordinator(
        _ environment: FakeSignInEnvironment,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> SubscriptionSignInCoordinator {
        SubscriptionSignInCoordinator(
            environment: environment,
            loginTimeout: 10,
            pollInterval: 1,
            notificationCenter: notificationCenter
        )
    }

    /// Records every phase the coordinator publishes, in order.
    private func recordPhases(of coordinator: SubscriptionSignInCoordinator) -> (() -> [SubscriptionSignInPhase], AnyCancellable) {
        var phases: [SubscriptionSignInPhase] = []
        let cancellable = coordinator.$phase.dropFirst().sink { phases.append($0) }
        return ({ phases }, cancellable)
    }

    @Test func alreadySignedInIsReadyWithoutInstallingOrOpeningAnything() async {
        let environment = FakeSignInEnvironment(probeResults: [.claudeMax])
        let coordinator = makeCoordinator(environment)
        let (phases, token) = recordPhases(of: coordinator)

        await coordinator.run(.claudeCode)

        #expect(phases() == [.checking, .ready(detail: "Claude Max · you@example.com")])
        #expect(environment.installCount == 0)
        #expect(environment.browserLoginCount == 0)
        #expect(environment.terminalLoginCount == 0)
        #expect(coordinator.statusLine == "Claude Max · you@example.com")
        _ = token
    }

    @Test func missingCLIIsInstalledThenSignedInThroughTheBrowser() async {
        let environment = FakeSignInEnvironment(probeResults: [
            .notInstalled,  // first check
            .signedOut,     // after install
            .signedOut,     // first poll: still in the browser
            .claudeMax      // second poll: approved
        ])
        let session = environment.loginSession!
        let coordinator = makeCoordinator(environment)
        let (phases, token) = recordPhases(of: coordinator)

        await coordinator.run(.claudeCode)

        #expect(phases() == [
            .checking,
            .installing,
            .checking,
            .waitingForBrowser,
            .ready(detail: "Claude Max · you@example.com")
        ])
        #expect(environment.installCount == 1)
        #expect(environment.browserLoginCount == 1)
        #expect(environment.terminalLoginCount == 0)
        // A finished login process is cleaned up, never left running.
        #expect(session.wasCancelled)
        _ = token
    }

    @Test func failedInstallOffersADownloadLinkAndNeverTriesToSignIn() async {
        let environment = FakeSignInEnvironment(probeResults: [.notInstalled])
        environment.installOutcome = .failed(message: "Couldn't install Codex for ChatGPT. Check your internet connection and try again.")
        let coordinator = makeCoordinator(environment)

        await coordinator.run(.codex)

        #expect(coordinator.phase == .failed(
            message: "Couldn't install Codex for ChatGPT. Check your internet connection and try again."
        ))
        #expect(coordinator.manualInstallURL == SubscriptionCLIInstaller.manualInstallURL(for: .codex))
        #expect(environment.browserLoginCount == 0)
    }

    @Test func installThatStillCannotBeFoundFailsHonestly() async {
        let environment = FakeSignInEnvironment(probeResults: [.notInstalled, .notInstalled])
        let coordinator = makeCoordinator(environment)

        await coordinator.run(.claudeCode)

        guard case .failed(let message) = coordinator.phase else {
            Issue.record("expected failure, got \(coordinator.phase)")
            return
        }
        #expect(message.contains("can't find it"))
        #expect(environment.browserLoginCount == 0)
    }

    @Test func headlessLoginUnavailableFallsBackToTerminal() async {
        let environment = FakeSignInEnvironment(probeResults: [.signedOut, .signedOut, .claudeMax])
        environment.loginSession = nil
        let coordinator = makeCoordinator(environment)

        await coordinator.run(.claudeCode)

        #expect(environment.terminalLoginCount == 1)
        #expect(coordinator.isUsingTerminalFallback)
        #expect(coordinator.phase.isReady)
    }

    @Test func noHeadlessLoginAndNoTerminalIsAFailureNotAHang() async {
        let environment = FakeSignInEnvironment(probeResults: [.signedOut])
        environment.loginSession = nil
        environment.terminalOpens = false
        let coordinator = makeCoordinator(environment)

        await coordinator.run(.codex)

        guard case .failed = coordinator.phase else {
            Issue.record("expected failure, got \(coordinator.phase)")
            return
        }
        #expect(environment.pauseCount == 0)
    }

    @Test func loginThatExitsWithAnErrorFailsAndOffersTerminal() async {
        let environment = FakeSignInEnvironment(probeResults: [.signedOut])
        let session = environment.loginSession!
        environment.onPoll = { poll in
            if poll == 2 { session.exitStatus = 1 }
        }
        let coordinator = makeCoordinator(environment)

        await coordinator.run(.codex)

        #expect(coordinator.phase == .failed(
            message: "The ChatGPT sign-in didn't finish. Try again, or finish it in Terminal."
        ))
        // Terminal is the fallback, so no download link replaces it.
        #expect(coordinator.manualInstallURL == nil)
        #expect(session.wasCancelled)
    }

    @Test func loginThatNeverCompletesTimesOut() async {
        let environment = FakeSignInEnvironment(probeResults: [.signedOut])
        let session = environment.loginSession!
        let coordinator = makeCoordinator(environment)

        await coordinator.run(.claudeCode)

        #expect(coordinator.phase == .failed(
            message: "The Claude sign-in timed out. Try again when you're ready."
        ))
        // loginTimeout 10 / pollInterval 1.
        #expect(environment.pauseCount == 10)
        #expect(session.wasCancelled)
    }

    @Test func browserFallbackLinkIsPublishedOnceTheCLIPrintsIt() async {
        let environment = FakeSignInEnvironment(probeResults: [.signedOut, .signedOut, .signedOut, .claudeMax])
        let session = environment.loginSession!
        let link = URL(string: "https://auth.openai.com/oauth/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback")!
        var linkSeenWhileWaiting: URL?
        environment.onPoll = { poll in
            if poll == 1 { session.signInPageURL = link }
        }
        let coordinator = makeCoordinator(environment)
        let token = coordinator.$signInPageURL.sink { url in
            if url != nil { linkSeenWhileWaiting = url }
        }

        await coordinator.run(.codex)

        #expect(linkSeenWhileWaiting == link)
        // Cleared once signed in: there is nothing left to open.
        #expect(coordinator.signInPageURL == nil)
        _ = token
    }

    @Test func indeterminateProbeDoesNotBlockTheUser() async {
        let environment = FakeSignInEnvironment(probeResults: [.indeterminate()])
        let coordinator = makeCoordinator(environment)

        await coordinator.run(.claudeCode)

        #expect(coordinator.phase == .ready(detail: "Claude Code is installed"))
        #expect(environment.browserLoginCount == 0)
    }

    @Test func cancelReturnsToIdleAndForgetsTheExecutor() async {
        let environment = FakeSignInEnvironment(probeResults: [.claudeMax])
        let coordinator = makeCoordinator(environment)
        await coordinator.run(.claudeCode)

        coordinator.cancel()

        #expect(coordinator.phase == .idle)
        #expect(coordinator.executor == nil)
    }

    @Test func existingSignInIsAdoptedForPreselection() async {
        let environment = FakeSignInEnvironment(probeResults: [.signedOut, .ready(detail: "Codex · ChatGPT subscription")])
        let coordinator = makeCoordinator(environment)

        let adopted = await coordinator.adoptExistingSignIn(among: [.claudeCode, .codex])

        #expect(adopted == .codex)
        #expect(coordinator.executor == .codex)
        #expect(coordinator.phase == .ready(detail: "Codex · ChatGPT subscription"))
        #expect(environment.installCount == 0)
        #expect(environment.browserLoginCount == 0)
    }

    @Test func nothingSignedInAdoptsNothing() async {
        let environment = FakeSignInEnvironment(probeResults: [.notInstalled])
        let coordinator = makeCoordinator(environment)

        let adopted = await coordinator.adoptExistingSignIn(among: [.claudeCode, .codex])

        #expect(adopted == nil)
        #expect(coordinator.phase == .idle)
        #expect(coordinator.executor == nil)
    }

    @Test func aFailedQuestionAsksForSignInAndResetsAStaleCheck() async {
        let environment = FakeSignInEnvironment(probeResults: [.claudeMax])
        let coordinator = makeCoordinator(environment)
        await coordinator.run(.claudeCode)
        #expect(coordinator.phase.isReady)

        coordinator.noteSignInNeeded(for: .claudeCode)

        #expect(coordinator.attentionExecutor == .claudeCode)
        #expect(coordinator.phase == .idle)

        // OpenCode has no subscription sign-in to offer.
        coordinator.dismissAttention()
        coordinator.noteSignInNeeded(for: .openCode)
        #expect(coordinator.attentionExecutor == nil)
    }

    @Test func theSettingsNotificationStartsASignIn() async throws {
        let environment = FakeSignInEnvironment(probeResults: [.claudeMax])
        let center = NotificationCenter()
        let coordinator = makeCoordinator(environment, notificationCenter: center)

        center.post(
            name: Notification.Name("heyMateBeginSubscriptionSignIn"),
            object: nil,
            userInfo: ["executor": HeadlessExecutor.claudeCode.rawValue]
        )

        for _ in 0..<100 where !coordinator.phase.isReady {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.executor == .claudeCode)
        #expect(coordinator.phase.isReady)
    }

    // MARK: Commands and copy

    @Test func installersAreTheVendorsOfficialScripts() {
        #expect(SubscriptionCLIInstaller.installShellCommand(for: .claudeCode)
            == "set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash")
        #expect(SubscriptionCLIInstaller.installShellCommand(for: .codex)
            == "set -o pipefail; curl -fsSL https://chatgpt.com/codex/install.sh | sh")
        #expect(SubscriptionCLIInstaller.environmentOverrides(for: .codex)["CODEX_NON_INTERACTIVE"] == "1")
        #expect(SubscriptionCLIInstaller.installShellCommand(for: .openCode) == nil)
    }

    @Test func loginsAreTheSubscriptionBrowserFlows() {
        #expect(SubscriptionCLILogin.arguments(for: .claudeCode) == ["auth", "login", "--claudeai"])
        #expect(SubscriptionCLILogin.arguments(for: .claudeCode)?.contains("--console") == false)
        #expect(SubscriptionCLILogin.arguments(for: .codex) == ["login"])
    }

    @Test func onlyALinkThatCallsBackToThisMacIsOffered() {
        let codexOutput = """
        Starting local login server on http://localhost:1455.
        If your browser did not open, navigate to this URL to authenticate:

        https://auth.openai.com/oauth/authorize?response_type=code&redirect_uri=http%3A%2F%2F127.0.0.1%3A1455%2Fauth%2Fcallback&state=abc

        On a remote or headless machine? Use `codex login --device-auth` instead.
        """
        #expect(SubscriptionCLILogin.browserCompletableURL(in: codexOutput)?.host == "auth.openai.com")

        // Claude's printed link is the paste-a-code flow; it would strand
        // the user on a code with nowhere to put it.
        let claudeOutput = """
        Opening browser to sign in…
        If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&state=x
        Paste code here if prompted >
        """
        #expect(SubscriptionCLILogin.browserCompletableURL(in: claudeOutput) == nil)
    }

    @Test func terminalFallbackRunsOnlyTheLoginWithAbsolutePathAndNoAPIKeys() throws {
        let script = try #require(SubscriptionCLILogin.terminalScript(
            executablePath: "/Users/someone/.local/bin/claude",
            executor: .claudeCode
        ))
        #expect(script.hasPrefix("#!/bin/bash"))
        #expect(script.contains("'/Users/someone/.local/bin/claude' auth login --claudeai"))
        #expect(script.contains("unset "))
        #expect(script.contains("ANTHROPIC_API_KEY"))
        #expect(script.contains("OPENAI_API_KEY"))
    }

    @Test func shellQuotingSurvivesAnApostropheInThePath() {
        #expect(SubscriptionCLILogin.shellQuoted("/Users/o'neil/bin/codex") == #"'/Users/o'\''neil/bin/codex'"#)
    }

    @Test func statusLinesArePlainEnglish() {
        #expect(SubscriptionSignInCopy.statusLine(for: .installing, executor: .claudeCode)
            == "Installing Claude Code. This takes about a minute…")
        #expect(SubscriptionSignInCopy.statusLine(for: .waitingForBrowser, executor: .codex)
            == "Finish signing in to ChatGPT in your browser.")
        #expect(SubscriptionSignInCopy.signInActionTitle(for: .claudeCode) == "Sign in to Claude")
    }

    @Test func remediesNeverSendAnyoneToPATHOrTerminal() {
        for executor in HeadlessExecutor.allCases {
            for remedy in [
                SubscriptionSignInCopy.signInRemedy(for: executor),
                SubscriptionSignInCopy.notInstalledRemedy(for: executor),
                SubscriptionSignInCopy.signInNeededMessage(for: executor)
            ] {
                #expect(!remedy.contains("PATH"))
                #expect(!remedy.contains("Terminal"))
                #expect(!remedy.contains("`"))
            }
        }
        #expect(SubscriptionSignInCopy.signInRemedy(for: .claudeCode) == "Sign in to Claude from Settings → AI & Accounts.")
    }

    @Test func notInstalledTalkErrorStillOffersTheSignIn() {
        let message = SubscriptionSignInCopy.notInstalledRemedy(for: .claudeCode)
        #expect(SpokenFailure.classify(message: message) == .signedOut)
    }

    @Test func codexSignedOutRemedyPointsAtAccounts() {
        let readiness = HeadlessExecutorReadinessProbe.codexReadiness(from: "Not logged in", exitStatus: 1)
        #expect(readiness.state == .notSignedIn)
        #expect(readiness.remedy.contains("Settings → AI & Accounts"))
        #expect(!readiness.remedy.contains("codex login"))
    }

    @Test func onboardingChoicesMapToBrains() {
        #expect(OnboardingAIChoice.claude.brain == .claudeCode)
        #expect(OnboardingAIChoice.chatGPT.brain == .codex)
        #expect(OnboardingAIChoice.neither.brain == .onDevice)
        #expect(OnboardingAIChoice.neither.executor == nil)
        #expect(OnboardingAIChoice(executor: .codex) == .chatGPT)
        #expect(OnboardingAIChoice(executor: .openCode) == nil)
    }
}
