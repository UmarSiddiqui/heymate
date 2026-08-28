//
//  Connector.swift
//  leanring-buddy
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
