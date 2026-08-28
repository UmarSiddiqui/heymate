//
//  ComposioConnections.swift
//  leanring-buddy
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
    private static let storageKey = "composioConnections"

    @Published private(set) var records: [String: ComposioConnectionRecord] = [:]
    @Published private(set) var states: [String: ComposioConnectionState] = [:]

    private let broker: ComposioAuthBroker
    private let userDefaults: UserDefaults

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

    // MARK: Connecting

    /// Create the toolkit's auth config if it has none, open the consent URL
    /// in the user's own browser, then poll until Composio reports ACTIVE.
    func connect(_ toolkit: ComposioToolkit) async {
        if records[toolkit.slug] != nil, state(for: toolkit.slug).isConnected {
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
        } catch {
            states[toolkit.slug] = .needsAttention(reason: error.localizedDescription)
        }
    }

    func disconnect(_ toolkitSlug: String) async {
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
        } catch {
            states[toolkitSlug] = .needsAttention(reason: error.localizedDescription)
        }
    }

    /// Re-prove every stored connection. Cheap, and the only honest way to
    /// show "Connected" after a relaunch.
    func revalidate() async {
        guard let apiKey else { return }
        var synchronizedAccountIDs: Set<String> = []
        do {
            let activeConnections = try await broker.activeConnections(
                apiKey: apiKey,
                userID: ComposioSessionStore.userID()
            )
            for activeConnection in activeConnections {
                synchronizedAccountIDs.insert(activeConnection.connectedAccountID)
                let existingDisplayName = records[activeConnection.toolkitSlug]?.displayName
                store(
                    ComposioConnectionRecord(
                        toolkitSlug: activeConnection.toolkitSlug,
                        connectedAccountID: activeConnection.connectedAccountID,
                        displayName: existingDisplayName ?? activeConnection.displayName
                    )
                )
                states[activeConnection.toolkitSlug] = .connected
            }
        } catch {
            // Existing records are still checked individually below. A list
            // failure must not turn every known app off at once.
        }
        for (slug, record) in records {
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
                states[slug] = status == ComposioAuthBroker.activeStatus
                    ? .connected
                    : .needsAttention(reason: "Sign-in is no longer active (\(status)).")
            } catch {
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
        userDefaults.set(encoded, forKey: Self.storageKey)
    }

    private func loadRecords() {
        guard let data = userDefaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: ComposioConnectionRecord].self, from: data) else {
            return
        }
        records = decoded
    }
}
