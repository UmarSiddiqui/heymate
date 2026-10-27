import Foundation
import Testing
@testable import HeyMate

@MainActor
struct MateAgentServeConversationClientTests {
    @Test func followUpReusesLiveSessionAndDoesNotImportNativeHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let client = fixture.client()
        var chunks: [String] = []
        var activity: [String] = []
        client.onProgress = { type, _ in activity.append(type) }
        let first = try await client.analyzeImageStreaming(images: [], systemPrompt: "Interface rules",
            conversationHistory: [("PRIVATE native question", "PRIVATE native answer")],
            userPrompt: "first request", onTextChunk: { chunks.append($0) })
        let second = try await client.analyzeImageStreaming(images: [], systemPrompt: "Changed rules",
            conversationHistory: [("PRIVATE native follow-up", "PRIVATE native answer")],
            userPrompt: "follow-up request", onTextChunk: { _ in })
        #expect(first.text == "Verified answer")
        #expect(second.text == "Verified answer")
        #expect(fixture.peers.count == 1)
        let methods = fixture.peers.flatMap(\.methods)
        #expect(methods.filter { $0 == "session.create" }.count == 1)
        #expect(methods.filter { $0 == "prompt.submit" }.count == 2)
        let prompts = fixture.peers.flatMap(\.prompts)
        let submits = fixture.peers.flatMap(\.submits)
        #expect(prompts == ["first request", "follow-up request"])
        #expect(submits.first?["system"] == .string("Interface rules"))
        #expect(submits.last?["system"] == .string("Changed rules"))
        #expect(!"\(submits)".contains("PRIVATE"))
        #expect(chunks == ["Verified ", "Verified answer"])
        #expect(activity.contains("tool.started"))
        #expect(activity.contains("subagent.started"))
        #expect(activity.last == "turn.complete")
        #expect(try fixture.store.sessionID(chatID: fixture.chatID, profile: fixture.profile) == "stored-test-session")
    }

    @Test func reopeningClientResumesDurableServeSessionWithoutNewSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try await fixture.client().analyzeImageStreaming(images: [], systemPrompt: "First rules",
            conversationHistory: [], userPrompt: "first", onTextChunk: { _ in })
        let reopened = fixture.client()
        _ = try await reopened.analyzeImageStreaming(images: [], systemPrompt: "Second rules",
            conversationHistory: [], userPrompt: "second", onTextChunk: { _ in })
        #expect(fixture.peers.count == 2)
        #expect(fixture.peers[1].methods.contains("session.resume"))
        #expect(!fixture.peers[1].methods.contains("session.create"))
        #expect(fixture.peers[1].submits.first?["system"] == .string("Second rules"))
        #expect(fixture.peers[1].prompts.first == "second")
    }

    @Test func corruptMapStopsBeforeOpeningBackend() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.storeRoot, withIntermediateDirectories: true)
        let map = fixture.storeRoot.appendingPathComponent("sessions.json")
        let corrupt = Data("broken map".utf8)
        try corrupt.write(to: map)
        await #expect(throws: MateAgentConversationError.self) {
            try await fixture.client().analyzeImageStreaming(images: [], systemPrompt: "Rules",
                conversationHistory: [], userPrompt: "first", onTextChunk: { _ in })
        }
        #expect(fixture.peers.isEmpty)
        #expect(try Data(contentsOf: map) == corrupt)
    }

    @Test func explicitImageIsAttachedBeforePromptSubmission() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6p8AAAAASUVORK5CYII=")!
        _ = try await fixture.client().analyzeImageStreaming(images: [(png, "user.png")],
            systemPrompt: "Rules", conversationHistory: [], userPrompt: "Describe attachment", onTextChunk: { _ in })
        let methods = try #require(fixture.peers.first?.methods)
        let image = try #require(methods.firstIndex(of: "image.attach_bytes"))
        let prompt = try #require(methods.firstIndex(of: "prompt.submit"))
        #expect(image < prompt)
    }

    @Test func incompleteAnswerFailsAndRetainsDurableSessionForRecovery() async throws {
        let fixture = try Fixture(outcome: "interrupted")
        defer { fixture.cleanup() }
        do {
            _ = try await fixture.client().analyzeImageStreaming(images: [], systemPrompt: "Rules",
                conversationHistory: [], userPrompt: "Check work", onTextChunk: { _ in })
            Issue.record("Interrupted turn reported success")
        } catch {
            #expect(error.localizedDescription.contains("interrupted") || error.localizedDescription.contains("complete"))
        }
        #expect(try fixture.store.sessionID(chatID: fixture.chatID, profile: fixture.profile) == "stored-test-session")
        #expect(fixture.peers.count == 1)
    }

    @Test func cancelledClientWaitsForInterruptionAndKeepsRecoveryIdentity() async throws {
        let fixture = try Fixture(outcome: "wait")
        defer { fixture.cleanup() }
        let client = fixture.client()
        let turn = Task {
            try await client.analyzeImageStreaming(images: [], systemPrompt: "Rules",
                conversationHistory: [], userPrompt: "Check work", onTextChunk: { _ in })
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while fixture.peers.first?.methods.contains("prompt.submit") != true {
            guard ContinuousClock.now < deadline else { throw MateAgentServeWebSocket.Failure.timedOut }
            await Task.yield()
        }
        turn.cancel()
        await #expect(throws: CancellationError.self) { try await turn.value }
        #expect(fixture.peers.first?.methods.contains("session.interrupt") == true)
        #expect(try fixture.store.sessionID(chatID: fixture.chatID, profile: fixture.profile) == "stored-test-session")
    }

    @Test func typedFollowUpSteersRunningTurnWithoutInterrupting() async throws {
        let fixture = try Fixture(outcome: "wait")
        defer { fixture.cleanup() }
        let client = fixture.client()
        #expect(client.canSteer == false)
        let turn = Task {
            try await client.analyzeImageStreaming(images: [], systemPrompt: "Rules",
                conversationHistory: [], userPrompt: "Check work", onTextChunk: { _ in })
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !client.canSteer {
            guard ContinuousClock.now < deadline else { throw MateAgentServeWebSocket.Failure.timedOut }
            await Task.yield()
        }
        try await client.steer("Also check the second file")
        #expect(try await turn.value.text == "Verified answer")
        #expect(fixture.peers.first?.prompts == ["Check work", "Also check the second file"])
        #expect(fixture.peers.first?.methods.contains("session.interrupt") == false)
        #expect(client.canSteer == false)
        await #expect(throws: MateAgentServeSession.Failure.busy) { try await client.steer("Late") }
    }

    @Test(arguments: ["approval", "clarify"])
    func nativeRequestBridgeReceivesOwnedRequestAndReturnsAnswer(method: String) async throws {
        let fixture = try Fixture(outcome: method)
        defer { fixture.cleanup() }
        var requests: [MateAgentServeSession.ServerRequest] = []
        var withdrawn: [UUID] = []
        let client = fixture.client(respond: { request in
            requests.append(request)
            if request.method == "approval" { return .object(["choice": .string("once"), "all": .bool(false)]) }
            return .object(["answers": .object(["color": .string("blue")])])
        }, withdraw: { withdrawn.append($0) })
        _ = try await client.analyzeImageStreaming(images: [], systemPrompt: "Rules", conversationHistory: [],
            userPrompt: "Check work", onTextChunk: { _ in })
        #expect(requests.count == 1)
        #expect(requests.first?.method == method)
        #expect(requests.first?.sessionID == "runtime-test-session")
        #expect(withdrawn == requests.map(\.localID))
        let expected: JSONValue = method == "approval"
            ? .object(["choice": .string("once"), "all": .bool(false)])
            : .object(["answers": .object(["color": .string("blue")])])
        #expect(fixture.peers.first?.requestReplies == [expected])
    }

    @Test(arguments: ["complete", "error", "interrupted"])
    func coldRecoveredWorkBlocksFreshSubmissionAndReportsExactOutcome(status: String) async throws {
        let fixture = try Fixture(outcome: "priorwork")
        defer { fixture.cleanup() }
        try fixture.store.save(sessionID: "stored-test-session", chatID: fixture.chatID, profile: fixture.profile)
        _ = try fixture.ledger.begin(chatID: fixture.chatID, profile: fixture.profile, checkpoint: .init(
            identity: .init(runtimeID: "runtime-test-session", storedID: "stored-test-session"), epoch: "test-epoch", lastSequence: 0))
        let client = fixture.client()
        var pending: [Bool] = []
        var recovered: [MateAgentServeTurnLedger.Delivery] = []
        client.onRecoveredWorkChanged = { pending.append($0) }
        client.onRecoveredResult = { recovered.append($0) }
        await #expect(throws: MateAgentServeSession.Failure.priorWorkRunning) {
            try await client.analyzeImageStreaming(images: [], systemPrompt: "Rules", conversationHistory: [],
                userPrompt: "New instruction", onTextChunk: { _ in })
        }
        #expect(pending == [true])
        #expect(fixture.peers.first?.methods.contains("prompt.submit") == false)
        #expect(fixture.peers.first?.methods.contains("session.interrupt") == false)
        fixture.peers.first?.event("message.complete", .object([
            "status": .string(status), "text": .string("Earlier task outcome"), "error": .string("Earlier task outcome")
        ]))
        #expect(pending == [true, false])
        #expect(recovered.first?.status == status)
        #expect(recovered.first?.text == "Earlier task outcome")
    }

    @Test func completionDuringAppDownReplaysWithoutResubmissionAndDeliverySurvivesCrashGap() async throws {
        let fixture = try Fixture(outcome: "recovered")
        defer { fixture.cleanup() }
        try fixture.store.save(sessionID: "stored-test-session", chatID: fixture.chatID, profile: fixture.profile)
        let pending = try fixture.ledger.begin(chatID: fixture.chatID, profile: fixture.profile, checkpoint: .init(
            identity: .init(runtimeID: "runtime-test-session", storedID: "stored-test-session"), epoch: "test-epoch", lastSequence: 0))
        try fixture.ledger.markAccepted(chatID: fixture.chatID, profile: fixture.profile, userRowID: 7)
        var deliveries: [MateAgentServeTurnLedger.Delivery] = []
        let recovered = fixture.client()
        recovered.onRecoveredResult = { deliveries.append($0) }
        try await recovered.recoverPendingWork()
        #expect(deliveries.first?.id == pending.id)
        #expect(deliveries.first?.text == "Completed while the app was down")
        #expect(fixture.peers.first?.methods.contains("prompt.submit") == false)
        #expect(try fixture.ledger.record(chatID: fixture.chatID, profile: fixture.profile).pending == nil)

        // Simulate a crash after native delivery but before acknowledgement:
        // the same stable key is replayed, so native history can deduplicate it.
        let reopened = fixture.client()
        reopened.onRecoveredResult = { deliveries.append($0) }
        try await reopened.recoverPendingWork()
        #expect(deliveries.count == 2)
        #expect(deliveries[0].key == deliveries[1].key)
        #expect(fixture.peers.count == 1)
        try reopened.acknowledgeDelivery(pending.id)
        let acknowledged = fixture.client()
        acknowledged.onRecoveredResult = { _ in Issue.record("Acknowledged result was delivered again") }
        try await acknowledged.recoverPendingWork()
        #expect(fixture.peers.count == 1)
    }

    @Test(arguments: [true, false])
    func freshConversationRequiresConfirmedOwnerShutdownAndArchivesUnknownWork(shutdownConfirmed: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.store.save(sessionID: "stored-test-session", chatID: fixture.chatID, profile: fixture.profile)
        let pending = try fixture.ledger.begin(chatID: fixture.chatID, profile: fixture.profile, checkpoint: .init(
            identity: .init(runtimeID: "runtime-test-session", storedID: "stored-test-session"), epoch: "old-epoch", lastSequence: 3))
        var shutdownCalls = 0
        let client = fixture.client(shutdownOwner: { shutdownCalls += 1; return shutdownConfirmed })
        if shutdownConfirmed {
            try await client.startNewConversationAfterUnverifiedRecovery()
            #expect(try fixture.store.sessionID(chatID: fixture.chatID, profile: fixture.profile) == nil)
            let record = try fixture.ledger.record(chatID: fixture.chatID, profile: fixture.profile)
            #expect(record.pending == nil)
            #expect(record.deliveries.first?.id == pending.id)
            #expect(record.deliveries.first?.status == "unverified")
            #expect(record.deliveries.first?.sessionID == "stored-test-session")
            #expect(record.needsFreshSession == false)
        } else {
            await #expect(throws: MateAgentServeSession.Failure.cancellationUnconfirmed) {
                try await client.startNewConversationAfterUnverifiedRecovery()
            }
            #expect(try fixture.store.sessionID(chatID: fixture.chatID, profile: fixture.profile) == "stored-test-session")
            #expect(try fixture.ledger.record(chatID: fixture.chatID, profile: fixture.profile).pending?.id == pending.id)
        }
        #expect(shutdownCalls == 1)
        #expect(fixture.peers.isEmpty)
    }

    @Test func gmailBridgeUsesBundledNodeWithoutSystemRuntime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mateAgent-node-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let node = root.appendingPathComponent("node")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: node)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: node.path)
        let runtime = MateAgentServeConversationClient.bridgeRuntime(environment: ["HEYMATE_AGENT_RUNTIME_DIR": root.path], fallback: { nil })
        #expect(runtime == node)
        try FileManager.default.removeItem(at: node)
        #expect(MateAgentServeConversationClient.bridgeRuntime(environment: ["HEYMATE_AGENT_RUNTIME_DIR": root.path], fallback: { nil }) == nil)
        #expect(MateAgentServeConversationClient.bridgeRuntime(environment: [:], fallback: { node }) == node)
    }

    @Test func gmailClaimsRequireMatchingSuccessfulActionReceipts() {
        let args: [String: Any] = ["tools": [["tool_slug": "GMAIL_UPDATE_DRAFT"]]]
        let success = #"{"results":[{"tool_slug":"GMAIL_UPDATE_DRAFT","response":{"successful":true,"data":{"id":"draft-123"}}}]}"#
        let failed = #"{"results":[{"tool_slug":"GMAIL_UPDATE_DRAFT","response":{"successful":false,"data":{"id":"draft-123"}}}]}"#
        let evidence = MateAgentGmailVerification.verifiedActions(tool: "COMPOSIO_MULTI_EXECUTE_TOOL", arguments: args, result: success)
        #expect(evidence == ["draft": ["draft-123"]])
        #expect(MateAgentGmailVerification.verifiedActions(tool: "COMPOSIO_MULTI_EXECUTE_TOOL", arguments: args, result: failed).isEmpty)
        #expect(MateAgentGmailVerification.verifiedActions(tool: "COMPOSIO_SEARCH_TOOLS", arguments: [:], result: success).isEmpty)
        #expect(MateAgentGmailVerification.checkedReply("Both Gmail drafts are updated.", verifiedActions: [:]).contains("couldn't verify"))
        #expect(MateAgentGmailVerification.checkedReply("Both Gmail drafts are updated.", verifiedActions: evidence).contains("couldn't verify"))
        #expect(MateAgentGmailVerification.checkedReply("The Gmail draft is updated.", verifiedActions: evidence) == "The Gmail draft is updated.")
        #expect(MateAgentGmailVerification.checkedReply("I sent the email.", verifiedActions: evidence).contains("couldn't verify"))
        #expect(MateAgentGmailVerification.checkedReply("I haven't sent anything.", verifiedActions: [:]) == "I haven't sent anything.")
        #expect(MateAgentGmailVerification.checkedReply("I'll update the drafts.", verifiedActions: [:]) == "I'll update the drafts.")
        #expect(MateAgentGmailVerification.checkedReply("I created two Gmail drafts.", verifiedActions: [:]).contains("couldn't verify"))
        #expect(MateAgentGmailVerification.checkedReply("I created a draft report.", verifiedActions: [:]) == "I created a draft report.")
        let oneDraftWithMessage = #"{"results":[{"tool_slug":"GMAIL_UPDATE_DRAFT","response":{"successful":true,"data":{"id":"draft-123","message":{"id":"message-456"}}}}]}"#
        #expect(MateAgentGmailVerification.verifiedActions(tool: "COMPOSIO_MULTI_EXECUTE_TOOL", arguments: args, result: oneDraftWithMessage)["draft"]?.count == 1)
    }

    @Test func seedHistoryKeepsBothRolesNewestFirstWithinBudgetAndSkipsCurrentRequest() {
        func message(_ role: ChatRole, _ text: String) -> ChatMessage {
            ChatMessage(id: UUID(), role: role, text: text, createdAt: Date())
        }
        var messages = [message(.user, "remember: https://getheymate.vercel.app/ is our landing page"),
                        message(.assistant, "Noted the landing page")]
        messages += (0..<70).map { message($0.isMultiple(of: 2) ? .user : .assistant, "Turn \($0)") }
        messages.append(message(.user, "Send it"))
        let rows = MateAgentServeConversationClient.seedRows(messages: messages, request: "Send it")
        #expect(rows.count == 60)
        #expect(rows.last == .object(["role": .string("assistant"), "content": .string("Turn 69")]))
        #expect(!rows.contains(.object(["role": .string("user"), "content": .string("Send it")])))
        let long = (0..<40).map { message(.user, String(repeating: "x", count: 9_000) + "\($0)") }
        let bounded = MateAgentServeConversationClient.seedRows(messages: long, request: "")
        #expect(bounded.count == 25)
        #expect(MateAgentServeConversationClient.turnPrompt(request: "Send it", contextNote: "") == "Send it")
        #expect(MateAgentServeConversationClient.turnPrompt(request: "Send it", contextNote: "No screen") == "No screen\n\nSend it")
    }

    @Test func instructionsAndSeedTravelSeparatelyFromThePlainUserMessage() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let client = fixture.client()
        client.seedMessages = [ChatMessage(id: UUID(), role: .user, text: "Earlier", createdAt: Date()),
                               ChatMessage(id: UUID(), role: .assistant, text: "Earlier reply", createdAt: Date())]
        _ = try await client.analyzeImageStreaming(images: [], systemPrompt: "MATE IDENTITY", conversationHistory: [],
            userPrompt: "Plain request", onTextChunk: { _ in })
        let submit = try #require(fixture.peers.first?.submits.first)
        #expect(submit["text"] == .string("Plain request"))
        #expect(submit["system"] == .string("MATE IDENTITY"))
        #expect(submit["seed"] == .array([.object(["role": .string("user"), "content": .string("Earlier")]),
                                          .object(["role": .string("assistant"), "content": .string("Earlier reply")])]))
    }

    @Test func bridgeRefreshPrecedesPromptAndContainsNoAuthenticationSecrets() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let client = fixture.client()
        // Fake gateway validates setup ordering; no app account or model is contacted.
        client.connectorScope = UUID().uuidString
        _ = try await client.analyzeImageStreaming(images: [], systemPrompt: "Rules", conversationHistory: [],
            userPrompt: "Check Gmail", onTextChunk: { _ in })
        let peer = try #require(fixture.peers.first)
        let methods = peer.methods
        #expect(try #require(methods.firstIndex(of: "mcp.servers.add")) < #require(methods.firstIndex(of: "reload.mcp")))
        #expect(try #require(methods.firstIndex(of: "mcp.servers.test")) < #require(methods.firstIndex(of: "prompt.submit")))
        #expect(methods.last == "mcp.servers.remove")
    }

    @Test func emptyBridgeDiscoveryBlocksModelSubmissionWithoutClaimingAccountDisconnected() async throws {
        let fixture = try Fixture(outcome: "bridgeempty")
        defer { fixture.cleanup() }
        let client = fixture.client()
        client.connectorScope = UUID().uuidString
        do {
            _ = try await client.analyzeImageStreaming(images: [], systemPrompt: "Rules", conversationHistory: [],
                userPrompt: "Send email", onTextChunk: { _ in })
            Issue.record("Empty connector discovery submitted a model turn")
        } catch {
            #expect(error.localizedDescription.contains("could not discover"))
            #expect(!error.localizedDescription.contains("disconnected"))
        }
        #expect(fixture.peers.first?.methods.contains("prompt.submit") == false)
        #expect(fixture.peers.first?.methods.last == "mcp.servers.remove")
        #expect(try fixture.ledger.record(chatID: fixture.chatID, profile: fixture.profile).pending == nil)
    }

    @Test func unverifiedGmailClaimNeverStreamsOrPersistsAsSuccess() async throws {
        let fixture = try Fixture(outcome: "falsegmail")
        defer { fixture.cleanup() }
        let client = fixture.client()
        client.verifyReply = { MateAgentGmailVerification.checkedReply($0, verifiedActions: [:]) }
        var chunks: [String] = []
        let response = try await client.analyzeImageStreaming(images: [], systemPrompt: "Rules", conversationHistory: [],
            userPrompt: "Update drafts", onTextChunk: { chunks.append($0) })
        #expect(chunks.isEmpty)
        #expect(response.text.contains("couldn't verify"))
        #expect(client.latestDelivery?.text == response.text)
    }

    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-sessions-client-\(UUID())", isDirectory: true)
        let chatID = UUID()
        var profile: URL { root.appendingPathComponent("profile", isDirectory: true) }
        var storeRoot: URL { root.appendingPathComponent("store", isDirectory: true) }
        var store: MateAgentChatSessionStore { MateAgentChatSessionStore(root: storeRoot) }
        var ledger: MateAgentServeTurnLedger { MateAgentServeTurnLedger(root: storeRoot) }
        var peers: [Peer] = []
        let outcome: String
        init(outcome: String = "complete") throws {
            self.outcome = outcome
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        }
        func client(respond: @escaping @MainActor (MateAgentServeSession.ServerRequest) async -> JSONValue? = { _ in nil },
                    withdraw: @escaping @MainActor (UUID) -> Void = { _ in },
                    shutdownOwner: @escaping @MainActor () async -> Bool = { true }) -> MateAgentServeConversationClient {
            MateAgentServeConversationClient(chatID: chatID, store: store, ledger: ledger, configuration: {
                MateAgentEngineLaunchConfiguration(executableURL: URL(fileURLWithPath: "/bin/sh"),
                    profileDirectoryURL: self.profile, environment: [:])
            }, openSession: { _ in
                let peer = Peer(workspace: try self.store.workspace(chatID: self.chatID), outcome: self.outcome)
                self.peers.append(peer)
                return MateAgentServeSession(connection: peer.socket)
            }, respond: respond, withdraw: withdraw, shutdownOwner: shutdownOwner)
        }
        func cleanup() {
            peers.forEach { $0.socket.close() }
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor
    private final class Peer {
        let workspace: URL
        let outcome: String
        var methods: [String] = []
        var prompts: [String] = []
        var submits: [[String: JSONValue]] = []
        var requestReplies: [JSONValue] = []
        init(workspace: URL, outcome: String) { self.workspace = workspace; self.outcome = outcome }
        lazy var socket: MateAgentServeWebSocket = {
            let socket = MateAgentServeWebSocket(write: { [weak self] message in
                guard let self, case .object(let fields) = message, let id = fields["id"] else { return }
                if id == .string("native-request"), let result = fields["result"] {
                    self.requestReplies.append(result)
                    self.event("message.complete", .object(["text": .string("Verified answer"), "status": .string("complete")]))
                    return
                }
                guard case .string(let method) = fields["method"] else { return }
                self.methods.append(method)
                switch method {
                case "client.capabilities": self.reply(id, .emptyObject)
                case "session.create", "session.resume":
                    self.reply(id, .object(["session_id": .string("runtime-test-session"),
                        "stored_session_id": .string("stored-test-session"), "session_key": .string("stored-test-session"),
                        "running": .bool(self.outcome == "priorwork"), "status": .string(self.outcome == "priorwork" ? "running" : "idle"),
                        "info": .object(["desktop_contract": .number(8), "cwd": .string(self.workspace.path)])]))
                case "session.events.since":
                    let events: [JSONValue] = self.outcome == "recovered" ? [.object([
                        "session_id": .string("runtime-test-session"), "seq": .number(1), "type": .string("message.complete"),
                        "payload": .object(["text": .string("Completed while the app was down"), "status": .string("complete")])
                    ])] : []
                    self.reply(id, .object(["events": .array(events), "latest_seq": .number(events.isEmpty ? 0 : 1), "truncated": .bool(false),
                        "epoch": .string("test-epoch"), "open_requests": .array([])]))
                case "image.attach_bytes":
                    self.reply(id, .object(["attached": .bool(true)]))
                case "mcp.servers.add": self.reply(id, .object(["ok": .bool(true)]))
                case "reload.mcp": self.reply(id, .object(["status": .string("reloaded")]))
                case "mcp.servers.test": self.reply(id, .object(["ok": .bool(true), "tools": .array(self.outcome == "bridgeempty" ? [] : [.object(["name": .string("COMPOSIO_SEARCH_TOOLS")])])]))
                case "prompt.submit":
                    if case .object(let params) = fields["params"] {
                        self.submits.append(params)
                        if case .string(let text) = params["text"] { self.prompts.append(text) }
                    }
                    self.reply(id, .object(["status": .string("streaming")]))
                    self.event("tool.started", .object(["name": .string("terminal")]))
                    self.event("subagent.started", .object(["name": .string("Researcher")]))
                    self.event("message.delta", .object(["text": .string("Verified ")]))
                    self.event("message.delta", .object(["text": .string("answer")]))
                    if ["approval", "clarify"].contains(self.outcome) {
                        var params: [String: JSONValue] = ["session_id": .string("runtime-test-session")]
                        if self.outcome == "approval" {
                            params["choices"] = .array([.string("once"), .string("deny")])
                            params["command"] = .string("Create requested file")
                        } else {
                            params["questions"] = .array([.object(["qid": .string("color"), "question": .string("Which color?")])])
                        }
                        self.socket.receive(.object(["jsonrpc": .string("2.0"), "id": .string("native-request"),
                            "method": .string(self.outcome), "params": .object(params)]))
                    } else if self.outcome != "wait" {
                        self.event("message.complete", .object(["text": .string(self.outcome == "falsegmail" ? "Both Gmail drafts are updated." : "Verified answer"), "status": .string(self.outcome == "falsegmail" ? "complete" : self.outcome)]))
                    }
                case "session.steer":
                    if case .object(let params) = fields["params"], case .string(let text) = params["text"] { self.prompts.append(text) }
                    self.reply(id, .object(["status": .string("queued"), "user_row_id": .number(2)]))
                    self.event("message.complete", .object(["text": .string("Verified answer"), "status": .string("complete")]))
                case "session.interrupt":
                    self.reply(id, .object(["status": .string("interrupted")]))
                    self.event("message.complete", .object(["status": .string("interrupted"), "text": .string("")]))
                case "session.info":
                    self.reply(id, .object(["status": .string("idle"), "streaming": .bool(false)]))
                default: self.reply(id, .emptyObject)
                }
            })
            socket.connect()
            return socket
        }()
        func reply(_ id: JSONValue, _ value: JSONValue) {
            socket.receive(.object(["jsonrpc": .string("2.0"), "id": id, "result": value]))
        }
        func event(_ type: String, _ payload: JSONValue) {
            socket.receive(.object(["jsonrpc": .string("2.0"), "method": .string("event"),
                "params": .object(["session_id": .string("runtime-test-session"), "type": .string(type), "payload": payload])]))
        }
    }
}
