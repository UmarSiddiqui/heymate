//
//  AgentBrain.swift
//  leanring-buddy
//
//  One choice: what is running HeyMate.
//
//  This replaces a pair of pickers that both called themselves the brain — an
//  "AI engine" for Talk and an "agent executor" for jobs — with different
//  vocabularies in different places. It also removes the shipped
//  Anthropic-API-key path: that was a metered key behind a proxy, which is the
//  opposite of the point when the whole design is to run on subscriptions the
//  user already pays for. Anyone who wants their own endpoint sets it up under
//  `.customAPI` with their own key.
//
//  ## Why Talk is not simply "the brain too"
//
//  A CLI cannot answer a screen question. Measured on this machine, a single
//  `claude -p` turn with a screenshot attached took **13 seconds** — process
//  boot, tool load, file read — against a Talk budget of about one. So the
//  brain picks who does the *work*, and screen questions go to whichever fast
//  vision endpoint is configured. `talkNeedsSeparateVisionEndpoint` is how the
//  UI says that out loud rather than leaving the user to discover it.
//

import Foundation

/// The single user-facing choice of what powers HeyMate.
nonisolated enum AgentBrain: String, CaseIterable, Hashable, Codable {
    /// ChatGPT subscription, through the `codex` CLI.
    case codex
    /// Claude subscription, through the `claude` CLI.
    case claudeCode
    /// Any provider you have configured in `opencode`.
    case openCode
    /// Your own Anthropic-compatible endpoint and key.
    case customAPI

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude"
        case .openCode: return "OpenCode"
        case .customAPI: return "Custom API"
        }
    }

    /// One line under the picker: what this actually costs you.
    var subtitle: String {
        switch self {
        case .codex:
            return "Your ChatGPT subscription, through the codex CLI."
        case .claudeCode:
            return "Your Claude subscription, through the claude CLI."
        case .openCode:
            return "Whatever providers you have signed in to opencode."
        case .customAPI:
            return "Your own Anthropic-compatible endpoint and key. You pay per token."
        }
    }

    /// Which CLI runs agent jobs. Nil means this brain does not spawn agents —
    /// `.customAPI` is an endpoint, not a coding agent.
    var executor: HeadlessExecutor? {
        switch self {
        case .claudeCode: return .claudeCode
        case .openCode: return .openCode
        case .codex: return .codex
        case .customAPI: return nil
        }
    }

    /// Non-nil when the brain cannot run a job yet, phrased as something the
    /// user can act on.
    var unavailableReason: String? {
        switch self {
        case .customAPI:
            return "A custom endpoint answers screen questions. It does not run agent jobs — pick Claude, Codex, or OpenCode for those."
        case .claudeCode, .openCode, .codex:
            return nil
        }
    }

    /// True when Talk cannot use this brain directly and needs a configured
    /// vision endpoint instead. Claude and Codex Talk now go through the
    /// signed-in CLI (slower than HTTP, but it actually answers).
    var talkNeedsSeparateVisionEndpoint: Bool {
        false
    }

    /// Claude Code is the default: it is the subscription most likely to
    /// already be signed in, and its stream format is the most stable of the
    /// CLIs HeyMate spawns.
    static func fromUserDefaults() -> AgentBrain {
        let storedRawValue = UserDefaults.standard.string(forKey: "selectedAgentBrain")
        if let stored = AgentBrain(rawValue: storedRawValue ?? "") { return stored }

        // Migration: the old key held an AIEngine. "openCode" carries over by
        // name; "cloudProxy" was the shipped metered key, which no longer
        // exists — those users land on the subscription instead.
        let legacyEngine = UserDefaults.standard.string(forKey: "selectedAIEngine")
        return legacyEngine == "openCode" ? .openCode : .claudeCode
    }
}

/// Where a `.customAPI` brain points, and the key it uses.
///
/// The URL is a preference; the key is a credential and lives in the Keychain
/// with every other secret this app holds — never in UserDefaults.
nonisolated enum CustomAPIConfiguration {

    static let keychainIdentifier = "heymate.customAPI"
    private static let baseURLKey = "customAPIBaseURL"
    private static let modelKey = "customAPIModel"

    /// Anthropic's own Messages endpoint, so the field has a working example
    /// in it rather than a placeholder nobody can guess.
    static let defaultBaseURL = "https://api.anthropic.com/v1/messages"
    static let defaultModel = "claude-sonnet-4-6"

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: baseURLKey) }
    }

    static var model: String {
        get {
            let stored = UserDefaults.standard.string(forKey: modelKey) ?? ""
            return stored.isEmpty ? defaultModel : stored
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: modelKey) }
    }

    static func apiKey() -> String? {
        ConnectorSecretStore.secret(forConnectorID: keychainIdentifier)
    }

    @discardableResult
    static func setAPIKey(_ apiKey: String) -> Bool {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ConnectorSecretStore.deleteSecret(forConnectorID: keychainIdentifier)
        }
        return ConnectorSecretStore.setSecret(trimmed, forConnectorID: keychainIdentifier)
    }

    static var hasAPIKey: Bool {
        ConnectorSecretStore.hasSecret(forConnectorID: keychainIdentifier)
    }

    /// A URL alone is enough when it points at a proxy that holds the key.
    static var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when Talk should POST here instead of spawning the signed-in CLI.
    ///
    /// The default Anthropic Messages URL without a key is *not* usable —
    /// that combination is what previously produced silent 401s. A different
    /// URL is assumed to be a proxy that already holds the credential.
    static var isUsableForTalk: Bool {
        if hasAPIKey { return isConfigured }
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != defaultBaseURL
    }
}
