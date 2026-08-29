//
//  DetachedAgentRunnerEngineTests.swift
//  leanring-buddyTests
//

import Darwin
import Foundation
import Testing
@testable import HeyMate

@MainActor
struct DetachedAgentRunnerEngineTests {

    @Test func successfulRunWritesTerminalStateAndJournal() async throws {
        let fixture = try makeFixtureDirectory(named: "success")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let runtimeRoot = fixture.appendingPathComponent("runtime", isDirectory: true)
        let scriptURL = try makeExecutableScript(
            in: fixture,
            named: "success.sh",
            contents: """
            #!/bin/sh
            printf '%s\n' '{"type":"item.completed","item":{"type":"file_change","status":"completed"}}'
            printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Built fixture"}}'
            exit 0
            """
        )
        let request = makeRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [scriptURL.path],
            workspaceURL: fixture,
            runtimeLimit: 5
        )
        var wakeCount = 0
        let engine = try DetachedAgentRunnerEngine(
            request: request,
            rootDirectoryURL: runtimeRoot,
            exitProcess: { _ in },
            wakeMainApp: { wakeCount += 1 }
        )

        engine.start()

        let reachedTerminalState = await waitUntil(timeout: 5) {
            (try? Self.loadState(root: runtimeRoot, request: request))?.phase.isTerminal == true
        }
        #expect(reachedTerminalState)
        let state = try #require(try Self.loadState(root: runtimeRoot, request: request))
        #expect(state.phase == .succeeded)
        #expect(state.exitCode == 0)
        #expect(state.terminalSafeSummary == "Work completed")
        #expect(state.lastJournalSequence > 0)

        let journal = try DetachedAgentRuntimeJournal.loadReadOnly(
            rootDirectoryURL: runtimeRoot,
            runID: request.runID,
            attemptID: request.attemptID
        )
        #expect(journal.first?.kind == .ready)
        #expect(journal.contains { $0.kind == .progress && $0.safeSummary == "tool" })
        #expect(journal.last?.kind == .finished)
        #expect(journal.last?.phase == .succeeded)
        #expect(wakeCount == 1)
    }

    @Test func bufferedFailureEventWinsOverZeroProcessExit() async throws {
        let fixture = try makeFixtureDirectory(named: "buffered-failure")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let runtimeRoot = fixture.appendingPathComponent("runtime", isDirectory: true)
        let scriptURL = try makeExecutableScript(
            in: fixture,
            named: "buffered-failure.sh",
            contents: """
            #!/bin/sh
            index=0
            while [ "$index" -lt 96 ]; do
              printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"queued"}}'
              index=$((index + 1))
            done
            printf '%s\n' '{"type":"error","message":"buffered failure"}'
            while [ "$index" -lt 160 ]; do
              printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"queued"}}'
              index=$((index + 1))
            done
            exit 0
            """
        )
        let request = makeRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [scriptURL.path],
            workspaceURL: fixture,
            runtimeLimit: 5
        )
        var wakeCount = 0
        let engine = try DetachedAgentRunnerEngine(
            request: request,
            rootDirectoryURL: runtimeRoot,
            exitProcess: { _ in },
            wakeMainApp: { wakeCount += 1 }
        )

        engine.start()

        let reachedTerminalState = await waitUntil(timeout: 5) {
            (try? Self.loadState(root: runtimeRoot, request: request))?.phase.isTerminal == true
        }
        #expect(reachedTerminalState)
        let state = try #require(try Self.loadState(root: runtimeRoot, request: request))
        #expect(state.phase == .failed)
        #expect(state.exitCode == 0)
        #expect(state.terminalSafeError == "Coding agent reported an error")
        #expect(wakeCount == 1)
    }

    @Test func cancelPublishesTerminalStateOnlyAfterChildAndGrandchildExit() async throws {
        let fixture = try makeFixtureDirectory(named: "cancel-tree")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let runtimeRoot = fixture.appendingPathComponent("runtime", isDirectory: true)
        let childPIDURL = fixture.appendingPathComponent("child.pid")
        let grandchildPIDURL = fixture.appendingPathComponent("grandchild.pid")
        let grandchildScriptURL = try makeExecutableScript(
            in: fixture,
            named: "grandchild.sh",
            contents: """
            #!/bin/sh
            trap '' TERM
            printf '%s\n' "$$" > "$1"
            while :; do /bin/sleep 30; done
            """
        )
        let childScriptURL = try makeExecutableScript(
            in: fixture,
            named: "child.sh",
            contents: """
            #!/bin/sh
            trap '' TERM
            printf '%s\n' "$$" > "$1"
            /bin/sh "$3" "$2" &
            wait
            """
        )
        let rootScriptURL = try makeExecutableScript(
            in: fixture,
            named: "root.sh",
            contents: """
            #!/bin/sh
            trap '' TERM
            /bin/sh "$3" "$1" "$2" "$4" &
            wait
            """
        )
        let request = makeRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                rootScriptURL.path,
                childPIDURL.path,
                grandchildPIDURL.path,
                childScriptURL.path,
                grandchildScriptURL.path
            ],
            workspaceURL: fixture,
            runtimeLimit: 30
        )
        var wakeCount = 0
        let engine = try DetachedAgentRunnerEngine(
            request: request,
            rootDirectoryURL: runtimeRoot,
            exitProcess: { _ in },
            wakeMainApp: { wakeCount += 1 }
        )
        engine.start()

        let childPID = try await processIdentifier(writtenTo: childPIDURL)
        let grandchildPID = try await processIdentifier(writtenTo: grandchildPIDURL)
        let runningState = try #require(try Self.loadState(root: runtimeRoot, request: request))
        #expect(runningState.phase == .running)

        let mailbox = try DetachedAgentCommandMailbox(
            rootDirectoryURL: runtimeRoot,
            runID: request.runID,
            attemptID: request.attemptID
        )
        try mailbox.enqueue(
            DetachedAgentCommandEnvelope(
                runID: request.runID,
                attemptID: request.attemptID,
                command: .cancel
            )
        )

        let reachedTerminalState = await waitUntil(timeout: 6) {
            (try? Self.loadState(root: runtimeRoot, request: request))?.phase.isTerminal == true
        }
        #expect(reachedTerminalState)
        let state = try #require(try Self.loadState(root: runtimeRoot, request: request))
        #expect(state.phase == .cancelled)
        #expect(!Self.processExists(childPID))
        #expect(!Self.processExists(grandchildPID))
        #expect(wakeCount == 0)
    }

    @Test func approvalWaitPersistsOpaqueTokenAndPausesWorkTimeout() async throws {
        let fixture = try makeFixtureDirectory(named: "approval")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let runtimeRoot = fixture.appendingPathComponent("runtime", isDirectory: true)
        let providerApprovalID = "provider-approval-must-not-persist"
        let scriptURL = try makeExecutableScript(
            in: fixture,
            named: "approval.sh",
            contents: """
            #!/bin/sh
            printf '%s\n' '{"type":"control_request","request_id":"\(providerApprovalID)","request":{"subtype":"can_use_tool","tool_name":"Bash"}}'
            while :; do /bin/sleep 30; done
            """
        )
        let request = makeRequest(
            executor: .claudeCode,
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [scriptURL.path],
            workspaceURL: fixture,
            usesDuplexStandardInput: true,
            runtimeLimit: 0.2
        )
        var wakeCount = 0
        let engine = try DetachedAgentRunnerEngine(
            request: request,
            rootDirectoryURL: runtimeRoot,
            exitProcess: { _ in },
            wakeMainApp: { wakeCount += 1 }
        )
        engine.start()

        let reachedApproval = await waitUntil(timeout: 3) {
            (try? Self.loadState(root: runtimeRoot, request: request))?.phase == .waitingForApproval
        }
        #expect(reachedApproval)
        #expect(wakeCount == 1)
        let approvalState = try #require(try Self.loadState(root: runtimeRoot, request: request))
        let approvalToken = try #require(approvalState.pendingApprovalToken)

        try? await Task.sleep(for: .milliseconds(500))
        let pausedState = try #require(try Self.loadState(root: runtimeRoot, request: request))
        #expect(pausedState.phase == .waitingForApproval)
        #expect(!pausedState.phase.isTerminal)

        let attemptDirectory = DetachedAgentRuntimePaths.attemptDirectoryURL(
            rootDirectoryURL: runtimeRoot,
            runID: request.runID,
            attemptID: request.attemptID
        )
        let persistedText = try persistedUTF8Text(in: attemptDirectory)
        #expect(!persistedText.contains(providerApprovalID))
        #expect(persistedText.contains(approvalToken.rawValue.uuidString))

        let mailbox = try DetachedAgentCommandMailbox(
            rootDirectoryURL: runtimeRoot,
            runID: request.runID,
            attemptID: request.attemptID
        )
        try mailbox.enqueue(
            DetachedAgentCommandEnvelope(
                runID: request.runID,
                attemptID: request.attemptID,
                command: .respondToApproval(token: approvalToken, decision: .deny)
            )
        )
        let cancelled = await waitUntil(timeout: 6) {
            (try? Self.loadState(root: runtimeRoot, request: request))?.phase == .cancelled
        }
        #expect(cancelled)
        #expect(wakeCount == 1)
    }

    @Test func workTimeoutWritesFailureOnlyAfterProcessTreeIsGone() async throws {
        let fixture = try makeFixtureDirectory(named: "work-timeout")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let runtimeRoot = fixture.appendingPathComponent("runtime", isDirectory: true)
        let childPIDURL = fixture.appendingPathComponent("timeout-child.pid")
        let scriptURL = try makeExecutableScript(
            in: fixture,
            named: "timeout.sh",
            contents: """
            #!/bin/sh
            trap '' TERM
            printf '%s\n' "$$" > "$1"
            while :; do /bin/sleep 30; done
            """
        )
        let request = makeRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [scriptURL.path, childPIDURL.path],
            workspaceURL: fixture,
            runtimeLimit: 0.1
        )
        var wakeCount = 0
        let engine = try DetachedAgentRunnerEngine(
            request: request,
            rootDirectoryURL: runtimeRoot,
            exitProcess: { _ in },
            wakeMainApp: { wakeCount += 1 }
        )
        engine.start()

        let childPID = try await processIdentifier(writtenTo: childPIDURL)
        let failed = await waitUntil(timeout: 6) {
            (try? Self.loadState(root: runtimeRoot, request: request))?.phase == .failed
        }
        #expect(failed)
        let state = try #require(try Self.loadState(root: runtimeRoot, request: request))
        #expect(state.terminalSafeError == "Timed out")
        #expect(!Self.processExists(childPID))
        #expect(wakeCount == 1)
    }

    @Test func terminalTakeoverDoesNotWakeMainApp() async throws {
        let fixture = try makeFixtureDirectory(named: "terminal-takeover")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let runtimeRoot = fixture.appendingPathComponent("runtime", isDirectory: true)
        let scriptURL = try makeExecutableScript(
            in: fixture,
            named: "takeover.sh",
            contents: """
            #!/bin/sh
            trap 'exit 0' TERM INT
            while :; do /bin/sleep 30; done
            """
        )
        let request = makeRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [scriptURL.path],
            workspaceURL: fixture,
            runtimeLimit: 30
        )
        var wakeCount = 0
        let engine = try DetachedAgentRunnerEngine(
            request: request,
            rootDirectoryURL: runtimeRoot,
            exitProcess: { _ in },
            wakeMainApp: { wakeCount += 1 }
        )
        engine.start()

        let running = await waitUntil(timeout: 3) {
            (try? Self.loadState(root: runtimeRoot, request: request))?.phase == .running
        }
        #expect(running)

        let mailbox = try DetachedAgentCommandMailbox(
            rootDirectoryURL: runtimeRoot,
            runID: request.runID,
            attemptID: request.attemptID
        )
        try mailbox.enqueue(
            DetachedAgentCommandEnvelope(
                runID: request.runID,
                attemptID: request.attemptID,
                command: .takeOverInTerminal
            )
        )

        let handedOff = await waitUntil(timeout: 6) {
            guard let state = try? Self.loadState(root: runtimeRoot, request: request) else {
                return false
            }
            return state.phase == .cancelled && state.handedOffToTerminal == true
        }
        #expect(handedOff)
        #expect(wakeCount == 0)
    }

    private func makeRequest(
        executor: HeadlessExecutor = .codex,
        executableURL: URL,
        arguments: [String],
        workspaceURL: URL,
        environmentKeysToRemove: [String] = [],
        environmentOverrides: [String: String] = [:],
        usesDuplexStandardInput: Bool = false,
        runtimeLimit: TimeInterval
    ) -> DetachedAgentLaunchRequest {
        DetachedAgentLaunchRequest(
            runID: UUID(),
            attemptID: UUID(),
            executor: executor,
            leg: .execute,
            spec: DetachedAgentLaunchSpec(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectoryURL: workspaceURL,
                environmentKeysToRemove: environmentKeysToRemove,
                environmentOverrides: environmentOverrides,
                usesDuplexStandardInput: usesDuplexStandardInput,
                runtimeLimit: runtimeLimit
            )
        )
    }

    private func makeFixtureDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DetachedAgentRunnerEngineTests-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private func makeExecutableScript(
        in directory: URL,
        named name: String,
        contents: String
    ) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        guard chmod(url.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return url
    }

    private func processIdentifier(writtenTo fileURL: URL) async throws -> pid_t {
        let found = await waitUntil(timeout: 3) {
            FileManager.default.fileExists(atPath: fileURL.path)
        }
        guard found else { throw RunnerEngineTestError.processIdentifierTimedOut }
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let processID = pid_t(contents), processID > 1 else {
            throw RunnerEngineTestError.invalidProcessIdentifier
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
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private func persistedUTF8Text(in directory: URL) throws -> String {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var text = ""
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true,
                  let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            text += contents
        }
        return text
    }

    nonisolated private static func loadState(
        root: URL,
        request: DetachedAgentLaunchRequest
    ) throws -> DetachedAgentDurableState? {
        try DetachedAgentDurableStateStore.loadReadOnly(
            rootDirectoryURL: root,
            runID: request.runID,
            attemptID: request.attemptID
        )
    }

    nonisolated private static func processExists(_ processID: pid_t) -> Bool {
        kill(processID, 0) == 0 || errno == EPERM
    }

    private enum RunnerEngineTestError: Error {
        case processIdentifierTimedOut
        case invalidProcessIdentifier
    }
}

@MainActor
struct DetachedAgentRunnerBootstrapSecurityTests {

    @Test func bootstrapUsesPipeOnlyAndStripsRunnerSecrets() async throws {
        let fixture = try makeFixtureDirectory(named: "bootstrap-secrecy")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let argumentCaptureURL = fixture.appendingPathComponent("arguments.txt")
        let environmentCaptureURL = fixture.appendingPathComponent("environment.txt")
        let secret = "sensitive-bootstrap-\(UUID().uuidString)"
        let prompt = "private-prompt-\(UUID().uuidString)"
        let scriptURL = try makeExecutableScript(
            in: fixture,
            named: "fake-runner.sh",
            contents: """
            #!/bin/sh
            printf '%s\n' "$@" > "$TMPDIR/arguments.txt"
            /usr/bin/env | /usr/bin/sort > "$TMPDIR/environment.txt"
            /bin/cat <&3 >/dev/null
            """
        )
        let request = DetachedAgentLaunchRequest(
            runID: UUID(),
            attemptID: UUID(),
            executor: .codex,
            leg: .execute,
            spec: DetachedAgentLaunchSpec(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", prompt],
                currentDirectoryURL: fixture,
                environmentKeysToRemove: ["HEYMATE_PRIVATE_SECRET"],
                environmentOverrides: ["HEYMATE_SCOPED_VALUE": secret],
                runtimeLimit: 5
            )
        )
        let runnerPID = try DetachedAgentRunnerBootstrap.spawn(
            executableURL: scriptURL,
            request: request,
            environment: [
                "PATH": "/usr/bin:/bin",
                "HOME": fixture.path,
                "TMPDIR": fixture.path,
                "LANG": "en_AU.UTF-8",
                "CLAUDE_CONFIG_DIR": fixture.appendingPathComponent("claude").path,
                "HEYMATE_PRIVATE_SECRET": secret,
                "AWS_SECRET_ACCESS_KEY": secret,
                "GITHUB_TOKEN": secret,
                "DYLD_INSERT_LIBRARIES": "/tmp/untrusted.dylib",
                "SSH_AUTH_SOCK": "/tmp/untrusted-agent.sock",
                "CI": "true"
            ]
        )
        defer { Self.killAndReapIfNeeded(runnerPID) }

        let captured = await waitUntil(timeout: 3) {
            FileManager.default.fileExists(atPath: argumentCaptureURL.path)
                && FileManager.default.fileExists(atPath: environmentCaptureURL.path)
        }
        #expect(captured)
        let arguments = try String(contentsOf: argumentCaptureURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        #expect(
            arguments == [
                DetachedAgentRunnerInvocation.commandLineFlag,
                request.runID.uuidString.lowercased(),
                request.attemptID.uuidString.lowercased(),
                "3"
            ]
        )
        #expect(!arguments.joined().contains(prompt))
        #expect(!arguments.joined().contains(secret))
        let environment = try String(contentsOf: environmentCaptureURL, encoding: .utf8)
        #expect(environment.contains("HOME=\(fixture.path)\n"))
        #expect(environment.contains("TMPDIR=\(fixture.path)\n"))
        #expect(environment.contains("CLAUDE_CONFIG_DIR=\(fixture.path)/claude\n"))
        #expect(environment.contains("TERM=dumb\n"))
        #expect(environment.contains("NO_COLOR=1\n"))
        #expect(!environment.contains("HEYMATE_PRIVATE_SECRET="))
        #expect(!environment.contains("AWS_SECRET_ACCESS_KEY="))
        #expect(!environment.contains("GITHUB_TOKEN="))
        #expect(!environment.contains("DYLD_INSERT_LIBRARIES="))
        #expect(!environment.contains("SSH_AUTH_SOCK="))
        #expect(!environment.contains("CI="))
        let persistedText = try persistedUTF8Text(in: fixture)
        #expect(!persistedText.contains(prompt))
        #expect(!persistedText.contains(secret))

        #expect(await reap(runnerPID, timeout: 3))
    }

    @Test func killingRunnerOwnerKillsItsChildAndGrandchild() async throws {
        let fixture = try makeFixtureDirectory(named: "owner-death")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let rootPIDURL = fixture.appendingPathComponent("root.pid")
        let childPIDURL = fixture.appendingPathComponent("child.pid")
        let grandchildPIDURL = fixture.appendingPathComponent("grandchild.pid")
        let grandchildScriptURL = try makeExecutableScript(
            in: fixture,
            named: "grandchild.sh",
            contents: """
            #!/bin/sh
            trap '' TERM
            printf '%s\n' "$$" > "$1"
            while :; do /bin/sleep 30; done
            """
        )
        let childScriptURL = try makeExecutableScript(
            in: fixture,
            named: "child.sh",
            contents: """
            #!/bin/sh
            trap '' TERM
            printf '%s\n' "$$" > "$1"
            /bin/sh "$3" "$2" &
            wait
            """
        )
        let rootScriptURL = try makeExecutableScript(
            in: fixture,
            named: "root.sh",
            contents: """
            #!/bin/sh
            trap '' TERM
            printf '%s\n' "$$" > "$1"
            /bin/sh "$4" "$2" "$3" "$5" &
            wait
            """
        )
        let request = DetachedAgentLaunchRequest(
            runID: UUID(),
            attemptID: UUID(),
            executor: .codex,
            leg: .execute,
            spec: DetachedAgentLaunchSpec(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    rootScriptURL.path,
                    rootPIDURL.path,
                    childPIDURL.path,
                    grandchildPIDURL.path,
                    childScriptURL.path,
                    grandchildScriptURL.path
                ],
                currentDirectoryURL: fixture,
                runtimeLimit: 30
            )
        )
        let runDirectoryURL = DetachedAgentRuntimePaths.runDirectoryURL(
            rootDirectoryURL: DetachedAgentRuntimePaths.defaultRootURL,
            runID: request.runID
        )
        defer { try? FileManager.default.removeItem(at: runDirectoryURL) }

        let hostExecutable = try #require(DetachedAgentRunnerExecutable.bundledURL())
        #expect(hostExecutable.lastPathComponent == "HeyMateAgentRunner")
        #expect(hostExecutable.deletingLastPathComponent().lastPathComponent == "Helpers")
        let runnerPID = try DetachedAgentRunnerBootstrap.spawn(
            executableURL: hostExecutable,
            request: request
        )
        var rootPID: pid_t?
        defer {
            Self.killAndReapIfNeeded(runnerPID)
            if let rootPID, rootPID > 1, getpgid(rootPID) == rootPID {
                Darwin.kill(-rootPID, SIGKILL)
            }
        }

        rootPID = try await processIdentifier(writtenTo: rootPIDURL)
        let childPID = try await processIdentifier(writtenTo: childPIDURL)
        let grandchildPID = try await processIdentifier(writtenTo: grandchildPIDURL)
        let processGroupID = try #require(rootPID)
        #expect(getpgid(processGroupID) == processGroupID)
        #expect(getpgid(childPID) == processGroupID)
        #expect(getpgid(grandchildPID) == processGroupID)

        #expect(Darwin.kill(runnerPID, SIGKILL) == 0)
        #expect(await reap(runnerPID, timeout: 3))
        let descendantsExited = await waitUntil(timeout: 6) {
            !Self.processExists(processGroupID)
                && !Self.processExists(childPID)
                && !Self.processExists(grandchildPID)
        }
        #expect(descendantsExited)
    }

    private func makeFixtureDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DetachedAgentRunnerBootstrapTests-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private func makeExecutableScript(
        in directory: URL,
        named name: String,
        contents: String
    ) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        guard chmod(url.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return url
    }

    private func processIdentifier(writtenTo fileURL: URL) async throws -> pid_t {
        let found = await waitUntil(timeout: 5) {
            FileManager.default.fileExists(atPath: fileURL.path)
        }
        guard found else { throw BootstrapSecurityTestError.processIdentifierTimedOut }
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let processID = pid_t(contents), processID > 1 else {
            throw BootstrapSecurityTestError.invalidProcessIdentifier
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
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private func reap(_ processID: pid_t, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var status: Int32 = 0
            let result = waitpid(processID, &status, WNOHANG)
            if result == processID || (result == -1 && errno == ECHILD) { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        var status: Int32 = 0
        let result = waitpid(processID, &status, WNOHANG)
        return result == processID || (result == -1 && errno == ECHILD)
    }

    private func persistedUTF8Text(in directory: URL) throws -> String {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var text = ""
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true,
                  let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            text += contents
        }
        return text
    }

    nonisolated private static func processExists(_ processID: pid_t) -> Bool {
        kill(processID, 0) == 0 || errno == EPERM
    }

    nonisolated private static func killAndReapIfNeeded(_ processID: pid_t) {
        guard processID > 1 else { return }
        if processExists(processID) {
            Darwin.kill(-processID, SIGKILL)
            Darwin.kill(processID, SIGKILL)
        }
        var status: Int32 = 0
        _ = waitpid(processID, &status, WNOHANG)
    }

    private enum BootstrapSecurityTestError: Error {
        case processIdentifierTimedOut
        case invalidProcessIdentifier
    }
}
