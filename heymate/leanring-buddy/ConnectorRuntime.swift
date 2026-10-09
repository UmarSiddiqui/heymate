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

    /// Re-prove every previously enabled connector. Connection is never
    /// assumed from persisted state — a CLI can be uninstalled and a token
    /// can expire while the app is closed.
    ///
    /// Restoring is *silent*: it may verify a permission the user has
    /// already granted, but it never asks for one. A permission panel is a
    /// response to an action, and restoring is not an action the user took —
    /// so a connector whose permission is still outstanding comes back as
    /// `.needsAttention` with a Connect button rather than as a dialog.
    func restoreEnabledConnectors() async {
        reenableComposioBridgeIfOrphaned()
        for connector in ConnectorCatalog.all where store.record(for: connector.id).isEnabled {
            await connect(connector, isRestoring: true)
        }
        for connector in store.additionalCustomMCPConnectors() where store.record(for: connector.id).isEnabled {
            await connect(connector, isRestoring: true)
        }
    }

    /// Turns the Composio bridge back on when everything it needs is still
    /// here but its own record is not: a saved key, and apps authorised
    /// through it. Without this the Apps page shows Gmail connected while
    /// chat is told no connected app is reachable, and a mate answers "how
    /// many emails?" by starting a job that drives Mail.app. Only the bridge
    /// record is restored; the restore pass that follows reconnects it.
    private func reenableComposioBridgeIfOrphaned() {
        let connectorID = ComposioSessionStore.connectorID
        guard Self.composioBridgeIsOrphaned(
            isEnabled: store.record(for: connectorID).isEnabled,
            hasStoredKey: ConnectorSecretStore.hasSecret(forConnectorID: connectorID),
            authorisedToolkitCount: ComposioAgentAttachment.connectedScope().count
        ) else { return }
        store.setEnabled(true, for: connectorID)
    }

    nonisolated static func composioBridgeIsOrphaned(
        isEnabled: Bool,
        hasStoredKey: Bool,
        authorisedToolkitCount: Int
    ) -> Bool {
        !isEnabled && hasStoredKey && authorisedToolkitCount > 0
    }

    // MARK: Connect

    func connect(_ connector: Connector, isRestoring: Bool = false) async {
        // A hand-driven connect is exactly the action that earns another
        // look at a panel the user waved away earlier this session.
        if !isRestoring { ConnectorSecretStore.retryRefusedSecrets() }
        store.markConnecting(connectorID: connector.id)
        do {
            let accountLabel = try await performConnection(for: connector, isRestoring: isRestoring)
            store.markConnected(connectorID: connector.id, accountLabel: accountLabel)
        } catch ConnectorRuntimeError.permissionNotYetGranted {
            // Not a failure — the ask is simply still owed. Presenting it as
            // plain "Connect" rather than a warning keeps the card honest:
            // nothing is broken, the user just has not been asked yet.
            store.markAwaitingConnect(connectorID: connector.id)
        } catch {
            store.markFailed(connectorID: connector.id, reason: error.localizedDescription)
        }
        await refreshAvailableMCPTools()
    }

    private func performConnection(for connector: Connector, isRestoring: Bool) async throws -> String? {
        switch connector.transport {
        case .appleNative:
            return try await connectAppleNative(connector, isRestoring: isRestoring)
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

    private func connectAppleNative(_ connector: Connector, isRestoring: Bool) async throws -> String? {
        switch connector.id {
        case "apple-calendar", "apple-reminders":
            let entityType: EKEntityType = connector.id == "apple-reminders" ? .reminder : .event
            switch EKEventStore.authorizationStatus(for: entityType) {
            case .fullAccess, .authorized:
                return "Allowed"
            case .denied, .restricted, .writeOnly:
                throw ConnectorRuntimeError.permissionRevoked(connector.displayName)
            default:
                guard !isRestoring else {
                    throw ConnectorRuntimeError.permissionNotYetGranted(connector.displayName)
                }
                let granted = try await requestEventKitAccess(store: EKEventStore(), entityType: entityType)
                guard granted else { throw ConnectorRuntimeError.permissionDenied(connector.displayName) }
                return "Allowed"
            }

        case "apple-contacts":
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .authorized:
                return "Allowed"
            case .denied, .restricted:
                throw ConnectorRuntimeError.permissionRevoked(connector.displayName)
            default:
                guard !isRestoring else {
                    throw ConnectorRuntimeError.permissionNotYetGranted(connector.displayName)
                }
                let granted = try await CNContactStore().requestAccess(for: .contacts)
                guard granted else { throw ConnectorRuntimeError.permissionDenied(connector.displayName) }
                return "Allowed"
            }

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
        //
        // Guarded by the silent existence check so a server with no stored
        // key never touches the encrypted item at all — reading it is what
        // raises the keychain panel, and most servers have nothing to read.
        var environmentOverrides: [String: String] = [:]
        if ConnectorSecretStore.hasSecret(forConnectorID: connector.id),
           let secret = ConnectorSecretStore.secret(forConnectorID: connector.id) {
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
        // A router session is scoped to the toolkits that were authorised
        // when it was minted, so reusing one after the user connects another
        // app leaves that app invisible to every search the session answers.
        if hasStoredCommand, !ComposioAgentAttachment.isSessionStale() { return }
        guard let apiKey = ConnectorSecretStore.secret(forConnectorID: connectorID),
              !apiKey.isEmpty else {
            throw ComposioProvisioningError.missingAPIKey
        }
        var session = try await composioProvisioner.createSession(
            apiKey: apiKey,
            userID: ComposioSessionStore.userID(),
            connectedAccounts: ComposioAgentAttachment.connectedAccounts()
        )
        session.scopedConnections = ComposioAgentAttachment.connectedScope()
        ComposioSessionStore.save(session)
        store.setCustomLaunchCommand(session.launchCommand, for: connectorID)
    }

    /// Re-prove Composio after the user authorises or removes a toolkit. The
    /// stale session is dropped first so `ensureComposioSession` cannot take
    /// its early return, and the live MCP client is restarted against the new
    /// URL — otherwise the new app stays unreachable until the next launch.
    func refreshComposioForChangedToolkits() async {
        guard let connector = ConnectorCatalog.connector(withID: ComposioSessionStore.connectorID),
              store.record(for: connector.id).isEnabled else { return }
        clearComposioSession()
        await connect(connector)
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
        await refreshAvailableMCPTools()
    }

    func stopAll() async {
        for (_, client) in mcpClients {
            await client.stop()
        }
        mcpClients.removeAll()
        availableMCPTools = []
    }

    // MARK: Tool surface

    private func refreshAvailableMCPTools() async {
        var flattened: [NamespacedMCPTool] = []
        for (connectorID, client) in mcpClients {
            guard let connector = mcpConnector(forSessionID: connectorID) else { continue }
            let tools = await client.discoveredTools
            flattened.append(contentsOf: tools.map { tool in
                NamespacedMCPTool(
                    connectorID: connectorID,
                    connectorDisplayName: connector.displayName,
                    tool: tool
                )
            })
        }
        availableMCPTools = flattened.sorted { $0.id < $1.id }
    }

    /// Catalog entries resolve as themselves. A user-supplied server uses
    /// the saved command for its display name so two custom servers are
    /// not both labeled with the generic catalog title.
    private func mcpConnector(forSessionID connectorID: String) -> Connector? {
        guard ConnectorCatalog.isUserSuppliedMCPID(connectorID) else {
            return ConnectorCatalog.connector(withID: connectorID)
        }
        let command = store.record(for: connectorID).customLaunchCommand
        return ConnectorCatalog.userSuppliedMCPConnector(
            id: connectorID,
            displayName: ConnectorCatalog.displayName(forCustomLaunchCommand: command),
            summary: command
        )
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
    /// Was granted once, and macOS has since had it turned off. Only System
    /// Settings can undo this — asking again would do nothing.
    case permissionRevoked(String)
    /// Never granted, and this is a silent restore, so the ask is being
    /// held back until the user clicks Connect.
    case permissionNotYetGranted(String)
    case executableNotFound(String, installHint: String?)
    case missingLaunchCommand(String)
    case missingAPIKey(String)
    case misconfigured(String)
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied(let name):
            return "\(name) needs permission in System Settings › Privacy & Security."
        case .permissionRevoked(let name):
            return "macOS is blocking \(name). Re-allow it in System Settings › Privacy & Security."
        case .permissionNotYetGranted(let name):
            return "Click Connect to let macOS ask for \(name) access."
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
