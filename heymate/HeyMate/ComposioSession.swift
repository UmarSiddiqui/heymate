//
//  ComposioSession.swift
//  HeyMate
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

    /// Which authorised toolkits this router session was minted for, as
    /// `slug:connectedAccountID` pairs.
    ///
    /// A Tool Router session is scoped when it is created: a toolkit the user
    /// authorises afterwards is simply not in it, and `COMPOSIO_SEARCH_TOOLS`
    /// answers about that session, so the search comes back empty and the
    /// model reports no connection. Comparing this against the current set is
    /// what forces a fresh session instead.
    ///
    /// Optional because sessions stored before this existed decode with the
    /// key missing — and nil means "scope unknown", which counts as stale, so
    /// one of those is replaced the first time it is used.
    var scopedConnections: [String]?

    /// True when `connected_accounts` was included in the session creation
    /// request. Sessions stored before account pinning existed decode this as
    /// nil and must be replaced even when their recorded scope still matches.
    var connectedAccountsWerePinned: Bool?

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
    static func makeRequest(
        apiKey: String,
        userID: String,
        connectedAccounts: [String: [String]] = [:]
    ) throws -> URLRequest {
        var request = URLRequest(url: sessionEndpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // `manage_connections` is the whole point: without it the session can
        // only use toolkits that are already authorised, and the user is never
        // offered the browser link that authorises a new one.
        var body: [String: Any] = [
            "user_id": userID,
            "manage_connections": ["enable": true],
            "search": ["enable": true]
        ]
        if !connectedAccounts.isEmpty {
            // Tool Router otherwise creates a session for the user but does
            // not reliably select accounts that were authorised earlier.
            // Pinning the known account ids makes those toolkits visible to
            // COMPOSIO_SEARCH_TOOLS immediately.
            body["connected_accounts"] = connectedAccounts
        }
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

    func createSession(
        apiKey: String,
        userID: String,
        connectedAccounts: [String: [String]] = [:]
    ) async throws -> ComposioSession {
        let request = try Self.makeRequest(
            apiKey: apiKey,
            userID: userID,
            connectedAccounts: connectedAccounts
        )
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
        var session = try Self.parseSession(from: data)
        session.connectedAccountsWerePinned = true
        return session
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
    ///
    /// `hasStoredKey` is a seam, not a setting: its default performs the real
    /// silent Keychain check, and only a test passes it, so an assertion
    /// about the attached shape does not depend on whether the machine
    /// running it happens to hold a Composio key.
    static func isAttachable(
        userDefaults: UserDefaults = .standard,
        hasStoredKey: Bool = ConnectorSecretStore.hasSecret(forConnectorID: ComposioSessionStore.connectorID)
    ) -> Bool {
        guard isConnectorEnabled(userDefaults: userDefaults),
              ComposioSessionStore.session(userDefaults: userDefaults) != nil else { return false }
        return hasStoredKey
    }

    static func isConnectorEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        guard let data = userDefaults.data(forKey: ConnectorStore.recordsPreferenceKey),
              let records = try? JSONDecoder().decode([String: ConnectorRecord].self, from: data) else {
            return false
        }
        return records[ComposioSessionStore.connectorID]?.isEnabled == true
    }

    /// Nothing here builds an MCP server entry any more. A child CLI reaches
    /// the user's connected apps through HeyMate's own loopback server, which
    /// borrows the sessions `ConnectorRuntime` already holds — see
    /// `HeyMateMCPServer`. Handing a child its own Composio URL meant a cold
    /// `npx` fetch on every question, a second sign-in to the vendor, and a
    /// tool call that bypassed the user's approval policy entirely.

    // MARK: Prompt

    /// `slug:connectedAccountID` for every authorised toolkit, sorted.
    ///
    /// The slug is included because a no-auth toolkit has no account id, and
    /// two of those would otherwise be indistinguishable. The pair is stable
    /// across `revalidate()`, which rewrites `connectedAt` every launch and
    /// so cannot be used to tell a new authorisation from an old one.
    static func connectedScope(userDefaults: UserDefaults = .standard) -> [String] {
        guard let data = userDefaults.data(forKey: ComposioConnectionsRuntime.recordsPreferenceKey),
              let records = try? JSONDecoder().decode(
                  [String: ComposioConnectionRecord].self,
                  from: data
              ) else { return [] }
        return records.values
            .map { "\($0.toolkitSlug):\($0.connectedAccountID)" }
            .sorted()
    }

    /// Account selection map accepted by Tool Router session creation.
    /// No-auth toolkits deliberately stay out: their empty account id is not
    /// a valid connected-account selector.
    static func connectedAccounts(userDefaults: UserDefaults = .standard) -> [String: [String]] {
        guard let data = userDefaults.data(forKey: ComposioConnectionsRuntime.recordsPreferenceKey),
              let records = try? JSONDecoder().decode(
                  [String: ComposioConnectionRecord].self,
                  from: data
              ) else { return [:] }
        return records.values.reduce(into: [:]) { result, record in
            guard !record.connectedAccountID.isEmpty else { return }
            result[record.toolkitSlug] = [record.connectedAccountID]
        }
    }

    /// True when the stored session was minted for a different set of
    /// authorised toolkits than the user has now — including the legacy case
    /// where the session records no scope at all.
    static func isSessionStale(userDefaults: UserDefaults = .standard) -> Bool {
        guard let session = ComposioSessionStore.session(userDefaults: userDefaults) else { return true }
        guard session.connectedAccountsWerePinned == true else { return true }
        guard let scoped = session.scopedConnections else { return true }
        return scoped != connectedScope(userDefaults: userDefaults)
    }

    /// Display names of the toolkits the user actually authorised, read from
    /// the same defaults key `ComposioConnectionsRuntime` writes. Read here
    /// rather than passed in because every caller is `nonisolated` and the
    /// runtime that owns the list is main-actor bound.
    static func connectedAppNames(userDefaults: UserDefaults = .standard) -> [String] {
        guard let data = userDefaults.data(forKey: ComposioConnectionsRuntime.recordsPreferenceKey),
              let records = try? JSONDecoder().decode(
                  [String: ComposioConnectionRecord].self,
                  from: data
              ) else { return [] }
        return records.values
            .map { $0.displayName.isEmpty ? $0.toolkitSlug : $0.displayName }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// What a Talk turn is told once the meta-tools are actually reachable.
    ///
    /// Without this the model sees six abstractly named tools and answers a
    /// question about the user's own YouTube channel from general knowledge —
    /// the meta-tools never announce which apps sit behind them, and the
    /// search-then-execute pairing is not guessable from the names alone.
    static func talkPromptBlock(
        userDefaults: UserDefaults = .standard,
        hasStoredKey: Bool = ConnectorSecretStore.hasSecret(forConnectorID: ComposioSessionStore.connectorID),
        enabledToolkitSlugs: Set<String>? = nil
    ) -> String? {
        guard isAttachable(userDefaults: userDefaults, hasStoredKey: hasStoredKey) else { return nil }
        let records: [String: ComposioConnectionRecord]
        if let data = userDefaults.data(forKey: ComposioConnectionsRuntime.recordsPreferenceKey),
           let decoded = try? JSONDecoder().decode([String: ComposioConnectionRecord].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
        let enabledRecords = records.values.filter { record in
            enabledToolkitSlugs?.contains(record.toolkitSlug) ?? true
        }
        let names = enabledRecords
            .map { $0.displayName.isEmpty ? $0.toolkitSlug : $0.displayName }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let appsLine = names.isEmpty
            ? "no composio apps are enabled for this chat. do not search for or call composio tools."
            : "connected through composio: \(names.joined(separator: ", "))."
        return """
        connected apps:
        - \(appsLine)
        - those are the user's live accounts, not general knowledge. when the question is about one of them — their own videos, subscriptions, playlists, mail, issues — read the answer out of the account instead of answering from what you already know about the service.
        - some of your tools are not listed up front. if you do not see a composio tool in your list, use your own tool search first to find one whose name contains COMPOSIO — codex keeps mcp tools behind that search, and a turn that skips it sees nothing and wrongly concludes there is no connection.
        - the composio tools come as a pair: COMPOSIO_SEARCH_TOOLS finds the tool for the app and action, then COMPOSIO_MULTI_EXECUTE_TOOL runs it. one search then one execute is the normal shape of such a turn.
        - when the search comes back with tools for the app, run one. the search only returns tools for accounts that are already authorised, so a result *is* the proof the account works — there is nothing to verify first.
        - you cannot connect or disconnect apps, and there is no tool for it here. if an app really is missing, say so and tell the user to open Tools in HeyMate, where they connect it themselves.
        - never say an app is out of reach before the search has actually come back empty.
        """
    }

    /// Said instead of `talkPromptBlock` when the user has Composio connected
    /// but this turn's brain cannot call tools at all. Being told the apps
    /// exist without being able to reach them is exactly the setup that
    /// produces a confident answer from memory.
    static func unreachablePromptBlock(
        userDefaults: UserDefaults = .standard,
        hasStoredKey: Bool = ConnectorSecretStore.hasSecret(forConnectorID: ComposioSessionStore.connectorID)
    ) -> String? {
        guard isAttachable(userDefaults: userDefaults, hasStoredKey: hasStoredKey) else { return nil }
        return """
        connected apps:
        - the user has apps connected through composio, but this brain cannot call tools, so none of them are reachable this turn.
        - never answer a question about their own account as if you had read it. say plainly that the current brain cannot reach connected apps, and that switching the brain in Settings to Claude, Codex, or a Custom API is what makes them work.
        """
    }
}
