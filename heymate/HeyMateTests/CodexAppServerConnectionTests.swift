import Foundation
import Testing
@testable import HeyMate

@MainActor
struct CodexAppServerConnectionTests {
    @MainActor
    private final class Peer {
        let connection = CodexAppServerConnection()
        var sent: [[String: JSONValue]] = []
        var stops = 0
        var acceptsWrites = true
        var respondsToInitialize = true

        func connect(timeout: Duration = .seconds(1)) async throws {
            try await connection.connect(write: { [weak self] data in
                guard let self, self.acceptsWrites,
                      let value = try? JSONDecoder().decode(JSONValue.self, from: data),
                      case .object(let fields) = value else { return false }
                self.sent.append(fields)
                if self.respondsToInitialize, fields["method"] == .string("initialize"), let id = fields["id"] {
                    self.deliver(.object(["id": id, "result": .emptyObject]))
                }
                return true
            }, stop: { [weak self] in self?.stops += 1 }, timeout: timeout)
        }

        func deliver(_ value: JSONValue) {
            let data = try! JSONEncoder().encode(value)
            connection.receive(String(decoding: data, as: UTF8.self))
        }

        func waitForMessages(_ count: Int) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while sent.count < count {
                guard ContinuousClock.now < deadline else { throw CodexAppServerConnection.Failure.timedOut }
                await Task.yield()
            }
        }
    }

    @Test func handshakeGatesRequestsAndCannotRepeat() async throws {
        let peer = Peer()
        await #expect(throws: CodexAppServerConnection.Failure.notReady) {
            try await peer.connection.request(method: "thread/start")
        }
        try await peer.connect()
        #expect(peer.sent.map { $0["method"] } == [.string("initialize"), .string("initialized")])
        await #expect(throws: CodexAppServerConnection.Failure.alreadyStarted) { try await peer.connect() }
        peer.connection.close()
        peer.connection.close()
        #expect(peer.stops == 1)
    }

    @Test func interleavedNotificationsAndOutOfOrderRepliesKeepOwnership() async throws {
        let peer = Peer()
        try await peer.connect()
        var notifications: [String] = []
        peer.connection.onNotification = { method, _ in notifications.append(method) }
        let first = Task { try await peer.connection.request(method: "thread/start") }
        try await peer.waitForMessages(3)
        let firstID = try #require(peer.sent[2]["id"])
        let second = Task { try await peer.connection.request(method: "turn/start") }
        try await peer.waitForMessages(4)
        let secondID = try #require(peer.sent[3]["id"])
        peer.deliver(.object(["method": .string("turn/started"), "params": .emptyObject]))
        peer.deliver(.object(["id": .string("late-unowned-id"), "result": .bool(false)]))
        peer.deliver(.object(["id": secondID, "result": .null]))
        peer.deliver(.object(["id": firstID, "result": .string("owned-thread")]))
        #expect(try await second.value == .null)
        #expect(try await first.value == .string("owned-thread"))
        #expect(notifications == ["turn/started"])
        peer.connection.close()
    }

    @Test func unsupportedApprovalRequestsAreRejectedWithOriginalID() async throws {
        let peer = Peer()
        try await peer.connect()
        peer.deliver(.object(["id": .number(42), "method": .string("item/commandExecution/requestApproval"),
                              "params": .emptyObject]))
        #expect(peer.sent.last?["id"] == .number(42))
        guard case .object(let error) = peer.sent.last?["error"] else { Issue.record("Missing rejection"); return }
        #expect(error["code"] == .number(-32601))
        #expect(peer.sent.last?["result"] == nil)
        peer.connection.close()
    }

    @Test func timeoutAndCancellationDoNotPoisonNextRequest() async throws {
        let peer = Peer()
        try await peer.connect()
        await #expect(throws: CodexAppServerConnection.Failure.timedOut) {
            try await peer.connection.request(method: "slow", timeout: .milliseconds(10))
        }
        let cancelled = Task { try await peer.connection.request(method: "cancelled") }
        try await peer.waitForMessages(4)
        let cancelledID = try #require(peer.sent.last?["id"])
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        peer.deliver(.object(["id": cancelledID, "result": .bool(true)]))
        let next = Task { try await peer.connection.request(method: "next") }
        try await peer.waitForMessages(5)
        peer.deliver(.object(["id": try #require(peer.sent.last?["id"]), "result": .string("next")]))
        #expect(try await next.value == .string("next"))
        peer.connection.close()
    }

    @Test func eofFailsAllPendingRequestsAndStopsOnce() async throws {
        let peer = Peer()
        try await peer.connect()
        let first = Task { try await peer.connection.request(method: "one") }
        let second = Task { try await peer.connection.request(method: "two") }
        try await peer.waitForMessages(4)
        peer.connection.close()
        await #expect(throws: CodexAppServerConnection.Failure.closed) { try await first.value }
        await #expect(throws: CodexAppServerConnection.Failure.closed) { try await second.value }
        #expect(peer.stops == 1)
    }

    @Test func ambiguousOrInvalidMessagesCloseConnection() async throws {
        let invalid: [JSONValue] = [
            .object(["id": .string("x"), "result": .null, "error": .emptyObject]),
            .object(["id": .number(1.5), "method": .string("approval")]),
            .object(["method": .string("notification"), "result": .null]),
            .array([])
        ]
        for message in invalid {
            let peer = Peer()
            try await peer.connect()
            let pending = Task { try await peer.connection.request(method: "pending") }
            try await peer.waitForMessages(3)
            peer.deliver(message)
            await #expect(throws: CodexAppServerConnection.Failure.malformedMessage) { try await pending.value }
            #expect(peer.stops == 1)
        }
    }

    @Test func remoteErrorsPreserveCodeAndMessage() async throws {
        let peer = Peer()
        try await peer.connect()
        let request = Task { try await peer.connection.request(method: "turn/steer") }
        try await peer.waitForMessages(3)
        peer.deliver(.object(["id": try #require(peer.sent.last?["id"]), "error": .object([
            "code": .number(-32000), "message": .string("No active turn")
        ])]))
        await #expect(throws: CodexAppServerConnection.Failure.remote(code: -32000, message: "No active turn")) {
            try await request.value
        }
        peer.connection.close()
    }

    @Test func initializationTimeoutAndWriteFailureCloseOwnedTransport() async throws {
        let stalled = Peer()
        stalled.respondsToInitialize = false
        await #expect(throws: CodexAppServerConnection.Failure.timedOut) {
            try await stalled.connect(timeout: .milliseconds(10))
        }
        #expect(stalled.stops == 1)
        let broken = Peer()
        broken.acceptsWrites = false
        await #expect(throws: CodexAppServerConnection.Failure.writeFailed) { try await broken.connect() }
        #expect(broken.stops == 1)
    }

    @Test func droppingConnectionStopsIdleOwnedTransport() async throws {
        var stops = 0
        var connection: CodexAppServerConnection? = CodexAppServerConnection()
        weak var observer = connection
        try await connection?.connect(write: { [weak connection] data in
            let value = try! JSONDecoder().decode(JSONValue.self, from: data)
            if case .object(let fields) = value, fields["method"] == .string("initialize"), let id = fields["id"] {
                let reply = try! JSONEncoder().encode(JSONValue.object(["id": id, "result": .emptyObject]))
                connection?.receive(String(decoding: reply, as: UTF8.self))
            }
            return true
        }, stop: { stops += 1 })
        connection = nil
        #expect(observer == nil)
        #expect(stops == 1)
    }

    @Test func ownedStdioProcessReassemblesSplitUTF8AndKeepsStderrSeparate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("heymate-rpc-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-codex")
        let script = #"""
        #!/usr/bin/python3
        import json, os, sys
        assert sys.argv[1:] == ['app-server', '--listen', 'stdio://']
        print('stderr must not enter JSON parser', file=sys.stderr, flush=True)
        def reply(value):
            data = (json.dumps(value, ensure_ascii=False) + '\n').encode('utf-8')
            # Split every byte, including multibyte UTF-8, across pipe writes.
            for byte in data:
                os.write(1, bytes([byte]))
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get('method')
            if method == 'initialize':
                reply({'id': message['id'], 'result': {}})
            elif method == 'ping':
                reply({'method': 'test/notification', 'params': {'text': '✅'}})
                reply({'id': message['id'], 'result': 'owned ✅'})
            elif method == 'breakProtocol':
                print('invalid JSON', flush=True)
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let connection = CodexAppServerConnection()
        var notification: JSONValue?
        connection.onNotification = { _, params in notification = params }
        do {
            try await connection.launch(executableURL: executable, workspaceURL: directory)
            #expect(try await connection.request(method: "ping") == .string("owned ✅"))
            #expect(notification == .object(["text": .string("✅")]))
            await #expect(throws: CodexAppServerConnection.Failure.malformedMessage) {
                try await connection.request(method: "breakProtocol")
            }
            #expect(await connection.shutdown())
        } catch {
            _ = await connection.shutdown()
            throw error
        }
    }

    @Test func serverIntegerIDsPreserveAll64BitsWhenRejectingRequests() async throws {
        let connection = CodexAppServerConnection()
        var output: [Data] = []
        try await connection.connect(write: { [weak connection] data in
            output.append(data)
            let value = try! JSONDecoder().decode(JSONValue.self, from: data)
            if case .object(let fields) = value, fields["method"] == .string("initialize"), let id = fields["id"] {
                let reply = try! JSONEncoder().encode(JSONValue.object(["id": id, "result": .emptyObject]))
                connection?.receive(String(decoding: reply, as: UTF8.self))
            }
            return true
        }, stop: {})
        connection.receive(#"{"id":9223372036854775807,"result":null}"#)
        connection.receive(#"{"id":9223372036854775807,"method":"approval"}"#)
        struct ExactReply: Decodable { let id: Int64 }
        #expect(try JSONDecoder().decode(ExactReply.self, from: #require(output.last)).id == Int64.max)
        connection.close()
    }
}
