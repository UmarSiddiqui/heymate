//
//  SubscriptionModelChoice.swift
//  leanring-buddy
//
//  Static aliases exposed by Claude CLI. Codex choices come from its live
//  app-server model catalog; see CodexModelCatalog.swift.
//

import Foundation

/// What `claude -p --model` is given when Claude is the brain.
nonisolated enum ClaudeModelChoice: String, CaseIterable, Hashable {
    case haiku
    case sonnet
    case opus

    var displayName: String {
        switch self {
        case .haiku: return "Haiku"
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        }
    }

    /// CLI aliases from `claude --help`: "sonnet", "opus", "haiku".
    var cliIdentifier: String { rawValue }

    static let persistenceKey = "selectedClaudeModel"

    static func fromUserDefaults() -> ClaudeModelChoice {
        ClaudeModelChoice(rawValue: UserDefaults.standard.string(forKey: persistenceKey) ?? "")
            ?? .sonnet
    }
}
