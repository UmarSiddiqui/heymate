import Foundation
import Testing
@testable import HeyMate

@MainActor
struct MateAgentSubscriptionLoginTests {
    @Test func claudeAuthorizationDisplaysOfficialPageAndPollsOwnProvider() async throws {
        var paths: [String] = []
        let login = MateAgentSubscriptionLoginController(prepare: { _ in }, request: { path, method, _ in
            paths.append(path)
            if method == "POST" {
                return .object(["session_id": .string("claude-flow"), "flow": .string("authorization_code"),
                    "verification_url": .string("https://claude.ai/oauth/authorize?state=fixture"),
                    "expires_in": .number(900), "poll_interval": .number(3)])
            }
            return .object(["session_id": .string("claude-flow"), "status": .string("approved")])
        }, sleep: { _ in await Task.yield() })
        await login.start(configuration, provider: "anthropic")
        #expect(login.verificationURL?.host == "claude.ai")
        #expect(login.userCode == nil)
        try await waitUntil { login.state == .connected }
        #expect(paths == ["/api/providers/oauth/anthropic/start", "/api/providers/oauth/anthropic/poll/claude-flow"])
        #expect(MateAgentSubscriptionLoginController.officialURL("https://claude.ai.evil.example/oauth/authorize?state=x") == nil)
        #expect(MateAgentSubscriptionLoginController.officialURL("https://claude.ai/oauth/authorize/other?state=x") == nil)
    }

    private let configuration = MateAgentEngineConfiguration(executablePath: "/bin/sh", profilePath: "/tmp")
    private static let started: JSONValue = .object([
        "session_id": .string("safe_flow-123"), "flow": .string("device_code"), "user_code": .string("ABCD-EFGH"),
        "verification_url": .string("https://auth.openai.com/codex/device"),
        "expires_in": .number(900), "poll_interval": .number(5)
    ])
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TestFailure.timedOut }
            try await ContinuousClock().sleep(for: .milliseconds(1))
        }
    }

    @Test func deviceSignInDisplaysCodeAndPollsWithoutOpeningBrowserOrSelectingModel() async throws {
        var requests: [(String, String, Duration)] = []
        var polls = 0
        let login = MateAgentSubscriptionLoginController(prepare: { _ in }, request: { path, method, timeout in
            requests.append((path, method, timeout))
            if method == "POST" { return Self.started }
            polls += 1
            return .object(["session_id": .string("safe_flow-123"), "status": .string(polls == 1 ? "pending" : "approved"),
                            "token_preview": .string("must-never-display")])
        }, sleep: { _ in await Task.yield() })
        await login.start(configuration)
        #expect(login.state == .awaitingApproval)
        #expect(login.busy)
        #expect(login.userCode == "ABCD-EFGH")
        #expect(login.verificationURL?.absoluteString == "https://auth.openai.com/codex/device")
        try await waitUntil { login.state == .connected }
        #expect(!login.busy)
        #expect(login.userCode == nil && login.verificationURL == nil)
        #expect(requests[0].2 == .seconds(20))
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { !$0.0.contains("model") })
        #expect(!login.status.contains("must-never-display"))
    }

    @Test func cancelRemovesOnlyItsServerFlowAndStopsPolling() async throws {
        var requests: [(String, String)] = []
        let login = MateAgentSubscriptionLoginController(prepare: { _ in }, request: { path, method, _ in
            requests.append((path, method))
            return method == "POST" ? Self.started : .object(["ok": .bool(true)])
        }, sleep: { _ in try await ContinuousClock().sleep(for: .seconds(100)) })
        await login.start(configuration)
        #expect(login.busy)
        await login.cancel()
        #expect(!login.busy && login.state == .cancelled)
        #expect(requests.map(\.1) == ["POST", "DELETE"])
        #expect(requests.last?.0 == "/api/providers/oauth/sessions/safe_flow-123")
        #expect(login.userCode == nil)
    }

    @Test func closingDuringStartCancelsLateAcknowledgedFlow() async throws {
        var pending: CheckedContinuation<JSONValue, Error>?
        var deleted: [String] = []
        let login = MateAgentSubscriptionLoginController(prepare: { _ in }, request: { path, method, _ in
            if method == "POST" {
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
            deleted.append(path); return .object(["ok": .bool(true)])
        })
        let start = Task { await login.start(configuration) }
        try await waitUntil { pending != nil }
        await login.cancel()
        pending?.resume(returning: Self.started)
        await start.value
        #expect(login.state == .cancelled)
        #expect(deleted == ["/api/providers/oauth/sessions/safe_flow-123"])
        #expect(login.userCode == nil)
    }

    @Test func cancelledPollCannotReportAStaleApproval() async throws {
        var poll: CheckedContinuation<JSONValue, Error>?
        let login = MateAgentSubscriptionLoginController(prepare: { _ in }, request: { _, method, _ in
            if method == "POST" { return Self.started }
            if method == "DELETE" { return .object(["ok": .bool(true)]) }
            return try await withCheckedThrowingContinuation { poll = $0 }
        }, sleep: { _ in await Task.yield() })
        await login.start(configuration)
        try await waitUntil { poll != nil }
        await login.cancel()
        poll?.resume(returning: .object(["session_id": .string("safe_flow-123"), "status": .string("approved")]))
        await Task.yield()
        #expect(login.state == .cancelled)
        #expect(!login.busy)
    }

    @Test(arguments: ["https://evil.example/codex/device", "http://auth.openai.com/codex/device", "https://auth.openai.com/codex/device?token=private", "https://auth.openai.com@evil.example/codex/device", "https://auth.openai.com:443/codex/device"])
    func onlyOfficialDeviceURLCanBeOffered(address: String) {
        #expect(MateAgentSubscriptionLoginController.officialURL(address) == nil)
    }

    @Test func malformedFlowCannotBecomeAPathOrDisplayServerSecrets() async {
        var paths: [String] = []
        let login = MateAgentSubscriptionLoginController(prepare: { _ in }, request: { path, _, _ in
            paths.append(path)
            return .object(["session_id": .string("../../private?token=secret"), "error_message": .string("private-account-token")])
        })
        await login.start(configuration)
        #expect(login.state == .failed && !login.busy)
        #expect(paths == ["/api/providers/oauth/openai-codex/start"])
        #expect(!login.status.contains("private-account-token"))
    }

    @Test(arguments: ["expired", "denied", "error", "unexpected"])
    func terminalFailuresAreBoundedAndDoNotEchoProviderDetails(status: String) async throws {
        let login = MateAgentSubscriptionLoginController(prepare: { _ in }, request: { _, method, _ in
            if method == "POST" { return Self.started }
            if method == "DELETE" { return .object(["ok": .bool(true)]) }
            return .object(["session_id": .string("safe_flow-123"), "status": .string(status), "error_message": .string("private-fixture-token")])
        }, sleep: { _ in await Task.yield() })
        await login.start(configuration)
        try await waitUntil { !login.busy }
        #expect(login.state != .connected)
        #expect(!login.status.contains("private-fixture-token"))
        #expect(login.userCode == nil)
    }
    private enum TestFailure: Error { case timedOut }
}
