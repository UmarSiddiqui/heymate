import Foundation
import Testing
@testable import HeyMate

@MainActor
struct HermesConversationClientTests {
    /// Opt-in provider exercise. Ordinary test runs mark this test disabled;
    /// credentials, provider selection and existing sessions are never copied.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEYMATE_HERMES_LIVE_EXECUTABLE"] != nil
                   && ProcessInfo.processInfo.environment["HEYMATE_HERMES_LIVE_PROFILE"] != nil))
    func livePreparedHermesProfileSmoke() async throws {
        let environment = ProcessInfo.processInfo.environment
        let executable = try #require(environment["HEYMATE_HERMES_LIVE_EXECUTABLE"])
        let profile = try #require(environment["HEYMATE_HERMES_LIVE_PROFILE"])
        let prepared = try HermesEngineConfiguration(executablePath: executable, profilePath: profile)
            .resolveLaunchConfiguration()
        var childEnvironment = prepared.environment
        if let runtime = environment["HEYMATE_HERMES_LIVE_RUNTIME"] {
            guard runtime.hasPrefix("/") else { throw POSIXError(.EINVAL) }
            childEnvironment["HERMES_RUNTIME_DIR"] = runtime
        }
        let launch = HermesEngineLaunchConfiguration(executableURL: prepared.executableURL,
            profileDirectoryURL: prepared.profileDirectoryURL, environment: childEnvironment)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heymate-hermes-live-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HermesChatSessionStore(root: root)
        let chatID = UUID()
        let nonce = "HEYMATE-" + UUID().uuidString
        let first = HermesConversationClient(chatID: chatID, store: store, configuration: { launch }, approve: { _ in nil })
        let remembered = try await first.analyzeImageStreaming(
            images: [], systemPrompt: "This is a harmless session-memory test. Do not use any tools or change files.",
            conversationHistory: [], userPrompt: "Do not use tools. Remember this token only in this conversation: \(nonce). Reply exactly STORED.",
            onTextChunk: { _ in })
        #expect(remembered.text.trimmingCharacters(in: .whitespacesAndNewlines) == "STORED")
        let storedID = try store.sessionID(chatID: chatID, profile: launch.profileDirectoryURL)
        let sessionID = try #require(storedID)
        let reopened = HermesConversationClient(chatID: chatID, store: HermesChatSessionStore(root: root),
                                                configuration: { launch }, approve: { _ in nil })
        let restored = try await reopened.analyzeImageStreaming(
            images: [], systemPrompt: "Do not use any tools or change files.", conversationHistory: [],
            userPrompt: "Do not use tools. Reply only with the exact token I asked you to remember in the previous turn.",
            onTextChunk: { _ in })
        #expect(restored.text.trimmingCharacters(in: .whitespacesAndNewlines) == nonce)
        #expect(try store.sessionID(chatID: chatID, profile: launch.profileDirectoryURL) == sessionID)
    }

    @Test func persistedChatUsesNewThenLoadAndDoesNotImportNativeHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let chatID = UUID()
        let client = fixture.client(chatID: chatID)
        var chunks: [String] = []
        let first = try await client.analyzeImageStreaming(
            images: [], systemPrompt: "Interface instructions", conversationHistory: [("PRIVATE NATIVE QUESTION", "PRIVATE NATIVE ANSWER")],
            userPrompt: "first request", onTextChunk: { chunks.append($0) })
        #expect(first.text == "Verified result")
        #expect(chunks == ["Verified ", "Verified result"])
        let storedID = try fixture.store.sessionID(chatID: chatID, profile: fixture.profile)
        let saved = try #require(storedID)
        #expect(saved == "hermes-test-session")
        let second = try await fixture.client(chatID: chatID).analyzeImageStreaming(
            images: [], systemPrompt: "Changed interface instructions", conversationHistory: [("SECOND PRIVATE QUESTION", "SECOND PRIVATE ANSWER")],
            userPrompt: "follow-up request", onTextChunk: { _ in })
        #expect(second.text == "Verified result")
        let messages = try fixture.messages()
        let methods = messages.compactMap { $0["method"] }
        #expect(methods.filter { $0 == .string("session/new") }.count == 1)
        #expect(methods.filter { $0 == .string("session/load") }.count == 1)
        let prompts = messages.filter { $0["method"] == .string("session/prompt") }
        #expect(prompts.count == 2)
        let encoded = String(decoding: try JSONEncoder().encode(prompts), as: UTF8.self)
        #expect(!encoded.contains("PRIVATE"))
        #expect(encoded.contains("Interface instructions"))
        #expect(!encoded.contains("Changed interface instructions"))
        guard case .object(let params) = prompts.last?["params"], case .array(let blocks) = params["prompt"],
              case .object(let text) = blocks.first else { Issue.record("Missing prompt blocks"); return }
        #expect(text["text"] == .string("follow-up request"))
    }

    @Test func sessionMapScopesChatAndProfileAndPersistsAcrossStoreInstances() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let chat = UUID()
        let otherChat = UUID()
        let otherProfile = fixture.root.appendingPathComponent("other-profile")
        try fixture.store.save(sessionID: "session-a", chatID: chat, profile: fixture.profile)
        try fixture.store.save(sessionID: "session-b", chatID: otherChat, profile: fixture.profile)
        try fixture.store.save(sessionID: "session-c", chatID: chat, profile: otherProfile)
        let reopened = HermesChatSessionStore(root: fixture.storeRoot)
        #expect(try reopened.sessionID(chatID: chat, profile: fixture.profile) == "session-a")
        #expect(try reopened.sessionID(chatID: otherChat, profile: fixture.profile) == "session-b")
        #expect(try reopened.sessionID(chatID: chat, profile: otherProfile) == "session-c")
        #expect(try reopened.sessionID(chatID: UUID(), profile: fixture.profile) == nil)
    }

    @Test(arguments: ["empty", "refusal", "cancelled", "max_tokens"])
    func incompleteResultsFailVisiblyWithoutClaimingCompletion(outcome: String) async throws {
        let fixture = try Fixture(outcome: outcome)
        defer { fixture.cleanup() }
        let client = fixture.client(chatID: UUID())
        do {
            _ = try await client.analyzeImageStreaming(images: [], systemPrompt: "Instructions", conversationHistory: [],
                                                       userPrompt: "Do work", onTextChunk: { _ in })
            Issue.record("Incomplete result was returned as success")
        } catch let error as HermesConversationError {
            if outcome == "empty" { #expect(error.localizedDescription.contains("without an answer")) }
            else { #expect(error.localizedDescription.contains(outcome)) }
        }
    }

    @Test func corruptSessionMapIsNotReplacedAndNoNewSessionStarts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.storeRoot, withIntermediateDirectories: true)
        let map = fixture.storeRoot.appendingPathComponent("sessions.json")
        let corrupt = Data("{broken session map".utf8)
        try corrupt.write(to: map)
        await #expect(throws: HermesConversationError.self) {
            try await fixture.client(chatID: UUID()).analyzeImageStreaming(
                images: [], systemPrompt: "Instructions", conversationHistory: [], userPrompt: "Do work", onTextChunk: { _ in })
        }
        #expect(try Data(contentsOf: map) == corrupt)
        let messages = try fixture.messages()
        #expect(!messages.contains { message in
            guard let method = message["method"] else { return false }
            return [JSONValue.string("session/new"), .string("session/load"), .string("session/prompt")].contains(method)
        })
    }

    @Test func permissionWaitCancellationCancelsApprovalTaskAndNeverAllows() async throws {
        let fixture = try Fixture(outcome: "permission")
        defer { fixture.cleanup() }
        var requested = false
        var approvalCancelled = false
        let client = fixture.client(chatID: UUID(), approve: { _ in
            requested = true
            do { try await ContinuousClock().sleep(for: .seconds(60)) }
            catch { approvalCancelled = true }
            return nil
        })
        let turn = Task {
            try await client.analyzeImageStreaming(images: [], systemPrompt: "Instructions", conversationHistory: [],
                                                    userPrompt: "Do work", onTextChunk: { _ in })
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !requested {
            guard ContinuousClock.now < deadline else { throw HermesACPConnection.Failure.timedOut }
            await Task.yield()
        }
        turn.cancel()
        await #expect(throws: CancellationError.self) { try await turn.value }
        let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !approvalCancelled, ContinuousClock.now < cleanupDeadline { await Task.yield() }
        #expect(approvalCancelled)
        let messages = try fixture.messages()
        let results = messages.compactMap { $0["result"] }
        #expect(!results.contains(.object(["outcome": .object(["outcome": .string("selected"), "optionId": .string("allow_once")])])))
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let profile: URL
        let storeRoot: URL
        let executable: URL
        let trace: URL
        let outcome: String
        var store: HermesChatSessionStore { HermesChatSessionStore(root: storeRoot) }

        init(outcome: String = "end_turn") throws {
            self.outcome = outcome
            root = FileManager.default.temporaryDirectory.appendingPathComponent("heymate-hermes-client-\(UUID())")
            profile = root.appendingPathComponent("profile", isDirectory: true)
            storeRoot = root.appendingPathComponent("store", isDirectory: true)
            executable = root.appendingPathComponent("hermes-fake")
            trace = root.appendingPathComponent("wire.jsonl")
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            try Self.script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        func client(chatID: UUID, approve: @escaping @MainActor (HermesACPSession.Permission) async -> String? = { _ in nil }) -> HermesConversationClient {
            let launch = HermesEngineLaunchConfiguration(executableURL: executable, profileDirectoryURL: profile,
                environment: ["HERMES_HOME": profile.path, "HEYMATE_TEST_TRACE": trace.path, "HEYMATE_TEST_OUTCOME": outcome])
            return HermesConversationClient(chatID: chatID, store: store, configuration: { launch }, approve: approve)
        }
        func messages() throws -> [[String: JSONValue]] {
            guard FileManager.default.fileExists(atPath: trace.path) else { return [] }
            return try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").map {
                guard case .object(let fields) = JSONValue(jsonText: String($0)) else { throw HermesACPConnection.Failure.malformedMessage }
                return fields
            }
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }

        private static let script = #"""
#!/usr/bin/python3
import json, os, sys
outcome = os.environ['HEYMATE_TEST_OUTCOME']
assert os.environ['HERMES_ACP_SKIP_CONFIGURED_MCP'] == '1'
assert os.environ['HERMES_DISABLE_LAZY_INSTALLS'] == '1'

def send(value):
    value['jsonrpc'] = '2.0'
    print(json.dumps(value), flush=True)

def result(req, value):
    send({'id': req['id'], 'result': value})

for line in sys.stdin:
    req = json.loads(line)
    with open(os.environ['HEYMATE_TEST_TRACE'], 'a') as trace:
        trace.write(json.dumps(req) + '\n')
    method = req.get('method')
    if method == 'initialize':
        result(req, {'protocolVersion': 1})
    elif method in ['session/new', 'session/load']:
        assert req['params']['mcpServers'] == []
        response = {'modes': {'currentModeId': 'default', 'availableModes': [{'id': 'default'}]}}
        if method == 'session/new': response['sessionId'] = 'hermes-test-session'
        else: assert req['params']['sessionId'] == 'hermes-test-session'
        result(req, response)
    elif method == 'session/set_mode':
        assert req['params']['modeId'] == 'default'
        result(req, {})
    elif method == 'session/prompt':
        if outcome == 'permission':
            send({'id': 'approval', 'method': 'session/request_permission', 'params': {
                'sessionId': 'hermes-test-session', 'toolCall': {'title': 'Change record'},
                'options': [{'optionId': 'allow_once', 'name': 'Allow once', 'kind': 'allow_once'},
                            {'optionId': 'deny', 'name': 'Deny', 'kind': 'reject_once'}]}})
            continue
        if outcome != 'empty':
            for chunk in ['Verified ', 'result']:
                send({'method': 'session/update', 'params': {'sessionId': 'hermes-test-session',
                    'update': {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': chunk}}}})
        result(req, {'stopReason': 'end_turn' if outcome == 'empty' else outcome})
    elif method == 'session/cancel':
        sys.exit(0)
"""#
    }
}
