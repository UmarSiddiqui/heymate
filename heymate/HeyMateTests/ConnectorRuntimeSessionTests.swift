import Foundation
import Testing
@testable import HeyMate

@Suite(.serialized)
@MainActor
struct ConnectorRuntimeSessionTests {
    @Test func customServerExecutesRealToolAndDeadSessionStopsAdvertisingIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("heymate-mcp-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fixture.py")
        try Self.server.write(to: script, atomically: true, encoding: .utf8)
        let suite = "heymate-connector-fixture-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConnectorStore(userDefaults: defaults)
        let id = ConnectorCatalog.additionalCustomMCPIDPrefix + UUID().uuidString
        store.setCustomLaunchCommand("/usr/bin/python3 -u '\(script.path)'", for: id)
        let connector = try #require(ConnectorCatalog.connector(withID: id))
        let runtime = ConnectorRuntime(store: store)
        await runtime.connect(connector)
        #expect(store.connectionState(for: id).isConnected)
        let tool = try #require(runtime.availableMCPTools.first)
        let exposed = try #require(TalkToolCatalog.availableTools(connectorRuntime: runtime).first { $0.toolDefinition.name == tool.id })
        if case .connector(let owner, let name, let risk) = exposed.origin {
            #expect(owner == id)
            #expect(name == tool.connectorDisplayName)
            #expect(risk == connector.maximumRisk)
        } else { Issue.record("Custom connector was exposed as an ungated local tool") }
        let result = try await runtime.callTool(namespacedID: tool.id, arguments: [:])
        #expect(result.textContent == "verified fixture result")
        #expect(!result.isError)
        do {
            _ = try await runtime.callTool(namespacedID: tool.id, arguments: ["close": true])
            Issue.record("A closed server unexpectedly returned success")
        } catch { }
        #expect(!store.connectionState(for: id).isConnected)
        #expect(store.record(for: id).lastErrorMessage != nil)
        #expect(runtime.availableMCPTools.isEmpty)
        #expect(!TalkToolCatalog.availableTools(connectorRuntime: runtime).contains { $0.toolDefinition.name == tool.id })
        await runtime.stopAll()
    }

    @Test func timedOutActionExplicitlyReportsUnknownOutcome() {
        let message = ConnectorRuntimeError.callOutcomeUnknown("Example service").localizedDescription
        #expect(message.contains("outcome is unknown"))
        #expect(message.contains("check the service before repeating"))
    }

    private static let server = #"""
    import json, sys
    for line in sys.stdin:
        request = json.loads(line)
        if 'id' not in request:
            continue
        method = request['method']
        if method == 'initialize':
            result = {'protocolVersion': '2025-06-18', 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'HeyMate fixture', 'version': '1'}}
        elif method == 'tools/list':
            result = {'tools': [{'name': 'read_fixture', 'description': 'Read a synthetic fixture, never a user account', 'inputSchema': {'type': 'object'}}]}
        elif method == 'tools/call':
            if request.get('params', {}).get('arguments', {}).get('close'):
                sys.exit(0)
            result = {'content': [{'type': 'text', 'text': 'verified fixture result'}], 'isError': False}
        else:
            result = {}
        print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
    """#
}
