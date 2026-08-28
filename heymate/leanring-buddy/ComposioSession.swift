//
//  ComposioSession.swift
//  leanring-buddy
//
//  One connector that stands in for five hundred.
//
//  Composio's Tool Router is a single MCP endpoint that fronts every
//  toolkit the user has authorised — Gmail, Slack, Notion, Linear, Stripe —
//  and exposes a handful of meta-tools instead of thousands of concrete
//  ones: search for a tool, execute it, manage the connection that backs
//  it. That last one is why this is worth wiring: when a toolkit is not
//  connected yet, the agent is handed an authorisation URL and the user
//  finishes the OAuth in their own browser. HeyMate never sees the app's
//  token, only the Composio API key the user pastes once.
//
//  Two things are persisted, and the split matters:
//
//    Keychain     — the Composio API key, under connector id "composio",
//                   which `ConnectorRuntime` already exports to the server
//                   process as COMPOSIO_API_KEY.
//    UserDefaults — the session id, the MCP URL, and the meta-tool names.
//                   None of those work without the key, so they are not
//                   credentials, and keeping them out of the Keychain means
//                   a stale session can be inspected and reset.
//
//  The URL is reached through `mcp-remote`, the same stdio↔HTTP bridge the
//  catalog already uses for Linear, Sentry and Atlassian, because
//  `MCPClient` speaks stdio only. The key is passed as `${COMPOSIO_API_KEY}`
//  inside single quotes so the login shell leaves it alone and mcp-remote
//  substitutes it from the environment — the value never reaches the
//  command line, where `ps` would show it to every process on the Mac.
//

import Foundation

// MARK: - Persisted session

struct ComposioSession: Codable, Equatable, Sendable {
    let sessionID: String
    let mcpURL: String
    /// The meta-tools this session exposes, as reported at creation.
    /// Persisted because Claude Code needs them by name in `--allowedTools`
    /// before the server has been started even once.
    let toolNames: [String]
    let createdAt: Date

    /// `npx -y mcp-remote <url> --header 'x-api-key:${COMPOSIO_API_KEY}'`
    var launchCommand: String {
        "npx -y mcp-remote \(ComposioSessionStore.shellQuoted(mcpURL)) --header 'x-api-key:${COMPOSIO_API_KEY}'"
    }

    /// `mcp__composio__COMPOSIO_SEARCH_TOOLS`-style names for the child CLI.
    var namespacedToolNames: [String] {
        toolNames.map { "mcp__\(ComposioSessionStore.mcpServerName)__\($0)" }
    }
}

// MARK: - Store

enum ComposioSessionStore {

    /// Catalog id, Keychain account, and MCP server name all at once. It is
    /// the value `ConnectorRuntime.environmentVariableName` turns into
    /// `COMPOSIO_API_KEY`, so it must not change once shipped.
    static let connectorID = "composio"
    static let mcpServerName = "composio"

    private static let sessionKey = "composioSession"
    private static let userIDKey = "composioUserID"
    static let userIDSecretsKey = "COMPOSIO_USER_ID"

    static func session(userDefaults: UserDefaults = .standard) -> ComposioSession? {
        guard let data = userDefaults.data(forKey: sessionKey) else { return nil }
        return try? JSONDecoder().decode(ComposioSession.self, from: data)
    }

    static func save(_ session: ComposioSession, userDefaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        userDefaults.set(data, forKey: sessionKey)
    }

    static func clear(userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: sessionKey)
    }

    /// Stable per-install identity. Composio scopes connected accounts to
    /// this, so regenerating it would orphan every app the user has already
    /// authorised — hence it is minted once and kept.
    ///
    /// `COMPOSIO_USER_ID` in the secrets file wins when present. That is what
    /// makes the identity portable: accounts authorised from another machine,
    /// or from a script before the app ever ran, stay reachable instead of
    /// having to be approved a second time.
    static func userID(userDefaults: UserDefaults = .standard) -> String {
        if let configured = HeyMateSecrets.lookup(userIDSecretsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return configured
        }
        if let existing = userDefaults.string(forKey: userIDKey), !existing.isEmpty {
            return existing
        }
        let minted = "heymate-\(UUID().uuidString.lowercased())"
        userDefaults.set(minted, forKey: userIDKey)
        return minted
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Provisioning

enum ComposioProvisioningError: LocalizedError {
    case missingAPIKey
    case rejected(status: Int, message: String)
    case malformedResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your Composio API key first — it is free at composio.dev."
        case .rejected(let status, let message):
            return "Composio refused the request (\(status)): \(message)"
        case .malformedResponse:
            return "Composio returned a session without an MCP URL."
        case .transport(let detail):
            return "Could not reach Composio: \(detail)"
        }
    }
}

/// Creates the Tool Router session that the connector then talks to.
///
/// Network access is injected rather than hard-wired so the request shape —
/// which is the part that silently rots when an API moves — can be asserted
/// in tests without a live account.
struct ComposioProvisioner: Sendable {

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let sessionEndpoint = URL(string: "https://backend.composio.dev/api/v3.1/tool_router/session")!

    let transport: Transport

    init(transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.transport = transport
    }

    /// The request is built separately from being sent so a test can read it.
    static func makeRequest(apiKey: String, userID: String) throws -> URLRequest {
        var request = URLRequest(url: sessionEndpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // `manage_connections` is the whole point: without it the session can
        // only use toolkits that are already authorised, and the user is never
        // offered the browser link that authorises a new one.
        let body: [String: Any] = [
            "user_id": userID,
            "manage_connections": ["enable": true],
            "search": ["enable": true]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parseSession(from data: Data) throws -> ComposioSession {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcp = root["mcp"] as? [String: Any],
              let url = mcp["url"] as? String,
              !url.isEmpty else {
            throw ComposioProvisioningError.malformedResponse
        }
        return ComposioSession(
            sessionID: root["session_id"] as? String ?? "",
            mcpURL: url,
            toolNames: root["tool_router_tools"] as? [String] ?? [],
            createdAt: Date()
        )
    }

    func createSession(apiKey: String, userID: String) async throws -> ComposioSession {
        let request = try Self.makeRequest(apiKey: apiKey, userID: userID)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw ComposioProvisioningError.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ComposioProvisioningError.rejected(
                status: http.statusCode,
                message: Self.errorMessage(from: data)
            )
        }
        return try Self.parseSession(from: data)
    }

    /// Composio nests its human-readable reason two levels down; anything
    /// else falls back to the raw body so a new error shape is still legible.
    static func errorMessage(from data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = root["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            if let message = root["message"] as? String { return message }
        }
        return String(data: data, encoding: .utf8) ?? "no response body"
    }
}

// MARK: - Agent attachment

/// What an approved, write-enabled Claude Code leg needs in order to reach
/// the user's connected apps.
///
/// Attached to the **execute** leg only, exactly like HeyMate's own tools: a
/// planning leg is meant to be invisible, and the two-leg gate means the user
/// has already approved the plan by the time any of this loads. The gate is
/// read straight from UserDefaults rather than from `ConnectorStore` because
/// both call sites — the config JSON and the `--allowedTools` list — are
/// `nonisolated` and must agree with each other without a round trip through
/// the main actor.
nonisolated enum ComposioAgentAttachment {

    /// True only when the user enabled the connector, a session exists, and
    /// the key that session runs on is still in the Keychain.
    static func isAttachable(userDefaults: UserDefaults = .standard) -> Bool {
        guard isConnectorEnabled(userDefaults: userDefaults),
              ComposioSessionStore.session(userDefaults: userDefaults) != nil else { return false }
        return ConnectorSecretStore.hasSecret(forConnectorID: ComposioSessionStore.connectorID)
    }

    static func isConnectorEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        guard let data = userDefaults.data(forKey: ConnectorStore.recordsPreferenceKey),
              let records = try? JSONDecoder().decode([String: ConnectorRecord].self, from: data) else {
            return false
        }
        return records[ComposioSessionStore.connectorID]?.isEnabled == true
    }

    /// One `mcpServers` entry, or nil when Composio is not attachable.
    ///
    /// The command runs through the login shell for the same reason
    /// `MCPClient` does — `npx` lives on a PATH a GUI app does not inherit.
    /// The API key is referenced, never embedded: `--mcp-config` is a command
    /// line argument, and a command line is world-readable.
    static func mcpServerConfiguration(userDefaults: UserDefaults = .standard) -> [String: Any]? {
        guard isAttachable(userDefaults: userDefaults),
              let session = ComposioSessionStore.session(userDefaults: userDefaults) else { return nil }
        return [
            ComposioSessionStore.mcpServerName: [
                "command": "/bin/zsh",
                "args": ["-lc", session.launchCommand]
            ]
        ]
    }

    /// `--allowedTools` entries. Without these, `acceptEdits` refuses every
    /// MCP call outright — the same trap `HeyMateMCPServer` documents.
    static func claudeCodeToolNames(userDefaults: UserDefaults = .standard) -> [String] {
        guard isAttachable(userDefaults: userDefaults),
              let session = ComposioSessionStore.session(userDefaults: userDefaults) else { return [] }
        return session.namespacedToolNames
    }

    /// The key travels in the child environment, never in an argument.
    static func childEnvironment(userDefaults: UserDefaults = .standard) -> [String: String] {
        guard isAttachable(userDefaults: userDefaults),
              let apiKey = ConnectorSecretStore.secret(forConnectorID: ComposioSessionStore.connectorID),
              !apiKey.isEmpty else { return [:] }
        return ["COMPOSIO_API_KEY": apiKey]
    }
}
