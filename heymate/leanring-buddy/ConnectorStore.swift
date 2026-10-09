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
    /// now: enabled AND currently connected. Extra custom MCP servers are
    /// not in the static catalog, so they are appended from stored records.
    var activeConnectors: [Connector] {
        let catalogued = ConnectorCatalog.all.filter { connector in
            record(for: connector.id).isEnabled && connectionState(for: connector.id).isConnected
        }
        let additional = additionalCustomMCPConnectors().filter { connector in
            record(for: connector.id).isEnabled && connectionState(for: connector.id).isConnected
        }
        return catalogued + additional
    }

    /// Every stored server whose id is `mcp-custom-` plus a UUID, whether
    /// or not it is currently connected. `ConnectorRuntime` restores the
    /// enabled ones through the same connect path as catalog MCP servers.
    func additionalCustomMCPConnectors() -> [Connector] {
        records.keys
            .filter { ConnectorCatalog.isAdditionalCustomMCPID($0) }
            .sorted()
            .map { id in
                let command = records[id]?.customLaunchCommand
                return ConnectorCatalog.userSuppliedMCPConnector(
                    id: id,
                    displayName: ConnectorCatalog.displayName(forCustomLaunchCommand: command),
                    summary: command
                )
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

    /// Drops an extra custom MCP server entirely. The first server
    /// (`mcp-custom`) stays in the catalog, so clearing it is
    /// `setCustomLaunchCommand(nil:)` rather than deleting the record.
    func removeAdditionalCustomMCP(connectorID: String) {
        guard ConnectorCatalog.isAdditionalCustomMCPID(connectorID) else { return }
        records.removeValue(forKey: connectorID)
        connectionStates.removeValue(forKey: connectorID)
        persistRecords()
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
        // Drop records for connectors that no longer exist. Extra custom
        // MCP servers are synthesized by `connector(withID:)`, so a
        // `mcp-custom-` record survives a relaunch.
        records = decoded.filter { ConnectorCatalog.connector(withID: $0.key) != nil }
    }
}

// MARK: - Secrets

/// Storage for connector credentials: the Composio key, a custom API key,
/// MCP connector keys, ElevenLabs. Deliberately tiny, and no logging of any
/// value.
///
/// ## Why a private file and not the Keychain
///
/// A legacy Keychain item remembers which app may read it. An app with no
/// Apple Team ID is remembered by the exact hash of that build, so every
/// HeyMate update — self-signed, by choice, not Developer ID — lost access
/// and macOS asked for the login password again, once per key, even after
/// "Always Allow". The keys now live in one file only this user can read
/// (directory 0700, file 0600), the same place the `codex`, `claude`, and
/// `gh` CLIs keep their tokens. Any program running as this user could read
/// it, as it can read theirs; FileVault encrypts it at rest.
///
/// Keys saved by an older build are still in the Keychain. The first read of
/// each copies it into the file and deletes the Keychain item — one last
/// panel, then never again.
///
/// `secret` caches per process, including a *refusal* of that one-time
/// migration panel: several callers read one key in a row, and one cancelled
/// panel must not become four more.
enum ConnectorSecretStore {

    private static let legacyKeychainService = "com.heymate.app.connector"

    /// Where the keys live. Tests point it somewhere disposable.
    nonisolated(unsafe) static var fileURL: URL = isRunningTests ? scratchFileURL : defaultFileURL

    /// The unit tests run inside the real app, so without this a test that
    /// saves or deletes a key would do it to the user's own keys.
    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private static var scratchFileURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-test-secrets-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            .appendingPathComponent("connector-secrets.json", isDirectory: false)
    }

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("heymate", isDirectory: true)
            .appendingPathComponent("secrets", isDirectory: true)
            .appendingPathComponent("connector-secrets.json", isDirectory: false)
    }

    /// Off in tests, so a test run never touches the user's real Keychain.
    nonisolated(unsafe) static var migratesFromKeychain = !isRunningTests

    private enum CachedOutcome {
        case value(String)
        case absent
        case refused
    }

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

        func reset() {
            lock.lock()
            storage = [:]
            lock.unlock()
        }
    }

    private static let cache = SecretCache()
    /// Serialises read-modify-write of the file.
    private static let fileLock = NSLock()

    /// Test hook: forget everything cached in this process.
    static func resetCacheForTesting() {
        cache.reset()
    }

    @discardableResult
    static func setSecret(_ secret: String, forConnectorID connectorID: String) -> Bool {
        let didWrite = updateFile { $0[connectorID] = secret }
        if didWrite {
            // A newer value supersedes anything an older build left behind.
            deleteLegacyKeychainItem(forConnectorID: connectorID)
        }
        cache.store(didWrite ? .value(secret) : .absent, for: connectorID)
        return didWrite
    }

    /// Reads the stored value. Only the one-time migration of a key an older
    /// build saved can show a system panel.
    ///
    /// Returns nil without asking again if the user already dismissed that
    /// panel this session. `retryRefusedSecrets()` lifts that.
    static func secret(forConnectorID connectorID: String) -> String? {
        switch cache.cached(connectorID) {
        case .value(let cachedValue): return cachedValue
        case .absent, .refused: return nil
        case nil: break
        }

        if let value = readFile()[connectorID] {
            cache.store(.value(value), for: connectorID)
            return value
        }

        switch readLegacyKeychainItem(forConnectorID: connectorID) {
        case .value(let value):
            // Only drop the Keychain copy once the file holds the key.
            if updateFile({ $0[connectorID] = value }) {
                deleteLegacyKeychainItem(forConnectorID: connectorID)
            }
            cache.store(.value(value), for: connectorID)
            return value
        case .absent:
            cache.store(.absent, for: connectorID)
            return nil
        case .refused:
            cache.store(.refused, for: connectorID)
            return nil
        }
    }

    /// Clears remembered refusals so a deliberate user action — clicking
    /// Connect, entering a key — gets a fresh attempt at the migration panel.
    static func retryRefusedSecrets() {
        cache.clearRefusals()
    }

    /// Whether a secret is stored, without ever showing a panel. Safe from a
    /// view body or at launch.
    static func hasSecret(forConnectorID connectorID: String) -> Bool {
        switch cache.cached(connectorID) {
        case .value: return true
        case .absent: return false
        case .refused, nil: break
        }
        if readFile()[connectorID] != nil { return true }
        return legacyKeychainItemExists(forConnectorID: connectorID)
    }

    @discardableResult
    static func deleteSecret(forConnectorID connectorID: String) -> Bool {
        cache.invalidate(connectorID)
        let removedFromFile = updateFile { $0[connectorID] = nil }
        let removedFromKeychain = deleteLegacyKeychainItem(forConnectorID: connectorID)
        return removedFromFile && removedFromKeychain
    }

    // MARK: - File

    private static func readFile() -> [String: String] {
        fileLock.lock()
        defer { fileLock.unlock() }
        return unlockedRead()
    }

    private static func unlockedRead() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }

    /// Applies `change` and writes the result atomically, created with
    /// owner-only permissions so the keys are never briefly world-readable.
    @discardableResult
    private static func updateFile(_ change: (inout [String: String]) -> Void) -> Bool {
        fileLock.lock()
        defer { fileLock.unlock() }
        var secrets = unlockedRead()
        let before = secrets
        change(&secrets)
        if secrets == before, FileManager.default.fileExists(atPath: fileURL.path) || secrets.isEmpty {
            return true
        }
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // An existing directory keeps whatever mode it had; tighten it.
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONEncoder().encode(secrets)
            let temporaryURL = directory.appendingPathComponent(".connector-secrets-\(UUID().uuidString)")
            guard fileManager.createFile(
                atPath: temporaryURL.path,
                contents: data,
                attributes: [.posixPermissions: 0o600]
            ) else { return false }
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Keychain left by older builds

    private static func readLegacyKeychainItem(forConnectorID connectorID: String) -> CachedOutcome {
        guard migratesFromKeychain else { return .absent }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: connectorID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return .refused }
        return .value(value)
    }

    /// Attributes only: an existence check never needs the item unlocked,
    /// so it never shows a panel.
    private static func legacyKeychainItemExists(forConnectorID connectorID: String) -> Bool {
        guard migratesFromKeychain else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: connectorID,
            kSecReturnData as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    @discardableResult
    private static func deleteLegacyKeychainItem(forConnectorID connectorID: String) -> Bool {
        guard migratesFromKeychain else { return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: connectorID
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
