import Foundation
import Testing
@testable import HeyMate

@MainActor
struct HermesACPTests {
    @MainActor
    private final class Peer {
        let connection = HermesACPConnection()
        var sent: [[String: JSONValue]] = []
        var stops = 0
        var acceptsWrites = true

        func connect() async throws {
            try await connection.connect(write: { [weak self] data in
                guard let self, self.acceptsWrites, let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                      case .object(let fields) = value else { return false }
                self.sent.append(fields)
                if fields["method"] == .string("initialize"), let id = fields["id"] {
                    self.deliver(["id": id, "result": .object(["protocolVersion": .number(1)])])
                }
                return true
            }, stop: { [weak self] in self?.stops += 1 })
        }
        func deliver(_ fields: [String: JSONValue]) {
            var fields = fields
            fields["jsonrpc"] = .string("2.0")
            connection.receive(String(decoding: try! JSONEncoder().encode(JSONValue.object(fields)), as: UTF8.self))
        }
        func waitForMessages(_ count: Int) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while sent.count < count {
                guard ContinuousClock.now < deadline else { throw HermesACPConnection.Failure.timedOut }
                await Task.yield()
            }
        }
    }

    @Test func initializeUsesACPProtocolAndNoUnsupportedInitializedNotification() async throws {
        let peer = Peer()
        try await peer.connect()
        #expect(peer.sent.count == 1)
        #expect(peer.sent.first?["jsonrpc"] == .string("2.0"))
        guard case .object(let params) = peer.sent.first?["params"] else { Issue.record("Missing initialize params"); return }
        #expect(params["protocolVersion"] == .number(1))
        #expect(params["clientCapabilities"] == .object([
            "fs": .object(["readTextFile": .bool(false), "writeTextFile": .bool(false)]), "terminal": .bool(false)
        ]))
        peer.deliver(["id": .number(13), "method": .string("fs/read_text_file"),
                      "params": .object(["path": .string("/etc/passwd")])])
        guard case .object(let rejection) = peer.sent.last?["error"] else {
            Issue.record("Unsupported client filesystem request was not rejected"); return
        }
        #expect(rejection["code"] == .number(-32601))
        #expect(peer.sent.last?["id"] == .number(13))
        peer.connection.close()
    }

    @Test func responsesMatchExactIDsAndCloseFailsEveryOutstandingRequest() async throws {
        let peer = Peer()
        try await peer.connect()
        let first = Task { try await peer.connection.request(method: "first") }
        try await peer.waitForMessages(2)
        let firstID = try #require(peer.sent.last?["id"])
        let second = Task { try await peer.connection.request(method: "second") }
        try await peer.waitForMessages(3)
        let secondID = try #require(peer.sent.last?["id"])
        peer.deliver(["id": .string("unowned"), "result": .string("wrong")])
        peer.deliver(["id": secondID, "result": .string("second")])
        #expect(try await second.value == .string("second"))
        peer.deliver(["id": firstID, "result": .string("first")])
        #expect(try await first.value == .string("first"))
        let pendingA = Task { try await peer.connection.request(method: "a") }
        let pendingB = Task { try await peer.connection.request(method: "b") }
        try await peer.waitForMessages(5)
        peer.connection.close()
        peer.connection.close()
        await #expect(throws: HermesACPConnection.Failure.closed) { try await pendingA.value }
        await #expect(throws: HermesACPConnection.Failure.closed) { try await pendingB.value }
        #expect(peer.stops == 1)
    }

    @Test func timeoutCancellationRemoteErrorAndBrokenWriteResolveRequests() async throws {
        let peer = Peer()
        try await peer.connect()
        await #expect(throws: HermesACPConnection.Failure.timedOut) {
            try await peer.connection.request(method: "slow", timeout: .milliseconds(5))
        }
        let cancelled = Task { try await peer.connection.request(method: "cancel") }
        try await peer.waitForMessages(3)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let rejected = Task { try await peer.connection.request(method: "reject") }
        try await peer.waitForMessages(4)
        peer.deliver(["id": try #require(peer.sent.last?["id"]),
                      "error": .object(["code": .number(-32602), "message": .string("Bad arguments")])])
        await #expect(throws: HermesACPConnection.Failure.remote(code: -32602, message: "Bad arguments")) { try await rejected.value }
        peer.acceptsWrites = false
        await #expect(throws: HermesACPConnection.Failure.writeFailed) { try await peer.connection.request(method: "broken") }
        #expect(peer.stops == 1)
    }

    @Test func malformedJSONAndDuplicateServerIDsFailClosed() async throws {
        let peer = Peer()
        try await peer.connect()
        peer.connection.onServerRequest = { _, _, _ in true }
        peer.deliver(["id": .number(42), "method": .string("session/request_permission")])
        peer.deliver(["id": .number(42), "method": .string("session/request_permission")])
        await #expect(throws: HermesACPConnection.Failure.notReady) { try await peer.connection.request(method: "after") }
        #expect(peer.stops == 1)
        let malformed = Peer()
        try await malformed.connect()
        let request = Task { try await malformed.connection.request(method: "pending") }
        try await malformed.waitForMessages(2)
        malformed.connection.receive("{garbled")
        await #expect(throws: HermesACPConnection.Failure.malformedMessage) { try await request.value }
    }

    @Test func fakeExecutableStreamsScopesPermissionsAndReusesSession() async throws {
        let fixture = try Fixture(script: Self.peerScript)
        defer { fixture.cleanup() }
        let connection = HermesACPConnection()
        let session = HermesACPSession(connection: connection)
        defer { connection.close() }
        var chunks: [String] = []
        var tools = 0
        var permissionIDs: [UUID] = []
        session.onMessageChunk = { chunks.append($0) }
        session.onToolUpdate = { _ in tools += 1 }
        session.onPermission = { permission in
            permissionIDs.append(permission.localID)
            #expect(permission.sessionID == "owned-session")
            #expect(permission.options.map(\.id) == ["allow_once", "deny"])
            #expect(throws: HermesACPSession.Failure.invalidPermission) {
                try session.respondToPermission(localID: permission.localID, optionID: "allow_always")
            }
            try! session.respondToPermission(localID: permission.localID, optionID: "allow_once")
        }
        try await connection.launch(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), workspaceURL: fixture.root,
                                    arguments: [fixture.script.path])
        #expect(try await session.new(workspace: fixture.root) == "owned-session")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0])
        let result = try await session.prompt(text: "hello", images: [(png, "screen.png")], timeout: .seconds(5))
        #expect(result == HermesACPSession.PromptResult(text: "Hello world", stopReason: "end_turn"))
        #expect(chunks == ["Hello ", "world"])
        #expect(tools == 1)
        #expect(permissionIDs.count == 1)
        let next = try await session.prompt(text: "again", timeout: .seconds(5))
        #expect(next.text == "Hello world")
        #expect(permissionIDs.count == 2)
        #expect(await connection.shutdown())
    }

    @Test func distinctAssistantMessagesKeepReadableBoundaries() async throws {
        let source = Self.peerScript
            .replacingOccurrences(of: "'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'Hello '",
                                  with: "'sessionUpdate': 'agent_message_chunk', 'messageId': 'before-tool', 'content': {'type': 'text', 'text': 'Hello '")
            .replacingOccurrences(of: "'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'world'",
                                  with: "'sessionUpdate': 'agent_message_chunk', 'messageId': 'after-tool', 'content': {'type': 'text', 'text': 'world'")
        let fixture = try Fixture(script: source)
        defer { fixture.cleanup() }
        let connection = HermesACPConnection()
        let session = HermesACPSession(connection: connection)
        defer { connection.close() }
        try await connection.launch(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), workspaceURL: fixture.root,
                                    arguments: [fixture.script.path])
        _ = try await session.new(workspace: fixture.root)
        let result = try await session.prompt(text: "hello", timeout: .seconds(5))
        #expect(result.text == "Hello \n\nworld")
    }

    @Test func fakeExecutableLoadEnforcesAskModeAndEOFResolvesPrompt() async throws {
        let fixture = try Fixture(script: Self.peerScript)
        defer { fixture.cleanup() }
        let connection = HermesACPConnection()
        let session = HermesACPSession(connection: connection)
        try await connection.launch(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), workspaceURL: fixture.root,
                                    arguments: [fixture.script.path])
        #expect(try await session.load(sessionID: "owned-session", workspace: fixture.root) == "owned-session")
        await #expect(throws: HermesACPConnection.Failure.closed) {
            try await session.prompt(text: "exit", timeout: .seconds(3))
        }
        #expect(await connection.shutdown())
    }

    @Test func fakeExecutableCancelStopsTurnAndRejectsStalePermission() async throws {
        let fixture = try Fixture(script: Self.peerScript)
        defer { fixture.cleanup() }
        let connection = HermesACPConnection()
        let session = HermesACPSession(connection: connection)
        var permission: UUID?
        session.onPermission = { value in permission = value.localID }
        try await connection.launch(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), workspaceURL: fixture.root,
                                    arguments: [fixture.script.path])
        _ = try await session.new(workspace: fixture.root)
        let prompt = Task { try await session.prompt(text: "hello", timeout: .seconds(5)) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while permission == nil {
            guard ContinuousClock.now < deadline else { throw HermesACPConnection.Failure.timedOut }
            await Task.yield()
        }
        let localID = try #require(permission)
        session.cancel()
        await #expect(throws: CancellationError.self) { try await prompt.value }
        #expect(throws: HermesACPSession.Failure.invalidPermission) {
            try session.respondToPermission(localID: localID, optionID: "allow_once")
        }
        #expect(await connection.shutdown())
    }

    @Test func unreadLargePromptCannotBlockTimeoutOrMainActor() async throws {
        let source = Self.peerScript.replacingOccurrences(of: "import json, sys", with: "import json, sys, time")
            .replacingOccurrences(of: "mode_set = True\n        result(req, {})", with: "mode_set = True\n        result(req, {})\n        time.sleep(60)")
        let fixture = try Fixture(script: source)
        defer { fixture.cleanup() }
        let connection = HermesACPConnection()
        let session = HermesACPSession(connection: connection)
        try await connection.launch(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), workspaceURL: fixture.root,
                                    arguments: [fixture.script.path])
        _ = try await session.new(workspace: fixture.root)
        var image = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        image.append(Data(repeating: 0, count: 1_024 * 1_024))
        let started = ContinuousClock.now
        await #expect(throws: HermesACPConnection.Failure.timedOut) {
            try await session.prompt(text: "inspect", images: [(image, "screen.png")], timeout: .milliseconds(20))
        }
        #expect(started.duration(to: .now) < .seconds(3))
        #expect(await connection.shutdown())
    }

    @Test func unknownSessionPermissionsDenyWithoutInvokingApprovalUI() async throws {
        let peer = Peer()
        try await peer.connect()
        let session = HermesACPSession(connection: peer.connection)
        var approvals = 0
        session.onPermission = { _ in approvals += 1 }
        peer.deliver(["id": .string("foreign"), "method": .string("session/request_permission"), "params": .object([
            "sessionId": .string("foreign"), "toolCall": .emptyObject, "options": .array([])
        ])])
        #expect(approvals == 0)
        #expect(peer.sent.last?["id"] == .string("foreign"))
        #expect(peer.sent.last?["result"] == .object(["outcome": .object(["outcome": .string("cancelled")])]))
        peer.connection.close()
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let script: URL
        init(script source: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("heymate-acp-test-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            script = root.appendingPathComponent("peer.py")
            try source.write(to: script, atomically: true, encoding: .utf8)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private static let peerScript = #"""
import json, sys
mode_set = False
pending = None

def send(value):
    value['jsonrpc'] = '2.0'
    text = json.dumps(value) + '\n'
    # Deliberately fragmented frames; reader must preserve JSONL boundaries.
    middle = len(text) // 2
    sys.stdout.write(text[:middle]); sys.stdout.flush()
    sys.stdout.write(text[middle:]); sys.stdout.flush()

def result(req, value):
    send({'id': req['id'], 'result': value})

def update(sid, content):
    send({'method': 'session/update', 'params': {'sessionId': sid, 'update': content}})

for line in sys.stdin:
    req = json.loads(line)
    assert req['jsonrpc'] == '2.0'
    method = req.get('method')
    params = req.get('params', {})
    if method == 'initialize':
        assert params['protocolVersion'] == 1
        assert params['clientCapabilities']['terminal'] is False
        result(req, {'protocolVersion': 1})
    elif method in ['session/new', 'session/load']:
        assert params['mcpServers'] == []
        value = {'modes': {'currentModeId': 'accept_edits', 'availableModes': [{'id': 'default'}]}}
        if method == 'session/new': value['sessionId'] = 'owned-session'
        result(req, value)
    elif method == 'session/set_mode':
        assert params == {'sessionId': 'owned-session', 'modeId': 'default'}
        mode_set = True
        result(req, {})
    elif method == 'session/prompt':
        assert mode_set
        assert params['sessionId'] == 'owned-session'
        if params['prompt'][0]['text'] == 'exit': sys.exit(0)
        update('foreign-session', {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'LEAK'}})
        update('owned-session', {'sessionUpdate': 'agent_thought_chunk', 'content': {'type': 'text', 'text': 'PRIVATE'}})
        update('owned-session', {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'Hello '}})
        update('owned-session', {'sessionUpdate': 'tool_call', 'toolCallId': 'tool-1', 'title': 'Inspect records'})
        pending = req
        send({'id': 42, 'method': 'session/request_permission', 'params': {
            'sessionId': 'owned-session', 'toolCall': {'toolCallId': 'tool-1', 'title': 'Inspect records'},
            'options': [{'optionId': 'allow_once', 'name': 'Allow once', 'kind': 'allow_once'},
                        {'optionId': 'allow_always', 'name': 'Allow always', 'kind': 'allow_always'},
                        {'optionId': 'deny', 'name': 'Reject', 'kind': 'reject_once'}]}})
    elif method == 'session/cancel':
        sys.exit(0)
    elif req.get('id') == 42:
        assert req['result']['outcome']['outcome'] in ['selected', 'cancelled']
        update('owned-session', {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'world'}})
        result(pending, {'stopReason': 'end_turn'})
        pending = None
    else:
        send({'id': req['id'], 'error': {'code': -32601, 'message': 'Unsupported'}})
"""#
}
