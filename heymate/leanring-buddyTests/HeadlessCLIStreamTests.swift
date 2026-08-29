//
//  HeadlessCLIStreamTests.swift
//  leanring-buddyTests
//

import Darwin
import Foundation
import Testing
@testable import HeyMate

struct HeadlessCLILineAccumulatorTests {

    private func chunk(_ text: String) -> Data { Data(text.utf8) }

    @Test func completeLinesAreDeliveredImmediately() {
        let accumulator = HeadlessCLILineAccumulator()
        let lines = accumulator.completeLines(from: chunk("{\"a\":1}\n{\"b\":2}\n"))
        #expect(lines == ["{\"a\":1}", "{\"b\":2}"])
    }

    /// The bug this class exists for: a JSON line split across two pipe reads
    /// used to arrive as two invalid fragments, and every agent event inside it
    /// was dropped.
    @Test func lineSplitAcrossReadsIsRejoinedNotDropped() {
        let accumulator = HeadlessCLILineAccumulator()

        let firstRead = accumulator.completeLines(from: chunk("{\"type\":\"tool_use\",\"na"))
        #expect(firstRead.isEmpty)

        let secondRead = accumulator.completeLines(from: chunk("me\":\"write\"}\n"))
        #expect(secondRead == ["{\"type\":\"tool_use\",\"name\":\"write\"}"])
    }

    @Test func partialLineIsHeldUntilItsNewlineArrives() {
        let accumulator = HeadlessCLILineAccumulator()
        #expect(accumulator.completeLines(from: chunk("first\nsecond-half")) == ["first"])
        #expect(accumulator.completeLines(from: chunk("-of-second\nthird\n")) == ["second-half-of-second", "third"])
    }

    /// A multi-byte character straddling a chunk boundary used to make the
    /// whole chunk fail to decode, not just the one character.
    @Test func multiByteCharacterSplitAcrossReadsSurvives() {
        let accumulator = HeadlessCLILineAccumulator()
        let emojiBytes = Array("✅".utf8)

        #expect(accumulator.completeLines(from: Data([UInt8(ascii: "x")] + emojiBytes.prefix(1))).isEmpty)
        let completed = accumulator.completeLines(
            from: Data(emojiBytes.dropFirst() + [UInt8(ascii: "\n")])
        )
        #expect(completed == ["x✅"])
    }

    @Test func flushDeliversAFinalLineWithoutATrailingNewline() {
        let accumulator = HeadlessCLILineAccumulator()
        #expect(accumulator.completeLines(from: chunk("done")).isEmpty)
        #expect(accumulator.flushRemainder() == ["done"])
        #expect(accumulator.flushRemainder().isEmpty)
    }

    @Test func blankLinesAreNotDelivered() {
        let accumulator = HeadlessCLILineAccumulator()
        #expect(accumulator.completeLines(from: chunk("\n\nreal\n\n")) == ["real"])
    }

    @Test func carriageReturnsAreTrimmed() {
        let accumulator = HeadlessCLILineAccumulator()
        #expect(accumulator.completeLines(from: chunk("value\r\n")) == ["value"])
    }
}

struct HeadlessCLIStandardErrorTailTests {

    @Test func recentLinesReturnsTheNewestLinesOldestFirst() {
        let tail = HeadlessCLIStandardErrorTail()
        tail.append(Data("one\ntwo\nthree\nfour\n".utf8))
        #expect(tail.recentLines(limit: 2) == ["three", "four"])
    }

    @Test func emptyStandardErrorProducesNoLines() {
        let tail = HeadlessCLIStandardErrorTail()
        #expect(tail.recentLines(limit: 6).isEmpty)
    }

    @Test func retainedBytesAreBounded() {
        let tail = HeadlessCLIStandardErrorTail()
        for index in 0..<4000 {
            tail.append(Data("line \(index)\n".utf8))
        }
        let lines = tail.recentLines(limit: 3)
        #expect(lines.count == 3)
        #expect(lines.last == "line 3999")
    }
}

struct HeadlessCLIOutputDeliveryBufferTests {
    @Test func oneDrainServesManyEnqueuesInBoundedBatches() {
        let buffer = HeadlessCLIOutputDeliveryBuffer()
        #expect(buffer.enqueue(["first"]))
        #expect(!buffer.enqueue(["second", "third"]))

        guard case .lines(let lines) = buffer.nextBatch() else {
            Issue.record("Expected queued lines")
            return
        }
        #expect(lines == ["first", "second", "third"])
        guard case .finished = buffer.nextBatch() else {
            Issue.record("Expected finished drain")
            return
        }
        #expect(buffer.enqueue(["later"]))
    }

    @Test func overflowIsTerminalAndDoesNotGrowAnotherQueue() {
        let buffer = HeadlessCLIOutputDeliveryBuffer()
        #expect(buffer.enqueue([String(repeating: "x", count: 2 * 1_024 * 1_024 + 1)]))
        guard case .overflow = buffer.nextBatch() else {
            Issue.record("Expected bounded overflow")
            return
        }
        #expect(!buffer.enqueue(["ignored-after-overflow"]))
        guard case .finished = buffer.nextBatch() else {
            Issue.record("Expected empty queue after overflow")
            return
        }
    }
}

@MainActor
struct HeadlessCLIProcessTreeTests {

    @Test func spawnPreservesDuplexIOEnvironmentDirectoryAndExitStatus() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeadlessCLIProcessIOTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let process = HeadlessCLIProcess()
        var outputLines: [String] = []
        var exitStatus: Int32?
        try process.start(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "IFS= read -r input; printf '%s|%s|%s' \"$PWD\" \"$HEYMATE_PROCESS_TEST\" \"$input\"; printf 'diagnostic\\n' >&2; exit 7"
            ],
            currentDirectoryURL: directoryURL,
            environmentOverrides: ["HEYMATE_PROCESS_TEST": "scoped"],
            usesDuplexStandardInput: true,
            onLine: { outputLines.append($0) },
            onExit: { exitStatus = $0 }
        )
        defer { process.terminateThenKill() }

        process.writeToStandardInput(Data("hello".utf8))

        // A terminal callback waits for the complete process group. Under the
        // full parallel suite, MainActor scheduling can consume most of the
        // four-second production cleanup window before this test resumes.
        let exited = await waitUntil(timeout: 6) { exitStatus != nil }
        #expect(exited)
        #expect(exitStatus == 7)
        let output = try #require(outputLines.first)
        let outputComponents = output.split(separator: "|", omittingEmptySubsequences: false)
        #expect(outputLines.count == 1)
        try #require(outputComponents.count == 3)
        #expect(
            URL(fileURLWithPath: String(outputComponents[0])).lastPathComponent
                == directoryURL.lastPathComponent
        )
        #expect(String(outputComponents[1]) == "scoped")
        #expect(String(outputComponents[2]) == "hello")
        #expect(process.recentStandardErrorSummary == "diagnostic")
    }

    @Test func cancellationTerminatesChildAndGrandchild() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HeadlessCLIProcessTreeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let rootScriptURL = directoryURL.appendingPathComponent("root.sh")
        let childScriptURL = directoryURL.appendingPathComponent("child.sh")
        let grandchildScriptURL = directoryURL.appendingPathComponent("grandchild.sh")
        let childPIDURL = directoryURL.appendingPathComponent("child.pid")
        let grandchildPIDURL = directoryURL.appendingPathComponent("grandchild.pid")

        try """
        #!/bin/sh
        trap '' TERM
        /bin/sh "$3" "$1" "$2" "$4" &
        wait
        """.write(to: rootScriptURL, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        trap '' TERM
        printf '%s\\n' "$$" > "$1"
        /bin/sh "$3" "$2" &
        wait
        """.write(to: childScriptURL, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        trap '' TERM
        printf '%s\\n' "$$" > "$1"
        while :; do sleep 30; done
        """.write(to: grandchildScriptURL, atomically: true, encoding: .utf8)

        let process = HeadlessCLIProcess()
        var didExit = false
        try process.start(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                rootScriptURL.path,
                childPIDURL.path,
                grandchildPIDURL.path,
                childScriptURL.path,
                grandchildScriptURL.path
            ],
            currentDirectoryURL: directoryURL,
            onLine: { _ in },
            onExit: { _ in didExit = true }
        )
        defer { process.terminateThenKill() }

        let rootPID = process.processIdentifier
        let childPID = try await processIdentifier(writtenTo: childPIDURL)
        let grandchildPID = try await processIdentifier(writtenTo: grandchildPIDURL)

        #expect(rootPID > 1)
        #expect(getpgid(rootPID) == rootPID)
        #expect(getpgid(childPID) == rootPID)
        #expect(getpgid(grandchildPID) == rootPID)

        let stopped = await process.terminateAndWait()

        let treeExited = await waitUntil(timeout: 4) {
            didExit
                && !Self.processExists(childPID)
                && !Self.processExists(grandchildPID)
        }
        #expect(stopped)
        #expect(treeExited)
    }

    @Test func terminalCallbackWaitsForDescendantProcessGroupCleanup() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HeadlessCLIProcessTerminalCleanupTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let leaderScriptURL = directoryURL.appendingPathComponent("leader.sh")
        let descendantScriptURL = directoryURL.appendingPathComponent("descendant.sh")
        let descendantPIDURL = directoryURL.appendingPathComponent("descendant.pid")
        try """
        #!/bin/sh
        trap '' TERM
        printf '%s\\n' "$$" > "$1"
        while :; do /bin/sleep 30; done
        """.write(to: descendantScriptURL, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        /bin/sh "$2" "$1" &
        while [ ! -s "$1" ]; do /bin/sleep 0.01; done
        exit 0
        """.write(to: leaderScriptURL, atomically: true, encoding: .utf8)

        let process = HeadlessCLIProcess()
        var leaderPID: pid_t = 0
        var exitStatus: Int32?
        var descendantExistedAtCallback: Bool?
        var groupExistedAtCallback: Bool?
        try process.start(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                leaderScriptURL.path,
                descendantPIDURL.path,
                descendantScriptURL.path
            ],
            currentDirectoryURL: directoryURL,
            onLine: { _ in },
            onExit: { status in
                exitStatus = status
                let descendantPID = try? String(
                    contentsOf: descendantPIDURL,
                    encoding: .utf8
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
                descendantExistedAtCallback = descendantPID
                    .flatMap { pid_t($0) }
                    .map(Self.processExists)
                    ?? true
                groupExistedAtCallback = Self.processGroupExists(leaderPID)
            }
        )
        leaderPID = process.processIdentifier
        let descendantPID = try await processIdentifier(writtenTo: descendantPIDURL)
        defer {
            process.terminateThenKill()
            if Self.processExists(descendantPID) { Darwin.kill(descendantPID, SIGKILL) }
        }

        #expect(getpgid(descendantPID) == leaderPID)
        let terminalCallbackArrived = await waitUntil(timeout: 6) { exitStatus != nil }
        #expect(terminalCallbackArrived)
        #expect(exitStatus == 0)
        #expect(descendantExistedAtCallback == false)
        #expect(groupExistedAtCallback == false)
        #expect(!Self.processExists(descendantPID))

        // Re-entering stop after terminal state must return without targeting
        // the stale positive leader PID or waiting a full kill deadline.
        let clock = ContinuousClock()
        let startedAt = clock.now
        let stoppedAgain = await process.terminateAndWait()
        #expect(stoppedAgain)
        #expect(startedAt.duration(to: clock.now) < .seconds(1))
    }

    private func processIdentifier(writtenTo fileURL: URL) async throws -> pid_t {
        let found = await waitUntil(timeout: 3) {
            FileManager.default.fileExists(atPath: fileURL.path)
        }
        guard found else { throw ProcessTreeTestError.pidFileTimedOut }

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let processID = pid_t(contents), processID > 1 else {
            throw ProcessTreeTestError.invalidProcessIdentifier
        }
        return processID
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return condition()
    }

    nonisolated private static func processExists(_ processID: pid_t) -> Bool {
        kill(processID, 0) == 0 || errno == EPERM
    }

    nonisolated private static func processGroupExists(_ processGroupID: pid_t) -> Bool {
        guard processGroupID > 1 else { return false }
        return kill(-processGroupID, 0) == 0 || errno == EPERM
    }

    private enum ProcessTreeTestError: Error {
        case pidFileTimedOut
        case invalidProcessIdentifier
    }
}

struct HeadlessExecutorPolicyTests {

    /// Claude Code runs on the subscription sign-in, so a provider key leaking
    /// in from the secrets file would silently move billing to the API.
    @Test func claudeCodeStripsProviderKeys() {
        #expect(HeadlessExecutor.claudeCode.usesSubscriptionSignIn)
        #expect(HeadlessExecutor.claudeCode.environmentKeysToRemove.contains("ANTHROPIC_API_KEY"))
        #expect(HeadlessExecutor.claudeCode.environmentKeysToRemove.contains("ANTHROPIC_BASE_URL"))
    }

    @Test func codexStripsProviderKeys() {
        #expect(HeadlessExecutor.codex.usesSubscriptionSignIn)
        #expect(HeadlessExecutor.codex.environmentKeysToRemove.contains("OPENAI_API_KEY"))
        #expect(HeadlessExecutor.codex.environmentKeysToRemove.contains("ANTHROPIC_API_KEY"))
        #expect(HeadlessExecutor.codex.executableName == "codex")
    }

    /// OpenCode may inherit provider credentials, but app-only credentials
    /// still stay outside its agent-controlled shell.
    @Test func openCodeStripsAppOnlySecrets() {
        #expect(HeadlessExecutor.openCode.usesSubscriptionSignIn == false)
        #expect(HeadlessExecutor.openCode.environmentKeysToRemove.contains("HEYMATE_CLIENT_TOKEN"))
        #expect(HeadlessExecutor.openCode.environmentKeysToRemove.contains("ELEVENLABS_API_KEY"))
        #expect(HeadlessExecutor.openCode.environmentKeysToRemove.contains("OPENCODE_CONFIG"))
        #expect(HeadlessExecutor.openCode.environmentKeysToRemove.contains("OPENCODE_CONFIG_CONTENT"))
        #expect(HeadlessExecutor.openCode.environmentKeysToRemove.contains("OPENCODE_PERMISSION"))
        #expect(HeadlessExecutor.openCode.environmentKeysToRemove.contains("OPENCODE_TEST_HOME"))
        #expect(HeadlessExecutor.openCode.environmentKeysToRemove.contains("OPENCODE_TEST_MANAGED_CONFIG_DIR"))
        #expect(HeadlessExecutor.openCode.environmentKeysToRemove.contains("OPENAI_API_KEY") == false)
    }

    @Test func strippedKeysAreAbsentFromTheChildEnvironment() {
        let environment = HeadlessChildEnvironment.build(
            stripping: ["ANTHROPIC_API_KEY", "HEYMATE_CLIENT_TOKEN"],
            overrides: ["HEYMATE_BRIDGE_URL": "http://127.0.0.1:18732"],
            processEnvironment: [
                "PATH": "/usr/bin",
                "ANTHROPIC_API_KEY": "provider-secret",
                "HEYMATE_CLIENT_TOKEN": "worker-secret"
            ]
        )
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["HEYMATE_CLIENT_TOKEN"] == nil)
        #expect(environment["HEYMATE_BRIDGE_URL"] == "http://127.0.0.1:18732")
        #expect(environment["TERM"] == "dumb")
        #expect(environment["PATH"]?.isEmpty == false)
    }

    @Test func trustedLegOverrideCanReintroduceScopedBridgeToken() {
        let environment = HeadlessChildEnvironment.build(
            stripping: ["HEYMATE_BRIDGE_TOKEN"],
            overrides: ["HEYMATE_BRIDGE_TOKEN": "scoped-token"],
            processEnvironment: ["HEYMATE_BRIDGE_TOKEN": "inherited-token"]
        )
        #expect(environment["HEYMATE_BRIDGE_TOKEN"] == "scoped-token")
    }

    @Test func everyExecutorStripsWorkerAndVoiceSecrets() {
        for executor in HeadlessExecutor.allCases {
            #expect(executor.environmentKeysToRemove.contains("HEYMATE_CLIENT_TOKEN"))
            #expect(executor.environmentKeysToRemove.contains("ASSEMBLYAI_API_KEY"))
            #expect(executor.environmentKeysToRemove.contains("ELEVENLABS_API_KEY"))
            #expect(executor.environmentKeysToRemove.contains("HEYMATE_BRIDGE_TOKEN"))
            #expect(executor.environmentKeysToRemove.contains("HEYMATE_SECRETS_FILE"))
            #expect(executor.environmentKeysToRemove.contains("COMPOSIO_API_KEY"))
        }
    }
}

struct HeadlessCLILaunchSpecTests {

    private let workspaceURL = URL(fileURLWithPath: "/tmp/heymate-spec-test", isDirectory: true)

    private func openCodeSpec(model: String?) -> HeadlessCLILaunchSpec {
        HeadlessCLIAdapterFactory.adapter(for: .openCode, openCodeModelIdentifier: model).launchSpec(
            workspaceURL: workspaceURL,
            leg: .plan(prompt: "build a landing page"),
            origin: .sandbox,
            title: "build a landing page",
            sessionIdentifier: ""
        )
    }

    /// Without an explicit model, `opencode run` falls back to its own default
    /// rather than the model showing in Settings.
    @Test func openCodePassesTheSelectedModel() {
        let arguments = openCodeSpec(model: "anthropic/claude-sonnet-4-6").arguments
        #expect(arguments.contains("--pure"))
        #expect(arguments.contains("--model"))
        #expect(arguments.contains("anthropic/claude-sonnet-4-6"))
    }

    @Test func openCodeOmitsTheModelFlagWhenNoneIsSelected() {
        #expect(openCodeSpec(model: nil).arguments.contains("--model") == false)
    }

    @Test func claudeCodeCarriesItsStrippedKeysOnTheSpec() {
        let spec = HeadlessCLIAdapterFactory.adapter(
            for: .claudeCode,
            claudeModelIdentifier: "sonnet"
        ).launchSpec(
            workspaceURL: workspaceURL,
            leg: .plan(prompt: "build a landing page"),
            origin: .sandbox,
            title: "build a landing page",
            sessionIdentifier: "4662b1f8-8da1-4865-a3a2-ecd91d20cbb0"
        )
        #expect(spec.environmentKeysToRemove.contains("ANTHROPIC_API_KEY"))
        #expect(spec.arguments.contains("stream-json"))
        #expect(spec.arguments.contains("--model"))
        #expect(spec.arguments.contains("sonnet"))
    }
}

struct HeadlessExecutorReadinessTests {

    /// Codex 0.149.1 writes a successful `login status` message to stderr and
    /// leaves stdout empty. Exercise the real process-capture path so a future
    /// refactor cannot silently turn a signed-in CLI back into "Installed".
    @Test func codexLoginStatusEmittedOnlyOnStandardErrorIsReady() throws {
        let executableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-codex-status-\(UUID().uuidString)")
        let script = """
        #!/bin/sh
        if [ -n "${HEYMATE_CLIENT_TOKEN:-}" ]; then
          printf 'Worker token leaked to probe\\n' >&2
          exit 9
        fi
        printf 'Logged in using ChatGPT\\n' >&2
        """

        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        defer { try? FileManager.default.removeItem(at: executableURL) }

        let readiness = HeadlessExecutorReadinessProbe.probeCodex(
            executableURL: executableURL,
            processEnvironment: ["HEYMATE_CLIENT_TOKEN": "must-not-reach-child"]
        )

        #expect(readiness.state == .ready)
        #expect(readiness.detail == "Codex · ChatGPT subscription")
        #expect(readiness.allowsLaunch)
    }

    @Test func codexPersistedMeteredCredentialsNeverMasqueradeAsChatGPT() {
        let statuses = [
            "Logged in using an API key - sk-redacted",
            "Logged in using access token",
            "Logged in using personal access token",
            "Logged in using Bedrock API key"
        ]

        for status in statuses {
            let readiness = HeadlessExecutorReadinessProbe.codexReadiness(
                from: status,
                exitStatus: 0
            )
            #expect(readiness.state == .usingAPIKey)
            #expect(readiness.detail == "Codex · non-ChatGPT credential")
            #expect(readiness.remedy.contains("may bill"))
        }

        let subscription = HeadlessExecutorReadinessProbe.codexReadiness(
            from: "Logged in using ChatGPT",
            exitStatus: 0
        )
        #expect(subscription.state == .ready)
    }

    @Test func onlyDefiniteNegativesBlockALaunch() {
        #expect(HeadlessExecutorReadiness.ready(detail: "Claude Pro").allowsLaunch)
        #expect(HeadlessExecutorReadiness.indeterminate().allowsLaunch)
        #expect(
            HeadlessExecutorReadiness(state: .usingAPIKey, detail: "", remedy: "").allowsLaunch
        )
        #expect(
            HeadlessExecutorReadiness(state: .notSignedIn, detail: "", remedy: "").allowsLaunch == false
        )
        #expect(
            HeadlessExecutorReadiness(state: .notInstalled, detail: "", remedy: "").allowsLaunch == false
        )
    }
}
