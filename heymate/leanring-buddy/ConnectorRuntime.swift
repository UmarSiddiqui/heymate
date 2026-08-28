//
//  ConnectorRuntime.swift
//  leanring-buddy
//
//  Turns catalog entries into live capability.
//
//  One method — `connect(_:)` — fans out to four very different things
//  depending on transport, and every one of them reports back through the
//  same `ConnectorStore` state machine so the UI needs no special cases:
//
//    .appleNative → request the TCC permission the framework needs
//    .localCLI    → probe PATH for the executable
//    .mcp         → launch the server and complete the handshake
//    .apiKey      → validate that a Keychain secret exists
//
//  Vendor sign-ins are not here: Composio brokers those, and
//  `ComposioConnectionsRuntime` owns that flow.
//
//  Disconnecting is symmetric and always removes the secret.
//

import AppKit
import Combine
import Contacts
import EventKit
import Foundation

@MainActor
final class ConnectorRuntime: ObservableObject {

    let store: ConnectorStore

    /// Live MCP sessions keyed by connector id. Started on connect, torn
    /// down on disconnect and at app exit.
    private var mcpClients: [String: MCPClient] = [:]

    /// Tools contributed by every connected MCP server, flattened and
    /// namespaced so two servers can both expose a `search` tool.
    @Published private(set) var availableMCPTools: [NamespacedMCPTool] = []

    struct NamespacedMCPTool: Identifiable, Equatable, Sendable {
        let connectorID: String
        let connectorDisplayName: String
        let tool: MCPToolDefinition
        /// `slack__search_messages` — stable, model-friendly, collision-free.
        var id: String { "\(connectorID.replacingOccurrences(of: "-", with: "_"))__\(tool.name)" }
    }

    /// Injected so a test can exercise the connect path without a live
    /// Composio account.
    private let composioProvisioner: ComposioProvisioner

    init(
        store: ConnectorStore,
        composioProvisioner: ComposioProvisioner = ComposioProvisioner()
    ) {
        self.store = store
        self.composioProvisioner = composioProvisioner
    }

    // MARK: Restore

    /// Re-prove every previously enabled connector at launch. Connection is
    /// never assumed from persisted state — a CLI can be uninstalled and a
    /// token can expire while the app is closed.
    func restoreEnabledConnectors() async {
        for connector in ConnectorCatalog.all where store.record(for: connector.id).isEnabled {
            await connect(connector, isRestoring: true)
        }
    }

    // MARK: Connect

    func connect(_ connector: Connector, isRestoring: Bool = false) async {
        store.markConnecting(connectorID: connector.id)
        do {
            let accountLabel = try await performConnection(for: connector, isRestoring: isRestoring)
            store.markConnected(connectorID: connector.id, accountLabel: accountLabel)
        } catch {
            store.markFailed(connectorID: connector.id, reason: error.localizedDescription)
        }
        refreshAvailableMCPTools()
    }

    private func performConnection(for connector: Connector, isRestoring: Bool) async throws -> String? {
        switch connector.transport {
        case .appleNative:
            return try await connectAppleNative(connector)
        case .localCLI:
            return try connectLocalCLI(connector)
        case .mcp:
            return try await connectMCP(connector)
        case .apiKey:
            guard ConnectorSecretStore.hasSecret(forConnectorID: connector.id) else {
                throw ConnectorRuntimeError.missingAPIKey(connector.displayName)
            }
            return "Key saved"
        }
    }

    // MARK: Apple native

    private func connectAppleNative(_ connector: Connector) async throws -> String? {
        switch connector.id {
        case "apple-calendar", "apple-reminders":
            let store = EKEventStore()
            let entityType: EKEntityType = connector.id == "apple-reminders" ? .reminder : .event
            let granted = try await requestEventKitAccess(store: store, entityType: entityType)
            guard granted else { throw ConnectorRuntimeError.permissionDenied(connector.displayName) }
            return "Allowed"

        case "apple-contacts":
            let granted = try await CNContactStore().requestAccess(for: .contacts)
            guard granted else { throw ConnectorRuntimeError.permissionDenied(connector.displayName) }
            return "Allowed"

        case "apple-screen":
            // Screen Recording is already managed by the companion's own
            // permission flow; reflect that rather than prompting twice.
            return "Managed in Permissions"

        default:
            // Notes, Mail, Messages, Shortcuts, Music and Maps go through
            // scripting or public URL schemes. macOS prompts for Automation
            // on first real use, which is the honest moment to ask — so
            // enabling here only records intent.
            return "Ready"
        }
    }

    private func requestEventKitAccess(store: EKEventStore, entityType: EKEntityType) async throws -> Bool {
        // EventKit's completion is declared @Sendable, so the continuation
        // has to be resumed from inside a @Sendable closure rather than a
        // shared local one — hence the duplicated bodies.
        if entityType == .reminder {
            return try await withCheckedThrowingContinuation { continuation in
                store.requestFullAccessToReminders { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            store.requestFullAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    // MARK: Local CLI

    private func connectLocalCLI(_ connector: Connector) throws -> String? {
        guard let executableName = connector.requiredExecutableName else {
            throw ConnectorRuntimeError.misconfigured(connector.displayName)
        }
        guard let resolvedURL = LoginShellExecutableResolver.resolveExecutable(named: executableName) else {
            throw ConnectorRuntimeError.executableNotFound(
                executableName,
                installHint: connector.installHint
            )
        }
        // Show the directory, not the full path — "/opt/homebrew/bin" is
        // the useful part when diagnosing a wrong-version problem.
        return resolvedURL.deletingLastPathComponent().path
    }

    // MARK: MCP

    private func connectMCP(_ connector: Connector) async throws -> String? {
        // Composio has no fixed command: its URL is a Tool Router session
        // minted against the user's own API key. Mint one if this is the
        // first connect, then fall through as an ordinary MCP server.
        if connector.id == ComposioSessionStore.connectorID {
            try await ensureComposioSession()
        }

        let record = store.record(for: connector.id)
        let command = record.customLaunchCommand?.isEmpty == false
            ? record.customLaunchCommand!
            : (connector.mcpLaunchCommand ?? "")

        guard !command.isEmpty else {
            throw ConnectorRuntimeError.missingLaunchCommand(connector.displayName)
        }

        // A stored secret becomes the server's API-key environment variable.
        // MCP servers overwhelmingly read one; passing it in the environment
        // keeps it off the command line, where `ps` would expose it.
        var environmentOverrides: [String: String] = [:]
        if let secret = ConnectorSecretStore.secret(forConnectorID: connector.id) {
            environmentOverrides[Self.environmentVariableName(forConnectorID: connector.id)] = secret
        }

        await mcpClients[connector.id]?.stop()
        let client = MCPClient(launchCommand: command, environmentOverrides: environmentOverrides)
        let tools = try await client.startAndDiscoverTools()
        mcpClients[connector.id] = client

        return tools.isEmpty ? "Connected" : "\(tools.count) tools"
    }

    /// Convention used by most published servers: `SLACK_API_KEY`,
    /// `NOTION_API_KEY`. Derived from the id so new catalog entries need no
    /// extra table.
    nonisolated static func environmentVariableName(forConnectorID connectorID: String) -> String {
        let stripped = connectorID.hasPrefix("mcp-")
            ? String(connectorID.dropFirst("mcp-".count))
            : connectorID
        return stripped
            .replacingOccurrences(of: "-", with: "_")
            .uppercased() + "_API_KEY"
    }

    // MARK: Composio session

    /// Reuse the stored session when there is one; otherwise ask Composio
    /// for a new one and write its launch command into the record, which is
    /// where every later connect reads it from.
    private func ensureComposioSession() async throws {
        let connectorID = ComposioSessionStore.connectorID
        let hasStoredCommand = store.record(for: connectorID).customLaunchCommand?.isEmpty == false
        if ComposioSessionStore.session() != nil, hasStoredCommand { return }
        guard let apiKey = ConnectorSecretStore.secret(forConnectorID: connectorID),
              !apiKey.isEmpty else {
            throw ComposioProvisioningError.missingAPIKey
        }
        let session = try await composioProvisioner.createSession(
            apiKey: apiKey,
            userID: ComposioSessionStore.userID()
        )
        ComposioSessionStore.save(session)
        store.setCustomLaunchCommand(session.launchCommand, for: connectorID)
    }

    /// Forget the session so the next connect mints a fresh one. Called on
    /// disconnect, because a session outlives its usefulness the moment the
    /// key behind it is deleted.
    private func clearComposioSession() {
        ComposioSessionStore.clear()
        store.setCustomLaunchCommand(nil, for: ComposioSessionStore.connectorID)
    }

    // MARK: Disconnect

    func disconnect(_ connector: Connector) async {
        if let client = mcpClients.removeValue(forKey: connector.id) {
            await client.stop()
        }
        store.disconnect(connectorID: connector.id)
        if connector.id == ComposioSessionStore.connectorID {
            clearComposioSession()
        }
        refreshAvailableMCPTools()
    }

    func stopAll() async {
        for (_, client) in mcpClients {
            await client.stop()
        }
        mcpClients.removeAll()
        availableMCPTools = []
    }

    // MARK: Tool surface

    private func refreshAvailableMCPTools() {
        Task { [weak self] in
            guard let self else { return }
            var flattened: [NamespacedMCPTool] = []
            for (connectorID, client) in self.mcpClients {
                guard let connector = ConnectorCatalog.connector(withID: connectorID) else { continue }
                let tools = await client.discoveredTools
                flattened.append(contentsOf: tools.map { tool in
                    NamespacedMCPTool(
                        connectorID: connectorID,
                        connectorDisplayName: connector.displayName,
                        tool: tool
                    )
                })
            }
            let sorted = flattened.sorted { $0.id < $1.id }
            await MainActor.run { self.availableMCPTools = sorted }
        }
    }

    /// Route a namespaced tool call back to the server that owns it.
    /// Approval is the caller's job — by the time this runs, the user has
    /// already said yes to anything the risk ladder required.
    func callTool(namespacedID: String, arguments: [String: Any]) async throws -> MCPToolResult {
        guard let namespaced = availableMCPTools.first(where: { $0.id == namespacedID }),
              let client = mcpClients[namespaced.connectorID] else {
            throw ConnectorRuntimeError.unknownTool(namespacedID)
        }
        return try await client.callTool(named: namespaced.tool.name, arguments: arguments)
    }
}

// MARK: - Errors

enum ConnectorRuntimeError: LocalizedError {
    case permissionDenied(String)
    case executableNotFound(String, installHint: String?)
    case missingLaunchCommand(String)
    case missingAPIKey(String)
    case misconfigured(String)
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let name):
            return "\(name) needs permission in System Settings › Privacy & Security."
        case .executableNotFound(let executable, let installHint):
            if let installHint {
                return "`\(executable)` is not on your PATH. Install it with: \(installHint)"
            }
            return "`\(executable)` is not on your PATH."
        case .missingLaunchCommand(let name):
            return "\(name) needs a server command before it can start."
        case .missingAPIKey(let name):
            return "Add an API key for \(name) first."
        case .misconfigured(let name):
            return "\(name) is missing configuration."
        case .unknownTool(let toolID):
            return "No connected server provides \(toolID)."
        }
    }
}
