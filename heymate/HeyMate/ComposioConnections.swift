//
//  ComposioConnections.swift
//  HeyMate
//
//  Which apps the user has actually authorised, and the one method that
//  authorises another.
//
//  Kept separate from `ConnectorStore` on purpose. That store is keyed by
//  catalog id and drops records whose connector no longer exists — correct
//  for a catalog held in this repo, wrong for a list of 1,411 toolkits
//  fetched at runtime, where "not in the catalog" means "not on this page of
//  search results".
//
//  Nothing here is a credential. A connected-account id is useless without
//  the Composio API key, which lives in the Keychain.
//

import AppKit
import Combine
import Foundation

// MARK: - Record

struct ComposioConnectionRecord: Codable, Equatable, Sendable {
    var toolkitSlug: String
    var connectedAccountID: String
    var displayName: String
    var connectedAt: Date

    init(toolkitSlug: String, connectedAccountID: String, displayName: String, connectedAt: Date = Date()) {
        self.toolkitSlug = toolkitSlug
        self.connectedAccountID = connectedAccountID
        self.displayName = displayName
        self.connectedAt = connectedAt
    }
}

// MARK: - Live state

enum ComposioConnectionState: Equatable, Sendable {
    case notConnected
    /// The browser is open and Composio is being polled.
    case connecting
    case connected
    case needsAttention(reason: String)

    var isConnected: Bool { self == .connected }
}

// MARK: - Runtime

/// Connect and disconnect Composio toolkits. The three-call flow lives in
/// `ComposioAuthBroker`; this owns the state the UI reads and the browser
/// window the user finishes the sign-in in.
@MainActor
final class ComposioConnectionsRuntime: ObservableObject {

    /// Long enough to read a consent screen, short enough that a row does not
    /// spin forever after the user gave up in the browser.
    static let connectionTimeout: TimeInterval = 180
    private static let pollInterval: Duration = .seconds(2)
    /// Internal rather than private: `ComposioAgentAttachment` reads the same
    /// list to name the connected apps in a Talk prompt, and it is
    /// `nonisolated` so it cannot ask this main-actor runtime.
    static let recordsPreferenceKey = "composioConnections"

    @Published private(set) var records: [String: ComposioConnectionRecord] = [:]
    @Published private(set) var states: [String: ComposioConnectionState] = [:]

    private let broker: ComposioAuthBroker
    private let userDefaults: UserDefaults

    /// Called after the set of authorised toolkits changes. `ConnectorRuntime`
    /// hangs the router-session refresh here rather than this type reaching
    /// for it: authorising an app and holding the MCP session are separate
    /// jobs, and only one of them belongs in this file.
    var onConnectedToolkitsChanged: (@MainActor () async -> Void)?

    init(
        broker: ComposioAuthBroker = ComposioAuthBroker(),
        userDefaults: UserDefaults = .standard
    ) {
        self.broker = broker
        self.userDefaults = userDefaults
        loadRecords()
        // Persisted records describe the last known truth, not the current
        // one — a token can be revoked from the vendor's side while the app
        // is closed. `revalidate()` proves them again.
        states = records.mapValues { _ in .connected }
    }

    // MARK: Reading

    func state(for toolkitSlug: String) -> ComposioConnectionState {
        states[toolkitSlug] ?? .notConnected
    }

    var connectedSlugs: [String] {
        records.keys.filter { state(for: $0).isConnected }.sorted()
    }

    var apiKey: String? {
        let stored = ConnectorSecretStore.secret(forConnectorID: ComposioSessionStore.connectorID)
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    var isConfigured: Bool { apiKey != nil }

    @Published private(set) var availableAccounts: [String: [ComposioConnectedAccountSummary]] = [:]
    private var accountOperations: [String: UUID] = [:]

    /// Select only an account returned for this installation's user, and prove
    /// it is still active before replacing routing. No remote deletion.
    func selectAccount(_ account: ComposioConnectedAccountSummary) async {
        let slug = account.toolkitSlug
        guard state(for: slug) != .connecting,
              availableAccounts[slug]?.contains(account) == true,
              let apiKey else { return }
        let operation = UUID()
        accountOperations[slug] = operation
        states[slug] = .connecting
        do {
            let status = try await broker.connectionStatus(apiKey: apiKey, connectedAccountID: account.connectedAccountID)
            guard accountOperations[slug] == operation else { return }
            guard status == ComposioAuthBroker.activeStatus else { throw ComposioAuthError.connectionFailed(status) }
            store(ComposioConnectionRecord(toolkitSlug: slug, connectedAccountID: account.connectedAccountID,
                                          displayName: account.displayName))
            states[slug] = .connected
            await onConnectedToolkitsChanged?()
        } catch {
            guard accountOperations[slug] == operation else { return }
            states[slug] = .needsAttention(reason: "Could not select account. Reconnect or try another active account.")
        }
    }

    // MARK: Connecting

    /// Create the toolkit's auth config if it has none, open the consent URL
    /// in the user's own browser, then poll until Composio reports ACTIVE.
    func connect(_ toolkit: ComposioToolkit, replacingAccount: Bool = false) async {
        guard state(for: toolkit.slug) != .connecting else { return }
        let operation = UUID()
        accountOperations[toolkit.slug] = operation
        if !replacingAccount, records[toolkit.slug] != nil, state(for: toolkit.slug).isConnected {
            return
        }
        guard let apiKey else {
            states[toolkit.slug] = .needsAttention(reason: ComposioAuthError.notConfigured.localizedDescription)
            return
        }
        states[toolkit.slug] = .connecting
        do {
            if toolkit.requiresNoAuthentication {
                store(
                    ComposioConnectionRecord(
                        toolkitSlug: toolkit.slug,
                        connectedAccountID: "",
                        displayName: toolkit.name
                    )
                )
                states[toolkit.slug] = .connected
                await onConnectedToolkitsChanged?()
                return
            }
            let authConfigID = try await ensureAuthConfig(apiKey: apiKey, toolkitSlug: toolkit.slug)
            let request = try await broker.initiateConnection(
                apiKey: apiKey,
                authConfigID: authConfigID,
                userID: ComposioSessionStore.userID()
            )
            if let redirectURL = request.redirectURL {
                NSWorkspace.shared.open(redirectURL)
            }
            let status = try await awaitConnection(
                apiKey: apiKey,
                connectedAccountID: request.connectedAccountID,
                displayName: toolkit.name
            )
            guard accountOperations[toolkit.slug] == operation else { return }
            guard status == ComposioAuthBroker.activeStatus else {
                throw ComposioAuthError.connectionFailed(status)
            }
            store(
                ComposioConnectionRecord(
                    toolkitSlug: toolkit.slug,
                    connectedAccountID: request.connectedAccountID,
                    displayName: toolkit.name
                )
            )
            states[toolkit.slug] = .connected
            await onConnectedToolkitsChanged?()
        } catch {
            guard accountOperations[toolkit.slug] == operation else { return }
            states[toolkit.slug] = .needsAttention(reason: error.localizedDescription)
        }
    }

    func disconnect(_ toolkitSlug: String) async {
        guard state(for: toolkitSlug) != .connecting else { return }
        accountOperations[toolkitSlug] = UUID()
        guard let record = records[toolkitSlug] else {
            states[toolkitSlug] = .notConnected
            return
        }
        states[toolkitSlug] = .connecting
        do {
            if !record.connectedAccountID.isEmpty {
                guard let apiKey else { throw ComposioAuthError.notConfigured }
                try await broker.disconnect(
                    apiKey: apiKey,
                    connectedAccountID: record.connectedAccountID
                )
            }
            records.removeValue(forKey: toolkitSlug)
            states[toolkitSlug] = .notConnected
            persist()
            await onConnectedToolkitsChanged?()
        } catch {
            states[toolkitSlug] = .needsAttention(reason: error.localizedDescription)
        }
    }

    /// Re-prove every stored connection. Cheap, and the only honest way to
    /// show "Connected" after a relaunch.
    func revalidate() async {
        // Nothing signed in means nothing to re-prove, and reaching for the
        // API key would raise a keychain panel to answer a question that has
        // no consequences. Check the cheap, non-secret state first.
        guard !records.isEmpty else { return }
        guard let apiKey else { return }
        var synchronizedAccountIDs: Set<String> = []
        do {
            let activeConnections = try await broker.activeConnections(
                apiKey: apiKey,
                userID: ComposioSessionStore.userID()
            )
            availableAccounts = Dictionary(grouping: activeConnections, by: \.toolkitSlug)
            for (slug, accounts) in availableAccounts {
                guard state(for: slug) != .connecting else { continue }
                if let existing = records[slug] {
                    // Keep explicit selection. An inactive selected account
                    // requires user choice; enumeration order grants nothing.
                    if accounts.contains(where: { $0.connectedAccountID == existing.connectedAccountID }) {
                        synchronizedAccountIDs.insert(existing.connectedAccountID)
                        states[slug] = .connected
                    }
                } else if accounts.count == 1, let account = accounts.first {
                    synchronizedAccountIDs.insert(account.connectedAccountID)
                    store(ComposioConnectionRecord(toolkitSlug: slug, connectedAccountID: account.connectedAccountID,
                                                  displayName: account.displayName))
                    states[slug] = .connected
                } else {
                    states[slug] = .needsAttention(reason: "Choose which connected account HeyMate should use.")
                }
            }
        } catch {
            // Existing records are still checked individually below. A list
            // failure must not turn every known app off at once.
        }
        for (slug, record) in records {
            guard state(for: slug) != .connecting else { continue }
            let selection = record.connectedAccountID
            if record.connectedAccountID.isEmpty {
                states[slug] = .connected
                continue
            }
            if synchronizedAccountIDs.contains(record.connectedAccountID) {
                continue
            }
            do {
                let status = try await broker.connectionStatus(
                    apiKey: apiKey,
                    connectedAccountID: record.connectedAccountID
                )
                guard records[slug]?.connectedAccountID == selection, state(for: slug) != .connecting else { continue }
                states[slug] = status == ComposioAuthBroker.activeStatus
                    ? .connected
                    : .needsAttention(reason: "Sign-in is no longer active (\(status)).")
            } catch {
                guard records[slug]?.connectedAccountID == selection, state(for: slug) != .connecting else { continue }
                states[slug] = .needsAttention(reason: error.localizedDescription)
            }
        }
    }

    // MARK: Internals

    private func ensureAuthConfig(apiKey: String, toolkitSlug: String) async throws -> String {
        if let cached = ComposioAuthConfigCache.identifier(forToolkit: toolkitSlug, userDefaults: userDefaults) {
            return cached
        }
        let identifier = try await broker.createAuthConfig(apiKey: apiKey, toolkitSlug: toolkitSlug)
        ComposioAuthConfigCache.store(identifier, forToolkit: toolkitSlug, userDefaults: userDefaults)
        return identifier
    }

    private func awaitConnection(
        apiKey: String,
        connectedAccountID: String,
        displayName: String
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(Self.connectionTimeout)
        while Date() < deadline {
            let status = try await broker.connectionStatus(
                apiKey: apiKey,
                connectedAccountID: connectedAccountID
            )
            if status == ComposioAuthBroker.activeStatus { return status }
            if ComposioAuthBroker.failureStatuses.contains(status) { return status }
            try? await Task.sleep(for: Self.pollInterval)
        }
        throw ComposioAuthError.timedOut(displayName)
    }

    private func store(_ record: ComposioConnectionRecord) {
        records[record.toolkitSlug] = record
        persist()
    }

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(records) else { return }
        userDefaults.set(encoded, forKey: Self.recordsPreferenceKey)
    }

    private func loadRecords() {
        guard let data = userDefaults.data(forKey: Self.recordsPreferenceKey),
              let decoded = try? JSONDecoder().decode([String: ComposioConnectionRecord].self, from: data) else {
            return
        }
        records = decoded
    }
}
