//
//  ConnectorStore.swift
//  leanring-buddy
//
//  Which connectors are on, what they are allowed to do, and where their
//  secrets live.
//
//  Two storage tiers, deliberately separated:
//
//    UserDefaults — non-secret state: enabled, account label, last error,
//                   per-connector approval policy. Safe to read in tests,
//                   safe to inspect, safe to lose.
//    Keychain     — API keys and MCP server environment secrets. Never in
//                   UserDefaults, never in a plist, never logged.
//

import Combine
import Foundation
import Security

// MARK: - Approval policy

/// How much the user is willing to let a connector do without being asked.
/// Defaults are chosen so no connector can ever take an irreversible
/// external action on its own.
enum ConnectorApprovalPolicy: String, Codable, CaseIterable, Sendable {
    /// Ask before anything at all, including reads.
    case askAlways
    /// Reads run freely; anything that writes or sends asks. Default.
    case askForWrites
    /// Reads and reversible writes run freely; sends and deletes still ask.
    case askForExternalEffects

    var displayName: String {
        switch self {
        case .askAlways: return "Ask every time"
        case .askForWrites: return "Ask before writing"
        case .askForExternalEffects: return "Ask before sending"
        }
    }

    /// The one rule the rest of the app consults. Destructive and external
    /// side effects always require approval regardless of policy — that
    /// floor is not user-configurable on purpose.
    func requiresApproval(forRisk risk: ConnectorToolRisk) -> Bool {
        if risk >= .externalSideEffect { return true }
        switch self {
        case .askAlways: return true
        case .askForWrites: return risk >= .reversibleWrite
        case .askForExternalEffects: return false
        }
    }
}

// MARK: - Persisted record

struct ConnectorRecord: Codable, Equatable, Sendable {
    var connectorID: String
    var isEnabled: Bool
    var accountLabel: String?
    var approvalPolicy: ConnectorApprovalPolicy
    var lastConnectedAt: Date?
    var lastErrorMessage: String?
    /// For `.mcp` connectors the user added themselves.
    var customLaunchCommand: String?
    /// For services signed in through Composio: the connected account to
    /// re-prove at launch. Not a credential — it is useless without the
    /// Composio API key, which lives in the Keychain.
    var composioConnectedAccountID: String?

    init(
        connectorID: String,
        isEnabled: Bool = false,
        accountLabel: String? = nil,
        approvalPolicy: ConnectorApprovalPolicy = .askForWrites,
        lastConnectedAt: Date? = nil,
        lastErrorMessage: String? = nil,
        customLaunchCommand: String? = nil,
        composioConnectedAccountID: String? = nil
    ) {
        self.connectorID = connectorID
        self.isEnabled = isEnabled
        self.accountLabel = accountLabel
        self.approvalPolicy = approvalPolicy
        self.lastConnectedAt = lastConnectedAt
        self.lastErrorMessage = lastErrorMessage
        self.customLaunchCommand = customLaunchCommand
        self.composioConnectedAccountID = composioConnectedAccountID
    }
}

// MARK: - Store

@MainActor
final class ConnectorStore: ObservableObject {

    nonisolated static let recordsPreferenceKey = "connectorRecords"

    @Published private(set) var records: [String: ConnectorRecord] = [:]

    /// Live connection state, rebuilt at launch and updated by the
    /// coordinator. Not persisted — "connected" must be re-proven every
    /// launch rather than remembered optimistically.
    @Published private(set) var connectionStates: [String: ConnectorConnectionState] = [:]

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        loadRecords()
    }

    // MARK: Reading

    func record(for connectorID: String) -> ConnectorRecord {
        records[connectorID] ?? ConnectorRecord(connectorID: connectorID)
    }

    func connectionState(for connectorID: String) -> ConnectorConnectionState {
        connectionStates[connectorID] ?? .notConnected
    }

    func approvalPolicy(for connectorID: String) -> ConnectorApprovalPolicy {
        record(for: connectorID).approvalPolicy
    }

    /// Connectors the agent runtime is allowed to build tools from right
    /// now: enabled AND currently connected.
    var activeConnectors: [Connector] {
        ConnectorCatalog.all.filter { connector in
            record(for: connector.id).isEnabled && connectionState(for: connector.id).isConnected
        }
    }

    var enabledConnectorCount: Int {
        records.values.filter(\.isEnabled).count
    }

    // MARK: Writing

    func setEnabled(_ isEnabled: Bool, for connectorID: String) {
        var updated = record(for: connectorID)
        updated.isEnabled = isEnabled
        if !isEnabled {
            updated.lastErrorMessage = nil
            connectionStates[connectorID] = .notConnected
        }
        save(updated)
    }

    func setApprovalPolicy(_ policy: ConnectorApprovalPolicy, for connectorID: String) {
        var updated = record(for: connectorID)
        updated.approvalPolicy = policy
        save(updated)
    }

    func setCustomLaunchCommand(_ command: String?, for connectorID: String) {
        var updated = record(for: connectorID)
        updated.customLaunchCommand = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        save(updated)
    }

    func setComposioConnectedAccountID(_ identifier: String?, for connectorID: String) {
        var updated = record(for: connectorID)
        updated.composioConnectedAccountID = identifier
        save(updated)
    }

    func markConnected(connectorID: String, accountLabel: String?) {
        var updated = record(for: connectorID)
        updated.isEnabled = true
        updated.accountLabel = accountLabel
        updated.lastConnectedAt = Date()
        updated.lastErrorMessage = nil
        save(updated)
        connectionStates[connectorID] = .connected(accountLabel: accountLabel)
    }

    func markConnecting(connectorID: String) {
        connectionStates[connectorID] = .connecting
    }

    /// Enabled, but still waiting on a permission the user has not been
    /// asked for yet. Deliberately reported as `.notConnected` so the card
    /// offers "Connect" instead of a warning the user cannot act on, and
    /// the record keeps `isEnabled` so the intent survives the launch.
    func markAwaitingConnect(connectorID: String) {
        var updated = record(for: connectorID)
        updated.lastErrorMessage = nil
        save(updated)
        connectionStates[connectorID] = .notConnected
    }

    func markFailed(connectorID: String, reason: String) {
        var updated = record(for: connectorID)
        updated.lastErrorMessage = reason
        save(updated)
        connectionStates[connectorID] = .needsAttention(reason: reason)
    }

    func disconnect(connectorID: String) {
        var updated = record(for: connectorID)
        updated.isEnabled = false
        updated.accountLabel = nil
        updated.lastErrorMessage = nil
        updated.composioConnectedAccountID = nil
        save(updated)
        connectionStates[connectorID] = .notConnected
        ConnectorSecretStore.deleteSecret(forConnectorID: connectorID)
    }

    private func save(_ record: ConnectorRecord) {
        records[record.connectorID] = record
        persistRecords()
    }

    // MARK: Persistence

    private func persistRecords() {
        guard let encoded = try? JSONEncoder().encode(records) else { return }
        userDefaults.set(encoded, forKey: Self.recordsPreferenceKey)
    }

    private func loadRecords() {
        guard let data = userDefaults.data(forKey: Self.recordsPreferenceKey),
              let decoded = try? JSONDecoder().decode([String: ConnectorRecord].self, from: data) else {
            return
        }
        // Drop records for connectors that no longer exist in the catalog
        // so a removed integration cannot linger as an orphan toggle.
        records = decoded.filter { ConnectorCatalog.connector(withID: $0.key) != nil }
    }
}

// MARK: - Secrets

/// Keychain-backed storage for connector credentials. Deliberately tiny:
/// one generic-password item per connector, and no logging of any value.
///
/// Two rules exist purely so macOS never puts an unexplained "HeyMate
/// wants to use your confidential information" panel in front of the user:
///
///   1. `hasSecret` asks for attributes, never for the data. Reading the
///      data is what trips the item's access control; an existence check
///      does not need it, and existence is what most callers — including
///      SwiftUI bodies, which re-run constantly — actually want.
///   2. `secret` caches per process — including a *refusal*. One stored
///      credential is read by several callers in a row (session mint,
///      server environment, revalidation), so without remembering the
///      dismissal, one cancelled panel becomes four more panels. A refusal
///      is the user saying no; asking again immediately just relitigates it.
enum ConnectorSecretStore {

    private static let service = "com.heymate.app.connector"

    /// What a previous read of this key established. Distinguishing
    /// "nothing is stored" from "the user declined to unlock it" is the
    /// whole point: the first is a permanent fact, the second is a decision
    /// that only an explicit user action should be allowed to revisit.
    private enum CachedOutcome {
        case value(String)
        case absent
        case refused
    }

    /// Process-lifetime cache. `@unchecked Sendable` with an explicit lock
    /// because the store is `nonisolated` and read from both the main actor
    /// and background connector work.
    private final class SecretCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: CachedOutcome] = [:]

        func cached(_ key: String) -> CachedOutcome? {
            lock.lock()
            defer { lock.unlock() }
            return storage[key]
        }

        func store(_ outcome: CachedOutcome, for key: String) {
            lock.lock()
            storage[key] = outcome
            lock.unlock()
        }

        /// Forget every refusal so a deliberate retry can ask again. Values
        /// and known-absent entries are kept — neither needs re-proving.
        func clearRefusals() {
            lock.lock()
            storage = storage.filter {
                if case .refused = $0.value { return false }
                return true
            }
            lock.unlock()
        }

        func invalidate(_ key: String) {
            lock.lock()
            storage[key] = nil
            lock.unlock()
        }
    }

    private static let cache = SecretCache()

    @discardableResult
    static func setSecret(_ secret: String, forConnectorID connectorID: String) -> Bool {
        guard let secretData = secret.data(using: .utf8) else { return false }
        deleteSecret(forConnectorID: connectorID)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectorID,
            kSecValueData as String: secretData,
            // The app runs from the menu bar and needs this after unlock,
            // but never while locked and never on another device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let didAdd = SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
        // The value just came from the user, so seeding the cache here means
        // the connect that follows never has to re-read the item.
        cache.store(didAdd ? .value(secret) : .absent, for: connectorID)
        return didAdd
    }

    /// Reads the stored value. This is the one call that can surface the
    /// system's keychain-access panel, so only reach for it when the value
    /// itself is about to be used — never to test for presence.
    ///
    /// Returns nil without asking again if the user already dismissed the
    /// panel this session. `retryRefusedSecrets()` lifts that.
    static func secret(forConnectorID connectorID: String) -> String? {
        switch cache.cached(connectorID) {
        case .value(let cachedValue): return cachedValue
        case .absent, .refused: return nil
        case nil: break
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectorID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            cache.store(status == errSecItemNotFound ? .absent : .refused, for: connectorID)
            return nil
        }
        cache.store(.value(value), for: connectorID)
        return value
    }

    /// Clears remembered refusals so a deliberate user action — clicking
    /// Connect, entering a key — gets a fresh attempt at the panel.
    static func retryRefusedSecrets() {
        cache.clearRefusals()
    }

    /// Whether a secret is stored, without decrypting it. Attribute-only
    /// queries do not trigger the keychain-access panel, which is what makes
    /// this safe to call from a view body or at launch.
    static func hasSecret(forConnectorID connectorID: String) -> Bool {
        switch cache.cached(connectorID) {
        case .value: return true
        case .absent: return false
        // A refusal says nothing about existence — the item is there, the
        // user just did not unlock it. Fall through to the silent check.
        case .refused, nil: break
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectorID,
            kSecReturnData as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    @discardableResult
    static func deleteSecret(forConnectorID connectorID: String) -> Bool {
        cache.invalidate(connectorID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectorID
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
