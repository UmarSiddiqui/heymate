//
//  ElevenLabsCredentials.swift
//  leanring-buddy
//
//  Where ElevenLabs requests get their authority from. Two routes:
//
//  - the user's own ElevenLabs API key, pasted in Settings and kept in the
//    Keychain (or ELEVENLABS_API_KEY in the developer secrets file). Requests
//    then go straight to api.elevenlabs.io.
//  - the HeyMate Worker, for a developer who runs it with
//    HEYMATE_CLIENT_TOKEN. The Worker holds the key and mints Scribe tokens.
//
//  HeyMate ships no shared ElevenLabs key, so a release build without either
//  of these has no ElevenLabs at all and stays on the on-device or Mac voices.
//

import Foundation

enum ElevenLabsCredentials {
    /// Keychain account for the pasted key. Shares the connector secret
    /// service so it gets the same access rules as other pasted keys.
    static let keychainSecretID = "elevenlabs-voice"

    static let apiBaseURLString = "https://api.elevenlabs.io"

    /// The user's own key, or nil. Reading it can surface the Keychain panel,
    /// so only call this right before a request.
    static func userAPIKey() -> String? {
        if let storedKey = ConnectorSecretStore.secret(forConnectorID: keychainSecretID)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !storedKey.isEmpty {
            return storedKey
        }
        return HeyMateSecrets.lookup("ELEVENLABS_API_KEY")
    }

    /// Whether a key is stored, without decrypting it.
    static var hasUserAPIKey: Bool {
        ConnectorSecretStore.hasSecret(forConnectorID: keychainSecretID)
            || HeyMateSecrets.lookup("ELEVENLABS_API_KEY") != nil
    }

    /// Whether this build can reach the developer's Worker.
    static var hasWorkerAccess: Bool {
        HeyMateSecrets.lookup(BackendClient.clientTokenSecretsKey) != nil
    }

    static var isAvailable: Bool {
        hasUserAPIKey || hasWorkerAccess
    }

    static var workerBaseURLString: String {
        AppBundleConfiguration.stringValue(forKey: "WorkerBaseURL")
            ?? "https://your-worker-name.your-subdomain.workers.dev"
    }

    @discardableResult
    static func saveUserAPIKey(_ apiKey: String) -> Bool {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return false }
        return ConnectorSecretStore.setSecret(trimmedKey, forConnectorID: keychainSecretID)
    }

    static func removeUserAPIKey() {
        ConnectorSecretStore.deleteSecret(forConnectorID: keychainSecretID)
    }
}
