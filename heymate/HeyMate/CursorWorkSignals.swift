//
//  CursorWorkSignals.swift
//  HeyMate
//
//  What the thinking cursor shows about the work behind it: how fast the
//  reply is streaming (a smoothed tokens-per-second pace) and what kind of
//  step the agent is on (read, write, web, a tool). Pure values; the
//  overlay samples them and the spinner draws them.
//

import Foundation

/// How hard the reply is working, from the streamed text's growth.
nonisolated struct CursorWorkPace: Equatable {
    enum Tempo: Equatable {
        case calm, busy, racing

        /// Seconds per orbit of the thinking spinner.
        var orbitSeconds: Double {
            switch self {
            case .calm: return 1.25
            case .busy: return 0.85
            case .racing: return 0.55
            }
        }
    }

    /// Rough tokens per character of streamed English text.
    static let charactersPerToken = 4.0
    static let busyThreshold = 8.0
    static let racingThreshold = 28.0

    private(set) var tokensPerSecond: Double?
    private var lastLength: Int?
    private var lastTime: TimeInterval?

    var tempo: Tempo {
        guard let rate = tokensPerSecond else { return .calm }
        if rate >= Self.racingThreshold { return .racing }
        if rate >= Self.busyThreshold { return .busy }
        return .calm
    }

    /// Folds in the streamed text length at `time`. The first sample only
    /// sets the baseline; a shrinking text (a new reply) counts as zero.
    mutating func sample(textLength: Int, at time: TimeInterval) {
        defer {
            lastLength = textLength
            lastTime = time
        }
        guard let lastLength, let lastTime else { return }
        let interval = max(0.25, time - lastTime)
        let tokens = Double(max(0, textLength - lastLength)) / Self.charactersPerToken
        let rate = tokens / interval
        tokensPerSecond = tokensPerSecond.map { 0.65 * $0 + 0.35 * rate } ?? rate
    }
}

/// The kind of step the agent is on, read from its latest progress line.
nonisolated enum CursorActivityKind: Equatable {
    case reasoning, reading, writing, web, image, tool

    /// SF Symbol drawn beside the spinner.
    var symbolName: String {
        switch self {
        case .reasoning: return "sparkle"
        case .reading: return "doc.text"
        case .writing: return "pencil"
        case .web: return "globe"
        case .image: return "photo"
        case .tool: return "wrench.and.screwdriver"
        }
    }

    /// First matching rule wins; nil when the line says nothing specific.
    static func classify(_ text: String?) -> CursorActivityKind? {
        guard let lowered = text?.lowercased(), !lowered.isEmpty else { return nil }
        let rules: [(CursorActivityKind, [String])] = [
            (.web, ["web", "search", "browse", "http", "url", "fetch"]),
            (.image, ["image", "photo", "screenshot"]),
            (.writing, ["write", "edit", "patch", "creat", "sav", "updat"]),
            (.reading, ["read", "open", "load", "list", "view"]),
            (.tool, ["tool", "command", "shell", "terminal", "bash", "run"]),
            (.reasoning, ["think", "reason", "plan", "condens"]),
        ]
        return rules.first { _, words in words.contains { lowered.contains($0) } }?.0
    }
}
