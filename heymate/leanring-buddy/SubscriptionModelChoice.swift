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
    case fable
    case opus
    case sonnet
    case haiku

    var displayName: String {
        switch self {
        case .fable: return "Fable"
        case .opus: return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku: return "Haiku"
        }
    }

    var summary: String {
        switch self {
        case .fable: return "Latest, strongest at the screen"
        case .opus: return "Deepest for hard problems"
        case .sonnet: return "Balanced everyday choice"
        case .haiku: return "Fastest for quick work"
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
