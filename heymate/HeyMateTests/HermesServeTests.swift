import Foundation
import Testing
@testable import HeyMate

@MainActor
struct HermesServeTests {
    @Test func ownedBackendAuthenticatesAttestsReusesAndStopsItsProcess() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let owner = HermesServeBackend()
        let first = try await owner.start(configuration: fixture.launch, expectedVersion: "1.2.3", timeout: .seconds(5))
        let reused = try await owner.start(configuration: fixture.launch, expectedVersion: "1.2.3")
        #expect(first == reused)
        #expect(first.home == fixture.profile.standardizedFileURL)
        #expect(first.pid > 0 && first.port > 0)
        let socket = try owner.openWebSocket()
        let session = HermesServeSession(connection: socket)
        let identity = try await session.create(workspace: fixture.root)
        #expect(identity.storedID == "stored-session")
        var chunks: [String] = []
        session.onTextDelta = { chunks.append($0) }
        let reply = try await session.prompt(text: "hello", timeout: .seconds(3))
        #expect(reply == HermesServeSession.Result(text: "Hello serve", status: "complete"))
        #expect(chunks == ["Hello ", "serve"])
        let secondReply = try await session.prompt(text: "again", timeout: .seconds(3))
        #expect(secondReply.text == "Hello serve")
        #expect(owner.identity?.pid == first.pid)
        socket.close()
        let resumed = HermesServeSession(connection: try owner.openWebSocket())
        let resumedIdentity = try await resumed.resume(storedID: identity.storedID, workspace: fixture.root)
        #expect(resumedIdentity.storedID == identity.storedID)
        #expect(try await resumed.prompt(text: "follow-up", timeout: .seconds(3)).text == "Hello serve")
        #expect(await owner.shutdown())
        #expect(owner.identity == nil)
        #expect(throws: HermesServeBackend.Failure.notRunning) { try owner.openWebSocket() }
        let second = try await owner.start(configuration: fixture.launch, expectedVersion: "1.2.3", timeout: .seconds(5))
        #expect(second.pid != first.pid)
        #expect(await owner.shutdown())
        let fingerprints = try String(contentsOf: fixture.trace, encoding: .utf8).split(separator: "\n")
        #expect(fingerprints.count == 2)
        #expect(fingerprints[0] != fingerprints[1])
    }

    @Test(arguments: ["home", "pid", "version", "auth", "nested-runtime"])
    func mismatchedListenerCannotBecomeReady(mismatch: String) async throws {
        let fixture = try Fixture(mismatch: mismatch)
        defer { fixture.cleanup() }
        let owner = HermesServeBackend()
        do {
            _ = try await owner.start(configuration: fixture.launch, expectedVersion: "1.2.3", timeout: .seconds(5))
            Issue.record("Mismatched backend was accepted")
        } catch let failure as HermesServeBackend.Failure {
            let expected: HermesServeBackend.Failure
            switch mismatch {
            case "home": expected = .homeMismatch
            case "pid": expected = .identityMismatch
            case "version": expected = .versionMismatch
            case "nested-runtime": expected = .unsupportedRuntime
            default: expected = .authenticationFailed
            }
            #expect(failure == expected)
        }
        #expect(owner.identity == nil)
        #expect(await owner.shutdown())
    }

    @Test func officialCommitBuildRequiresMatchingBootedCommitAndBaseMetadata() async throws {
        let commit = "d923a5eb487a17c0a68801bba9ef0f56c81040a8"
        let health: [String: JSONValue] = ["version": .string("unknown"), "displayVersion": .string("git.d923a5e"), "commit": .string(commit)]
        #expect(try HermesServeBackend.validatedVersion(health: health, status: ["version": .string("unknown")], expectedCommit: commit) == "git.d923a5e")
        #expect(throws: HermesServeBackend.Failure.versionMismatch) {
            try HermesServeBackend.validatedVersion(health: health, status: ["version": .string("1.2.3")])
        }
        #expect(throws: HermesServeBackend.Failure.versionMismatch) {
            try HermesServeBackend.validatedVersion(health: health, status: ["version": .string("unknown")], expectedVersion: "1.2.3")
        }
        var wrongPrefix = health
        wrongPrefix["displayVersion"] = .string("git.abcdef0")
        #expect(throws: HermesServeBackend.Failure.versionMismatch) {
            try HermesServeBackend.validatedVersion(health: wrongPrefix, status: ["version": .string("unknown")])
        }
        let fixture = try Fixture(mismatch: "commit-version")
        defer { fixture.cleanup() }
        let owner = HermesServeBackend()
        defer { owner.stop() }
        let identity = try await owner.start(configuration: fixture.launch, expectedCommit: commit, timeout: .seconds(5))
        #expect(identity.version == "git.d923a5e")
        #expect(await owner.shutdown())
    }

    @Test func readinessTimeoutAndCallerCancellationStopOnlyOwnedProcess() async throws {
        let fixture = try Fixture(mismatch: "no-ready")
        defer { fixture.cleanup() }
        let owner = HermesServeBackend()
        await #expect(throws: HermesServeBackend.Failure.startupTimedOut) {
            try await owner.start(configuration: fixture.launch, timeout: .milliseconds(30))
        }
        #expect(await owner.shutdown())
        let pending = Task { try await owner.start(configuration: fixture.launch, timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(20))
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await owner.shutdown())
    }

    @Test func completionBeforeAcceptanceIsBufferedAndOtherSessionEventsIgnored() async throws {
        let peer = Peer()
        let session = HermesServeSession(connection: peer.socket)
        _ = try await session.create(workspace: peer.workspace)
        let prompt = Task { try await session.prompt(text: "Check", timeout: .seconds(2)) }
        try await peer.waitFor("prompt.submit")
        let requestID = try #require(peer.sent.last?["id"])
        peer.event("message.delta", sid: "foreign", payload: .object(["text": .string("LEAK")]))
        peer.event("message.complete", sid: "runtime-session", payload: .object([
            "text": .string("Verified answer"), "status": .string("complete")
        ]))
        peer.respond(id: requestID, result: .object(["status": .string("streaming")]))
        #expect(try await prompt.value.text == "Verified answer")
        peer.socket.close()
    }

    @Test func requestAcceptanceAloneTimesOutAndAttemptsInterruption() async throws {
        let peer = Peer()
        let session = HermesServeSession(connection: peer.socket)
        _ = try await session.create(workspace: peer.workspace)
        let prompt = Task { try await session.prompt(text: "Check", timeout: .milliseconds(20)) }
        try await peer.waitFor("prompt.submit")
        peer.respond(id: try #require(peer.sent.last?["id"]), result: .object(["status": .string("streaming")]))
        await #expect(throws: HermesServeWebSocket.Failure.timedOut) { try await prompt.value }
        try await peer.waitFor("session.interrupt")
        peer.socket.close()
    }

    @Test func websocketMatchesIDsRejectsUnsupportedRequestsAndFailsPendingOnClose() async throws {
        let peer = Peer()
        let request = Task { try await peer.socket.request(method: "unknown") }
        try await peer.waitFor("unknown")
        let id = try #require(peer.sent.last?["id"])
        peer.respond(id: .string("unowned"), result: .string("wrong"))
        peer.respond(id: id, result: .string("owned"))
        #expect(try await request.value == .string("owned"))
        peer.socket.receive(.object(["jsonrpc": .string("2.0"), "id": .number(17),
                                    "method": .string("fs/read_text_file"), "params": .emptyObject]))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while peer.sent.last?["id"] != .number(17), ContinuousClock.now < deadline { await Task.yield() }
        guard case .object(let error) = peer.sent.last?["error"] else { Issue.record("No rejection"); return }
        #expect(error["code"] == .number(-32601))
        let pending = Task { try await peer.socket.request(method: "pending") }
        try await peer.waitFor("pending")
        peer.socket.close()
        await #expect(throws: HermesServeWebSocket.Failure.closed) { try await pending.value }
    }

    @Test func nativeApprovalsPermitOnlyAdvertisedOnceAndPreserveRequestID() async throws {
        let peer = Peer()
        let session = HermesServeSession(connection: peer.socket)
        _ = try await session.create(workspace: peer.workspace)
        var presented = 0
        session.onRequest = { request in
            presented += 1
            #expect(request.method == "approval")
            return .object(["choice": .string(presented == 1 ? "always" : "once"), "all": .bool(true)])
        }
        for (id, expected) in [("request-a", "deny"), ("request-b", "once")] {
            peer.serverRequest(id: id, method: "approval", params: .object([
                "session_id": .string("runtime-session"), "request_id": .string(id),
                "choices": .array([.string("once"), .string("session"), .string("always"), .string("deny")])
            ]))
            let reply = try await peer.waitForReply(id)
            #expect(reply["result"] == .object(["choice": .string(expected), "all": .bool(false)]))
        }
        #expect(presented == 2)
        peer.serverRequest(id: "foreign", method: "approval", params: .object([
            "session_id": .string("foreign-session"), "choices": .array([.string("once")])
        ]))
        let foreign = try await peer.waitForReply("foreign")
        #expect(foreign["error"] != nil)
        #expect(presented == 2)
        session.close()
    }

    @Test func clarificationKeepsLockedAnswersAndRejectsUnknownQuestions() async throws {
        let peer = Peer()
        let session = HermesServeSession(connection: peer.socket)
        _ = try await session.create(workspace: peer.workspace)
        var call = 0
        session.onRequest = { _ in
            call += 1
            return .object(["answers": .object(call == 1
                ? ["one": .string("changed"), "two": .string("blue")]
                : ["unrelated": .string("wrong scope")])])
        }
        for id in ["clarify-a", "clarify-b"] {
            peer.serverRequest(id: id, method: "clarify", params: .object([
                "session_id": .string("runtime-session"),
                "questions": .array([.object(["qid": .string("one"), "question": .string("One?")]),
                                      .object(["qid": .string("two"), "question": .string("Two?")])]),
                "answers": .object(["one": .string("locked")])
            ]))
            let reply = try await peer.waitForReply(id)
            let expected: JSONValue = id == "clarify-a"
                ? .object(["answers": .object(["one": .string("locked"), "two": .string("blue")])]) : .emptyObject
            #expect(reply["result"] == expected)
        }
        session.close()
    }

    @Test func withdrawnRequestCancelsNativeCallbackAndCannotGrantLatePermission() async throws {
        let peer = Peer()
        let session = HermesServeSession(connection: peer.socket)
        _ = try await session.create(workspace: peer.workspace)
        var shown = false
        var cancelled = false
        var cleared = 0
        session.onRequest = { _ in
            shown = true
            do { try await ContinuousClock().sleep(for: .seconds(60)) }
            catch { cancelled = true }
            return .object(["choice": .string("once")])
        }
        session.onRequestWithdrawn = { _ in cleared += 1 }
        peer.serverRequest(id: "withdrawn", method: "approval", params: .object([
            "session_id": .string("runtime-session"), "choices": .array([.string("once")])
        ]))
        try await peer.waitUntil { shown }
        peer.event("request.cancel", sid: "runtime-session", payload: .object([
            "id": .string("withdrawn"), "method": .string("approval"), "reason": .string("interrupted")
        ]))
        try await peer.waitUntil { cancelled }
        #expect(cleared == 1)
        #expect(!peer.sent.contains { $0["id"] == .string("withdrawn") && $0["result"] != nil })
        session.close()
    }

    @Test func acknowledgedTurnReconnectsReplaysOnceAndNeverSubmitsAgain() async throws {
        let original = Peer()
        let replacement = Peer()
        replacement.resumeRunning = true
        replacement.replayEvents = [
            .object(["session_id": .string("runtime-session"), "seq": .number(2), "type": .string("message.delta"),
                     "payload": .object(["text": .string("B")])]),
            .object(["session_id": .string("runtime-session"), "seq": .number(3), "type": .string("message.complete"),
                     "payload": .object(["text": .string("AB"), "status": .string("complete")])])
        ]
        let session = HermesServeSession(connection: original.socket, reconnect: { replacement.socket })
        _ = try await session.create(workspace: original.workspace)
        var chunks: [String] = []
        session.onTextDelta = { chunks.append($0) }
        let prompt = Task { try await session.prompt(text: "Check", timeout: .seconds(3)) }
        try await original.waitFor("prompt.submit")
        original.respond(id: try #require(original.sent.last?["id"]), result: .object(["status": .string("streaming")]))
        try await ContinuousClock().sleep(for: .milliseconds(10))
        original.event("message.delta", sid: "runtime-session", payload: .object(["text": .string("A")]), seq: 1)
        original.event("message.delta", sid: "runtime-session", payload: .object(["text": .string("A")]), seq: 1)
        original.socket.close()
        let result = try await prompt.value
        #expect(result.text == "AB")
        #expect(chunks == ["A", "B"])
        #expect(result.completionSequence == 3)
        #expect(session.checkpoint?.lastSequence == 3)
        #expect(!replacement.sent.contains { $0["method"] == .string("prompt.submit") })
        session.close()
    }

    @Test func truncatedReplayFailsVisiblyWithoutResendingPrompt() async throws {
        let original = Peer()
        let replacement = Peer()
        replacement.replayTruncated = true
        let session = HermesServeSession(connection: original.socket, reconnect: { replacement.socket })
        _ = try await session.create(workspace: original.workspace)
        let prompt = Task { try await session.prompt(text: "Check", timeout: .seconds(3)) }
        try await original.waitFor("prompt.submit")
        original.respond(id: try #require(original.sent.last?["id"]), result: .object(["status": .string("streaming")]))
        try await ContinuousClock().sleep(for: .milliseconds(10))
        original.socket.close()
        await #expect(throws: HermesServeSession.Failure.replayGap) { try await prompt.value }
        #expect(!replacement.sent.contains { $0["method"] == .string("prompt.submit") })
    }

    @Test func lostAcceptanceDoesNotDuplicatePossibleRemoteExecution() async throws {
        let original = Peer()
        let replacement = Peer()
        let session = HermesServeSession(connection: original.socket, reconnect: { replacement.socket })
        _ = try await session.create(workspace: original.workspace)
        let prompt = Task { try await session.prompt(text: "Check", timeout: .seconds(3)) }
        try await original.waitFor("prompt.submit")
        original.socket.close()
        await #expect(throws: HermesServeSession.Failure.submissionUncertain) { try await prompt.value }
        #expect(original.sent.filter { $0["method"] == .string("prompt.submit") }.count == 1)
        #expect(!replacement.sent.contains { $0["method"] == .string("prompt.submit") })
    }

    @Test func restoredRunningWorkIsObservedAndNotSilentlyInterruptedByNewInput() async throws {
        let peer = Peer()
        peer.resumeRunning = true
        let session = HermesServeSession(connection: peer.socket)
        _ = try await session.resume(storedID: "stored-session", workspace: peer.workspace)
        var recovered: HermesServeSession.Result?
        session.onRecoveredResult = { recovered = $0 }
        await #expect(throws: HermesServeSession.Failure.priorWorkRunning) {
            try await session.prompt(text: "New unrelated task")
        }
        session.close()
        #expect(peer.socket.isOpen)
        #expect(!peer.sent.contains { [.string("prompt.submit"), .string("session.interrupt")].contains($0["method"] ?? .null) })
        peer.event("message.complete", sid: "runtime-session", payload: .object([
            "status": .string("complete"), "text": .string("Earlier work finished")
        ]), seq: 1)
        #expect(recovered?.text == "Earlier work finished")
        #expect(!session.hasPriorWorkInProgress)
        session.close()
    }

    @Test func durablePendingRecoveryReplaysFinalOnlyAfterItsSavedCursor() async throws {
        let peer = Peer()
        peer.replayEvents = [.object([
            "session_id": .string("runtime-session"), "seq": .number(2), "type": .string("message.complete"),
            "payload": .object(["status": .string("complete"), "text": .string("Recovered final answer")])
        ])]
        let session = HermesServeSession(connection: peer.socket)
        let saved = HermesServeSession.Checkpoint(identity: .init(runtimeID: "runtime-session", storedID: "stored-session"),
                                                  epoch: "test-epoch", lastSequence: 1)
        var recovered: HermesServeSession.Result?
        session.onRecoveredResult = { recovered = $0 }
        _ = try await session.resume(storedID: "stored-session", workspace: peer.workspace,
                                     checkpoint: saved, recoverPendingTurn: true)
        #expect(recovered?.text == "Recovered final answer")
        #expect(recovered?.completionSequence == 2)
        #expect(!session.hasPriorWorkInProgress)
        guard let replay = peer.sent.first(where: { $0["method"] == .string("session.events.since") }),
              case .object(let params) = replay["params"] else { Issue.record("No replay"); return }
        #expect(params["last_seen"] == .number(1))
        #expect(!peer.sent.contains { $0["method"] == .string("prompt.submit") })
        session.close()
    }

    @Test func staleEpochBlocksPendingResumeBeforeHermesCanAutoContinueIt() async throws {
        let peer = Peer()
        let session = HermesServeSession(connection: peer.socket)
        let saved = HermesServeSession.Checkpoint(identity: .init(runtimeID: "runtime-session", storedID: "stored-session"),
                                                  epoch: "previous-process", lastSequence: 9)
        await #expect(throws: HermesServeSession.Failure.replayGap) {
            try await session.resume(storedID: "stored-session", workspace: peer.workspace,
                                     checkpoint: saved, recoverPendingTurn: true)
        }
        #expect(!peer.sent.contains { $0["method"] == .string("session.resume") })
        #expect(!peer.sent.contains { $0["method"] == .string("prompt.submit") })
        session.close()
    }

    @Test func coldRecoveryReadsAcceptedDurableBoundaryBeforeAnyResume() async throws {
        let peer = Peer()
        var lookupBeforeResume = false
        let session = HermesServeSession(connection: peer.socket, recoverDurable: { storedID, rowID in
            #expect(storedID == "stored-session")
            #expect(rowID == 41)
            lookupBeforeResume = !peer.sent.contains { $0["method"] == .string("session.resume") }
            return .init(text: "Persisted answer after app closed", status: "complete")
        })
        var recovered: HermesServeSession.Result?
        session.onRecoveredResult = { recovered = $0 }
        let saved = HermesServeSession.Checkpoint(identity: .init(runtimeID: "old-runtime", storedID: "stored-session"),
                                                  epoch: "dead-process", lastSequence: 9)
        _ = try await session.resume(storedID: "stored-session", workspace: peer.workspace,
            checkpoint: saved, recoverPendingTurn: true, acceptedUserRowID: 41)
        #expect(lookupBeforeResume)
        #expect(recovered?.text == "Persisted answer after app closed")
        #expect(session.checkpoint?.epoch == "test-epoch")
        #expect(!peer.sent.contains { $0["method"] == .string("prompt.submit") })
        session.close()
    }

    @Test func unresolvedDurableTurnNeverInvokesResumeAutoContinuation() async throws {
        let peer = Peer()
        let session = HermesServeSession(connection: peer.socket, recoverDurable: { _, _ in nil })
        let saved = HermesServeSession.Checkpoint(identity: .init(runtimeID: "old-runtime", storedID: "stored-session"),
                                                  epoch: "dead-process", lastSequence: 9)
        await #expect(throws: HermesServeSession.Failure.replayGap) {
            try await session.resume(storedID: "stored-session", workspace: peer.workspace,
                checkpoint: saved, recoverPendingTurn: true, acceptedUserRowID: 41)
        }
        #expect(!peer.sent.contains { $0["method"] == .string("session.resume") })
        session.close()
    }

    @Test func durableHistoryRequiresExactCompleteUntruncatedTurn() {
        let user: JSONValue = .object(["id": .number(41), "role": .string("user"), "content": .string("Task")])
        let assistant: JSONValue = .object(["id": .number(42), "role": .string("assistant"),
            "content": .string("Answer"), "finish_reason": .string("stop"), "tool_calls": .null])
        func page(_ rows: [JSONValue], newer: Bool = false) -> JSONValue {
            .object(["messages": .array(rows), "pagination": .object(["has_newer": .bool(newer)])])
        }
        #expect(HermesServeBackend.durableResult(page: page([user, assistant]), userRowID: 41)?.text == "Answer")
        #expect(HermesServeBackend.durableResult(page: page([user, assistant]), userRowID: 40) == nil)
        #expect(HermesServeBackend.durableResult(page: page([user, assistant], newer: true), userRowID: 41) == nil)
        #expect(HermesServeBackend.durableResult(page: page([user]), userRowID: 41) == nil)
        #expect(HermesServeBackend.durableResult(page: page([user, assistant, user, assistant]), userRowID: 41) == nil)
        let pendingTool: JSONValue = .object(["id": .number(42), "role": .string("assistant"),
            "content": .string("Working"), "finish_reason": .string("stop"), "tool_calls": .array([.emptyObject])])
        #expect(HermesServeBackend.durableResult(page: page([user, pendingTool]), userRowID: 41) == nil)
        for reason in ["error", "length", "tool_calls", "incomplete", "verification_required"] {
            let row: JSONValue = .object(["id": .number(42), "role": .string("assistant"), "content": .string("Partial"), "finish_reason": .string(reason)])
            #expect(HermesServeBackend.durableResult(page: page([user, row]), userRowID: 41) == nil)
        }
    }

    @Test func runtimeGuardRejectsNestedLoopBeforeSessionOrPromptSubmission() async throws {
        for key in ["openai_runtime", "api_mode"] {
            #expect(throws: HermesServeBackend.Failure.unsupportedRuntime) {
                try HermesServeBackend.validateHermesRuntime(.object(["model": .object([key: .string("codex_app_server")])]))
            }
        }
        try HermesServeBackend.validateHermesRuntime(.object(["model": .object([
            "openai_runtime": .string("auto"), "api_mode": .string("chat_completions")])]))
        let peer = Peer()
        var blocked = true
        var checks = 0
        let session = HermesServeSession(connection: peer.socket, runtimeGuard: {
            checks += 1
            if blocked { throw HermesServeBackend.Failure.unsupportedRuntime }
        })
        await #expect(throws: HermesServeBackend.Failure.unsupportedRuntime) { try await session.create(workspace: peer.workspace) }
        #expect(!peer.sent.contains { $0["method"] == .string("session.create") })
        blocked = false
        _ = try await session.create(workspace: peer.workspace)
        blocked = true
        await #expect(throws: HermesServeBackend.Failure.unsupportedRuntime) { try await session.prompt(text: "Task") }
        #expect(checks == 3)
        #expect(!peer.sent.contains { $0["method"] == .string("prompt.submit") })
        session.close()
    }

    @Test func durableSubmitFailureStopsBeforeAnyPromptIsSent() async throws {
        let peer = Peer()
        let session = HermesServeSession(connection: peer.socket)
        _ = try await session.create(workspace: peer.workspace)
        session.onPromptWillSubmit = { throw POSIXError(.ENOSPC) }
        await #expect(throws: POSIXError.self) { try await session.prompt(text: "Do work") }
        #expect(!peer.sent.contains { $0["method"] == .string("prompt.submit") })
        #expect(!peer.sent.contains { $0["method"] == .string("session.interrupt") })
    }

    @Test func interruptionAckAloneRequiresIdleProofOrOwnedShutdown() async throws {
        let peer = Peer()
        peer.resumeRunning = true
        var ownerStopped = false
        let session = HermesServeSession(connection: peer.socket, stopOwner: {
            ownerStopped = true; return true
        }, cancellationConfirmationTimeout: .milliseconds(10))
        // Create snapshots may be lazy; set busy only after this owned turn starts.
        peer.resumeRunning = false
        _ = try await session.create(workspace: peer.workspace)
        peer.resumeRunning = true
        let prompt = Task { try await session.prompt(text: "Check", timeout: .seconds(3)) }
        try await peer.waitFor("prompt.submit")
        peer.respond(id: try #require(peer.sent.last?["id"]), result: .object(["status": .string("streaming")]))
        try await ContinuousClock().sleep(for: .milliseconds(10))
        #expect(await session.cancelAndWait())
        await #expect(throws: CancellationError.self) { try await prompt.value }
        #expect(ownerStopped)
        #expect(!peer.socket.isOpen)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEYMATE_HERMES_SERVE_LIVE_EXECUTABLE"] != nil
                   && ProcessInfo.processInfo.environment["HEYMATE_HERMES_SERVE_LIVE_PROFILE"] != nil))
    func livePreparedServeKeepsOneBackendAcrossTwoModelTurns() async throws {
        let values = ProcessInfo.processInfo.environment
        let path = try #require(values["HEYMATE_HERMES_SERVE_LIVE_EXECUTABLE"])
        let profile = try #require(values["HEYMATE_HERMES_SERVE_LIVE_PROFILE"])
        let prepared = try HermesEngineConfiguration(executablePath: path, profilePath: profile).resolveLaunchConfiguration()
        var environment = prepared.environment
        if let runtime = values["HEYMATE_HERMES_SERVE_LIVE_RUNTIME"] { environment["HERMES_RUNTIME_DIR"] = runtime }
        let launch = HermesEngineLaunchConfiguration(executableURL: prepared.executableURL,
            profileDirectoryURL: prepared.profileDirectoryURL, environment: environment)
        let owner = HermesServeBackend()
        defer { owner.stop() }
        let identity = try await owner.start(configuration: launch, timeout: .seconds(90))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heymate-serve-live-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstSocket = try owner.openWebSocket()
        let firstSession = HermesServeSession(connection: firstSocket)
        firstSession.onUncertainCancellation = { owner.stop() }
        let remote = try await firstSession.create(workspace: root)
        let marker = "cedar garden number \(Int.random(in: 100_000...999_999))"
        let first = try await firstSession.prompt(text: "Do not use any tools or change files. This is a harmless conversation-memory test. My public garden label is \(marker). Remember that public label in this conversation, and reply exactly STORED.")
        #expect(first.text.trimmingCharacters(in: .whitespacesAndNewlines) == "STORED")
        firstSocket.close()
        let secondSocket = try owner.openWebSocket()
        let secondSession = HermesServeSession(connection: secondSocket)
        secondSession.onUncertainCancellation = { owner.stop() }
        _ = try await secondSession.resume(storedID: remote.storedID, workspace: root)
        var acceptedRowID: Int?
        secondSession.onPromptAccepted = { acceptedRowID = $0 }
        let coldCheckpoint = try #require(secondSession.checkpoint)
        let second = try await secondSession.prompt(text: "Do not use tools. What public garden label did I tell you in the previous turn? Reply only with the exact public label.")
        #expect(second.text.trimmingCharacters(in: .whitespacesAndNewlines) == marker)
        #expect(owner.identity?.pid == identity.pid)
        #expect(await owner.shutdown())
        _ = try await owner.start(configuration: launch, timeout: .seconds(90))
        let coldSession = try owner.openSession()
        var coldResult: HermesServeSession.Result?
        coldSession.onRecoveredResult = { coldResult = $0 }
        _ = try await coldSession.resume(storedID: remote.storedID, workspace: root,
            checkpoint: coldCheckpoint, recoverPendingTurn: true, acceptedUserRowID: try #require(acceptedRowID))
        #expect(coldResult?.text.trimmingCharacters(in: .whitespacesAndNewlines) == marker)
        #expect(coldSession.isUsable)
        coldSession.close()
        #expect(await owner.shutdown())
    }

    @MainActor
    private final class Peer {
        var sent: [[String: JSONValue]] = []
        var resumeRunning = false
        var replayEvents: [JSONValue] = []
        var replayTruncated = false
        let workspace = URL(fileURLWithPath: "/tmp", isDirectory: true)
        lazy var socket: HermesServeWebSocket = {
            let value = HermesServeWebSocket(write: { [weak self] value in
                guard let self, case .object(let fields) = value else { return }
                self.sent.append(fields)
                guard let id = fields["id"], case .string(let method) = fields["method"] else { return }
                if method == "client.capabilities" { self.respond(id: id, result: .emptyObject) }
                if method == "session.create" || method == "session.resume" {
                    self.respond(id: id, result: .object([
                        "session_id": .string("runtime-session"), "stored_session_id": .string("stored-session"),
                        "running": .bool(self.resumeRunning), "status": .string(self.resumeRunning ? "streaming" : "idle"), "info": .object(["cwd": .string(self.workspace.path), "desktop_contract": .number(8)])
                    ]))
                }
                if method == "session.interrupt" { self.respond(id: id, result: .object(["status": .string("interrupted")])) }
                if method == "session.events.since" {
                    self.respond(id: id, result: .object(["events": .array(self.replayEvents), "latest_seq": .number(Double(self.replayEvents.count)),
                        "truncated": .bool(self.replayTruncated), "epoch": .string("test-epoch"), "open_requests": .array([])]))
                }
            })
            value.connect()
            return value
        }()
        func respond(id: JSONValue, result: JSONValue) {
            socket.receive(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
        }
        func event(_ type: String, sid: String, payload: JSONValue, seq: Int? = nil) {
            var params: [String: JSONValue] = ["type": .string(type), "session_id": .string(sid), "payload": payload]
            if let seq { params["seq"] = .number(Double(seq)) }
            socket.receive(.object(["jsonrpc": .string("2.0"), "method": .string("event"), "params": .object(params)]))
        }
        func serverRequest(id: String, method: String, params: JSONValue) {
            socket.receive(.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": params]))
        }
        func waitForReply(_ id: String) async throws -> [String: JSONValue] {
            try await waitUntil { self.sent.contains { $0["id"] == .string(id) && ($0["result"] != nil || $0["error"] != nil) } }
            return sent.first { $0["id"] == .string(id) && ($0["result"] != nil || $0["error"] != nil) }!
        }
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !condition() {
                guard ContinuousClock.now < deadline else { throw HermesServeWebSocket.Failure.timedOut }
                await Task.yield()
            }
        }
        func waitFor(_ method: String) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !sent.contains(where: { $0["method"] == .string(method) }) {
                guard ContinuousClock.now < deadline else { throw HermesServeWebSocket.Failure.timedOut }
                await Task.yield()
            }
        }
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let profile: URL
        let executable: URL
        let trace: URL
        let mismatch: String
        var launch: HermesEngineLaunchConfiguration {
            HermesEngineLaunchConfiguration(executableURL: executable, profileDirectoryURL: profile, environment: [
                "HEYMATE_TEST_MISMATCH": mismatch, "HEYMATE_TEST_TRACE": trace.path
            ])
        }
        init(mismatch: String = "") throws {
            self.mismatch = mismatch
            root = FileManager.default.temporaryDirectory.appendingPathComponent("heymate-serve-fixture-\(UUID())")
            profile = root.appendingPathComponent("profile", isDirectory: true)
            executable = root.appendingPathComponent("hermes-serve-fake")
            trace = root.appendingPathComponent("token-fingerprints.txt")
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            try Self.script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        private static let script = #"""
#!/usr/bin/python3
import base64, hashlib, http.server, json, os, socketserver, struct, sys, urllib.parse
TOKEN = os.environ['HERMES_DASHBOARD_SESSION_TOKEN']
MISMATCH = os.environ.get('HEYMATE_TEST_MISMATCH', '')
SESSION_CWD = ''
assert sys.argv[1:] == ['serve', '--isolated', '--host', '127.0.0.1', '--port', '0', '--no-open']
assert os.environ['HERMES_DESKTOP'] == '1'
assert os.environ['PYTHONPYCACHEPREFIX'] == os.path.join(os.environ['HERMES_HOME'], 'cache', 'heymate-python')
assert os.environ['HERMES_DISABLE_LAZY_INSTALLS'] == '1'
with open(os.environ['HEYMATE_TEST_TRACE'], 'a') as trace:
    trace.write(hashlib.sha256(TOKEN.encode()).hexdigest() + '\n')

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args): pass  # Never log query tokens.
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/api/ws':
            if urllib.parse.parse_qs(parsed.query).get('token') != [TOKEN]:
                self.send_error(401); return
            key = self.headers['Sec-WebSocket-Key']
            digest = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            self.send_response(101)
            self.send_header('Upgrade', 'websocket'); self.send_header('Connection', 'Upgrade')
            self.send_header('Sec-WebSocket-Accept', digest); self.end_headers()
            try: self.websocket()
            except (OSError, EOFError, ValueError): pass
            return
        if self.headers.get('X-Hermes-Session-Token') != TOKEN or MISMATCH == 'auth':
            self.send_error(401); return
        if parsed.path == '/api/host/identity':
            body = {'ok': True, 'protocolVersion': 1, 'pid': os.getpid() + (1 if MISMATCH == 'pid' else 0),
                    'role': 'desktop-serve', 'servesSpa': False}
        elif parsed.path == '/api/health':
            body = {'ok': True, 'version': 'unknown', 'displayVersion': 'git.d923a5e', 'commit': 'd923a5eb487a17c0a68801bba9ef0f56c81040a8'} if MISMATCH == 'commit-version' else {'ok': True, 'version': '1.2.3', 'commit': '0123456789abcdef'}
        elif parsed.path == '/api/config':
            body = {'model': {'openai_runtime': 'codex_app_server'}} if MISMATCH == 'nested-runtime' else {}
        elif parsed.path == '/api/status':
            body = {'hermes_home': '/wrong-home' if MISMATCH == 'home' else os.environ['HERMES_HOME'],
                    'version': 'unknown' if MISMATCH == 'commit-version' else ('9.9.9' if MISMATCH == 'version' else '1.2.3')}
        else: self.send_error(404); return
        data = json.dumps(body).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
    def exact(self, count):
        data = self.rfile.read(count)
        if len(data) != count: raise EOFError()
        return data
    def send_frame(self, obj):
        data = json.dumps(dict(jsonrpc='2.0', **obj)).encode()
        length = len(data)
        header = bytes([0x81, length]) if length < 126 else bytes([0x81, 126]) + struct.pack('!H', length)
        self.wfile.write(header + data); self.wfile.flush()
    def websocket(self):
        global SESSION_CWD
        self.send_frame({'method': 'event', 'params': {'type': 'gateway.ready', 'payload': {'replay_epoch': 'test-epoch'}}})
        while True:
            first, second = self.exact(2)
            opcode = first & 15
            length = second & 127
            if length == 126: length = struct.unpack('!H', self.exact(2))[0]
            if length == 127: length = struct.unpack('!Q', self.exact(8))[0]
            mask = self.exact(4) if second & 128 else None
            data = self.exact(length)
            if mask: data = bytes(value ^ mask[index % 4] for index, value in enumerate(data))
            if opcode == 8: return
            if opcode != 1: continue
            req = json.loads(data)
            method, params = req.get('method'), req.get('params', {})
            if method == 'client.capabilities': result = {}
            elif method in ['session.create', 'session.resume']:
                if method == 'session.create': SESSION_CWD = params['cwd']
                else: assert set(params) <= {'session_id', 'omit_messages', 'inline_images'}
                result = {'session_id': 'runtime-session', 'running': False, 'status': 'idle', 'info': {'cwd': SESSION_CWD, 'desktop_contract': 8}}
                result['stored_session_id' if method == 'session.create' else 'session_key'] = 'stored-session'
            elif method == 'session.events.since':
                result = {'events': [], 'latest_seq': 0, 'truncated': False, 'epoch': 'test-epoch', 'open_requests': []}
            elif method == 'image.attach_bytes': result = {'attached': True}
            elif method == 'prompt.submit':
                self.send_frame({'id': req['id'], 'result': {'status': 'streaming'}})
                self.send_frame({'method': 'event', 'params': {'type': 'message.delta', 'session_id': 'foreign', 'payload': {'text': 'LEAK'}}})
                for text in ['Hello ', 'serve']:
                    self.send_frame({'method': 'event', 'params': {'type': 'message.delta', 'session_id': 'runtime-session', 'payload': {'text': text}}})
                self.send_frame({'method': 'event', 'params': {'type': 'message.complete', 'session_id': 'runtime-session',
                                 'payload': {'text': 'Hello serve', 'status': 'complete'}}})
                continue
            elif method == 'session.interrupt': result = {'status': 'interrupted'}
            else:
                self.send_frame({'id': req['id'], 'error': {'code': -32601, 'message': 'Unsupported'}}); continue
            self.send_frame({'id': req['id'], 'result': result})

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
server = Server(('127.0.0.1', 0), Handler)
if MISMATCH != 'no-ready': print('HERMES_BACKEND_READY port=' + str(server.server_port), flush=True)
server.serve_forever()
"""#
    }
}
