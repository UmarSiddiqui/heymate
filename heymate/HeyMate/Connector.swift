//
//  Connector.swift
//  HeyMate
//
//  What HeyMate can reach outside this Mac.
//
//  A connector is a *description*, not an implementation: an identity, the
//  way it authenticates, the tools it contributes to the agent runtime,
//  and the risk level of each. Four transports cover essentially every
//  service worth connecting, and only one of them needs us to run a
//  backend:
//
//    .mcp        — a Model Context Protocol server, launched locally or
//                  reached over HTTP. This is the leverage: one client
//                  implementation, and every MCP server in the ecosystem
//                  becomes a HeyMate connector with a catalog entry.
//    .localCLI   — a signed-in command line tool the user already trusts
//                  (`gh`, `gog`, `stripe`). No tokens ever touch HeyMate.
//    .appleNative— EventKit / Contacts / MapKit / Shortcuts. No network,
//                  no account, just a TCC prompt.
//
//  Services that need a vendor account are deliberately absent: those are
//  Composio toolkits, fetched at runtime, connected through
//  `ComposioConnectionsRuntime`. HeyMate holds no refresh tokens.
//
//  Nothing here performs I/O. The catalog is data so it can be rendered,
//  searched, and tested without a network or a running agent.
//

import Foundation
import SwiftUI

// MARK: - Transport

enum ConnectorTransport: String, Codable, Sendable {
    /// Model Context Protocol server (stdio subprocess or HTTP endpoint).
    case mcp
    /// A CLI the user authenticates themselves; HeyMate only shells out.
    case localCLI
    /// A first-party Apple framework, gated by a TCC permission.
    case appleNative
    /// A plain API key the user pastes; stored in the Keychain.
    case apiKey

    var displayName: String {
        switch self {
        case .mcp: return "MCP server"
        case .localCLI: return "Local CLI"
        case .appleNative: return "Built into macOS"
        case .apiKey: return "API key"
        }
    }

    /// Whether connecting this transport can leak credentials off-device.
    /// Used to sort the catalog: local-first options appear first.
    var localityRank: Int {
        switch self {
        case .appleNative: return 0
        case .localCLI: return 1
        case .mcp: return 2
        case .apiKey: return 3
        }
    }
}

// MARK: - Risk

/// Mirrors the tool-risk ladder in the product spec. Levels 2 and 3 always
/// require an explicit approval step before the agent may act.
enum ConnectorToolRisk: Int, Codable, Comparable, Sendable {
    case readOnly = 0
    case reversibleWrite = 1
    case externalSideEffect = 2
    case destructive = 3

    static func < (lhs: ConnectorToolRisk, rhs: ConnectorToolRisk) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var requiresApproval: Bool { self >= .externalSideEffect }

    /// Risk for one named tool, never above the connector's own ceiling.
    ///
    /// A connector's `maximumRisk` describes the worst thing it can do, which
    /// is the right thing to show on its card and the wrong thing to judge
    /// every call by: Composio can delete in someone else's account, so
    /// judging by the ceiling alone puts a destructive-red approval card in
    /// front of a tool search. Discovery then costs a click, a turn stalls
    /// waiting on one, and the model gives up and asks for a screenshot.
    ///
    /// An unrecognised verb falls back to the ceiling. A tool nobody can read
    /// is treated as the most dangerous thing its connector can do, never the
    /// least — so `COMPOSIO_MULTI_EXECUTE_TOOL`, which can run anything, still
    /// stops for a yes.
    static func inferred(forToolNamed toolName: String, ceiling: ConnectorToolRisk) -> ConnectorToolRisk {
        let tokens = Set(tokenize(toolName))
        let inferred: ConnectorToolRisk?
        // Most dangerous first: `list_and_delete` is a delete.
        if !tokens.isDisjoint(with: destructiveVerbs) {
            inferred = .destructive
        } else if !tokens.isDisjoint(with: externalSideEffectVerbs) {
            inferred = .externalSideEffect
        } else if !tokens.isDisjoint(with: writeVerbs) {
            inferred = .reversibleWrite
        } else if !tokens.isDisjoint(with: readVerbs) {
            inferred = .readOnly
        } else {
            inferred = nil
        }
        guard let inferred else { return ceiling }
        return min(inferred, ceiling)
    }

    /// Risk for an actual call. Composio's multi-execute meta-tool hides the
    /// concrete operation in `arguments.tools`, so judging only its outer
    /// name forces approval for harmless reads. Every batch item must expose
    /// a tool slug; malformed or unknown items fail closed at the ceiling.
    static func inferred(
        forToolNamed toolName: String,
        arguments: [String: Any],
        ceiling: ConnectorToolRisk
    ) -> ConnectorToolRisk {
        let tokens = Set(tokenize(toolName))
        guard tokens.contains("composio"),
              tokens.contains("multi"),
              tokens.contains("execute") else {
            return inferred(forToolNamed: toolName, ceiling: ceiling)
        }
        guard let tools = arguments["tools"] as? [Any], !tools.isEmpty else {
            return ceiling
        }
        var batchRisk = ConnectorToolRisk.readOnly
        for value in tools {
            guard let tool = value as? [String: Any],
                  let name = (tool["tool_slug"] as? String)
                    ?? (tool["tool_name"] as? String)
                    ?? (tool["slug"] as? String),
                  !name.isEmpty else {
                return ceiling
            }
            batchRisk = max(batchRisk, inferred(forToolNamed: name, ceiling: ceiling))
        }
        return batchRisk
    }

    /// Whole tokens, never substrings: `forget_account` contains "get" and is
    /// not a read.
    static func tokenize(_ toolName: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in toolName {
            if character == "_" || character == "-" || character == "." || character == " " {
                if !current.isEmpty { tokens.append(current.lowercased()); current = "" }
            } else if character.isUppercase, let last = current.last, last.isLowercase {
                tokens.append(current.lowercased())
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current.lowercased()) }
        return tokens
    }

    private static let destructiveVerbs: Set<String> = [
        "delete", "destroy", "remove", "revoke", "drop", "purge", "erase",
        "wipe", "truncate", "uninstall", "disconnect", "cancel", "terminate"
    ]
    private static let externalSideEffectVerbs: Set<String> = [
        "send", "post", "publish", "share", "email", "message", "invite",
        "reply", "forward", "notify", "broadcast", "submit", "pay", "charge"
    ]
    private static let writeVerbs: Set<String> = [
        "create", "add", "update", "set", "write", "edit", "patch", "upload",
        "insert", "modify", "rename", "move", "copy", "duplicate", "star",
        "label", "tag", "assign", "mark", "archive", "upsert"
    ]
    private static let readVerbs: Set<String> = [
        "search", "list", "get", "read", "fetch", "find", "describe", "schema",
        "schemas", "lookup", "count", "query", "check", "status", "info",
        "view", "show", "download", "export", "analytics", "stats", "metrics"
    ]

    var displayName: String {
        switch self {
        case .readOnly: return "Read only"
        case .reversibleWrite: return "Reversible write"
        case .externalSideEffect: return "Sends or publishes"
        case .destructive: return "Destructive"
        }
    }

    var tintColor: Color {
        switch self {
        case .readOnly: return DS.Colors.success
        case .reversibleWrite: return DS.Colors.info
        case .externalSideEffect: return DS.Colors.warning
        case .destructive: return DS.Colors.destructive
        }
    }
}

// MARK: - Category

enum ConnectorCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case appleBuiltIn = "On this Mac"
    case communication = "Communication"
    case calendarAndTasks = "Calendar & tasks"
    case notesAndDocs = "Notes & docs"
    case developer = "Developer"
    case designAndMedia = "Design & media"
    case dataAndAnalytics = "Data & analytics"
    case commerceAndFinance = "Commerce & finance"
    case cloudAndInfra = "Cloud & infrastructure"
    case webAndResearch = "Web & research"
    case automation = "Automation"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .appleBuiltIn: return "apple.logo"
        case .communication: return "bubble.left.and.bubble.right"
        case .calendarAndTasks: return "calendar"
        case .notesAndDocs: return "doc.text"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .designAndMedia: return "paintbrush.pointed"
        case .dataAndAnalytics: return "chart.bar"
        case .commerceAndFinance: return "creditcard"
        case .cloudAndInfra: return "cloud"
        case .webAndResearch: return "globe"
        case .automation: return "bolt.horizontal"
        }
    }
}

// MARK: - Connector

struct Connector: Identifiable, Equatable, Sendable {
    /// Stable slug and Keychain account name. It must never change once
    /// shipped.
    let id: String
    let displayName: String
    let summary: String
    let category: ConnectorCategory
    let transport: ConnectorTransport
    /// SF Symbol used until a real vendor mark is bundled.
    let symbolName: String
    /// Highest risk level any of this connector's tools can reach. Shown on
    /// the card so the user knows before connecting, not after.
    let maximumRisk: ConnectorToolRisk
    /// Human-readable list of what the agent gains. Kept short — these are
    /// read on a card, not in documentation.
    let capabilities: [String]

    /// For `.mcp`: the command (and arguments) that launches the server, or
    /// an `https://` URL for a remote server.
    let mcpLaunchCommand: String?
    /// For `.localCLI`: the executable we probe for on PATH.
    let requiredExecutableName: String?
    /// For `.localCLI`: what to tell the user to run if it's missing.
    let installHint: String?

    init(
        id: String,
        displayName: String,
        summary: String,
        category: ConnectorCategory,
        transport: ConnectorTransport,
        symbolName: String,
        maximumRisk: ConnectorToolRisk,
        capabilities: [String],
        mcpLaunchCommand: String? = nil,
        requiredExecutableName: String? = nil,
        installHint: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.category = category
        self.transport = transport
        self.symbolName = symbolName
        self.maximumRisk = maximumRisk
        self.capabilities = capabilities
        self.mcpLaunchCommand = mcpLaunchCommand
        self.requiredExecutableName = requiredExecutableName
        self.installHint = installHint
    }
}

// MARK: - Connection state

enum ConnectorConnectionState: Equatable, Sendable {
    case notConnected
    /// Browser is open / CLI probe is running / MCP server is starting.
    case connecting
    case connected(accountLabel: String?)
    /// Was connected, now failing — token expired, CLI uninstalled, server
    /// crashed. Distinct from `.notConnected` so the UI can offer "Retry"
    /// instead of "Connect".
    case needsAttention(reason: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var displayName: String {
        switch self {
        case .notConnected: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected(let accountLabel): return accountLabel ?? "Connected"
        case .needsAttention: return "Needs attention"
        }
    }

    var tintColor: Color {
        switch self {
        case .notConnected: return DS.Colors.textTertiary
        case .connecting: return DS.Colors.info
        case .connected: return DS.Colors.success
        case .needsAttention: return DS.Colors.warning
        }
    }
}
