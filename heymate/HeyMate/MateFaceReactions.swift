import Foundation

/// Short motions layered on top of a mate face's expression: a click says
/// hello, a finished job celebrates, a failed one wobbles. Each one plays
/// once and settles back to the resting pose.
nonisolated enum MateFaceReaction: String, CaseIterable, Equatable {
    case wink
    case boop
    case giggle
    case celebrate
    case wobble

    var duration: Double {
        switch self {
        case .wink: return 0.6
        case .boop: return 0.65
        case .giggle: return 0.8
        case .celebrate: return 1.2
        case .wobble: return 0.65
        }
    }

    /// A double click giggles. A single click winks on the upper half of
    /// the face and boops on the lower half. `normalizedY` runs 0 (top) to 1.
    static func forTap(count: Int, normalizedY: Double) -> Self {
        if count >= 2 { return .giggle }
        return normalizedY < 0.5 ? .wink : .boop
    }

    /// What a job's end looks like on its mate's face.
    static func forFinished(_ status: AgentRunStatus) -> Self? {
        switch status {
        case .succeeded: return .celebrate
        case .failed: return .wobble
        default: return nil
        }
    }
}

/// One reaction request. A new `id` plays once; repeating an id does nothing.
nonisolated struct MateReactionEvent: Equatable {
    let id: String
    let reaction: MateFaceReaction
}

/// The offsets a reaction adds to the face at a moment in time. Sizes are
/// fractions of the face's side so every surface scales the same motion.
nonisolated struct MateReactionPose: Equatable {
    var leftEyeOpen: Double = 1
    var rightEyeOpen: Double = 1
    var squashX: Double = 1
    var squashY: Double = 1
    /// Vertical offset; negative lifts the face.
    var lift: Double = 0
    var shake: Double = 0
    /// Degrees.
    var tilt: Double = 0
    /// Extra cheek colour, 0…1.
    var flush: Double = 0

    static func sample(_ reaction: MateFaceReaction?, elapsed: Double) -> Self {
        guard let reaction, elapsed.isFinite, elapsed >= 0, elapsed < reaction.duration else { return Self() }
        var pose = Self()
        switch reaction {
        case .wink:
            pose.rightEyeOpen = 1 - 0.94 * bump(elapsed / reaction.duration)
            pose.flush = 0.4 * bump(elapsed / reaction.duration)
        case .boop:
            let squash = bump(min(elapsed / 0.38, 1))
            pose.squashY = 1 - 0.05 * squash
            pose.squashX = 1 + 0.035 * squash
            pose.flush = 0.8 * bump(elapsed / 0.65)
            pose.leftEyeOpen = blink(elapsed)
            pose.rightEyeOpen = pose.leftEyeOpen
        case .giggle:
            let fade = 1 - elapsed / reaction.duration
            pose.shake = sin(elapsed * 2 * .pi * 6) * 0.012 * fade
            pose.lift = -abs(sin(elapsed * 2 * .pi * 3)) * 0.018 * fade
            pose.leftEyeOpen = 1 - 0.55 * bump(elapsed / reaction.duration)
            pose.rightEyeOpen = pose.leftEyeOpen
            pose.flush = 0.5 * bump(elapsed / reaction.duration)
        case .celebrate:
            let hop = min(elapsed / 0.92, 1)
            pose.lift = -sin(hop * .pi) * 0.07
            // Squash on take-off and landing, stretch at the top.
            let land = bump(min(max(elapsed - 0.82, 0) / 0.3, 1))
            pose.squashY = 1 + 0.04 * sin(hop * .pi) - 0.05 * land
            pose.squashX = 1 - 0.025 * sin(hop * .pi) + 0.035 * land
            pose.leftEyeOpen = 1 - 0.5 * bump(elapsed / reaction.duration)
            pose.rightEyeOpen = pose.leftEyeOpen
            pose.flush = 0.6 * bump(elapsed / reaction.duration)
        case .wobble:
            let progress = elapsed / reaction.duration
            pose.tilt = sin(progress * .pi * 4) * 7 * (1 - progress)
        }
        return pose
    }

    /// 0 → 1 → 0 over `progress` 0…1, eased at both ends.
    private static func bump(_ progress: Double) -> Double {
        sin(min(max(progress, 0), 1) * .pi)
    }

    /// A 0.19 s blink: closed in the middle third.
    private static func blink(_ elapsed: Double) -> Double {
        guard elapsed < 0.19 else { return 1 }
        return 1 - 0.94 * bump(elapsed / 0.19)
    }
}

/// Holds a reaction that arrives while the face is hidden. If the face shows
/// up within `lifetime` the reaction plays once; after that it is dropped,
/// so opening a window later never replays stale news.
nonisolated struct MateReactionInbox: Equatable {
    static let lifetime: TimeInterval = 2

    private(set) var pending: MateReactionEvent?
    private var offeredAt: Date?
    private var seen: [String] = []

    /// False when this id was already offered.
    @discardableResult
    mutating func offer(_ event: MateReactionEvent, at now: Date) -> Bool {
        guard !seen.contains(event.id) else { return false }
        seen.append(event.id)
        if seen.count > 32 { seen.removeFirst(seen.count - 32) }
        pending = event
        offeredAt = now
        return true
    }

    /// The reaction to play now, if the face is visible and it isn't stale.
    mutating func take(isVisible: Bool, at now: Date) -> MateFaceReaction? {
        guard let pending, let offeredAt else { return nil }
        if now.timeIntervalSince(offeredAt) > Self.lifetime {
            clear()
            return nil
        }
        guard isVisible else { return nil }
        clear()
        return pending.reaction
    }

    mutating func clear() {
        pending = nil
        offeredAt = nil
    }
}

/// What a running job is doing, read from its latest progress line, so the
/// face shows reading, writing, tools or the web instead of one "busy" look.
nonisolated enum MateWorkActivity {
    private static let rules: [(prefixes: [String], expression: MateFaceExpression)] = [
        (["reason", "think", "plan"], .thinking),
        (["web", "search", "brows", "http", "url", "fetch", "google"], .browsing),
        (["writ", "edit", "patch", "creat", "updat", "sav", "appl", "draft", "chang"], .writing),
        (["read", "open", "view", "look", "inspect", "scan", "check", "review"], .reading),
        (["tool", "command", "shell", "terminal", "run", "exec", "build", "test", "install"], .tooling),
    ]

    static func expression(for text: String) -> MateFaceExpression {
        match(for: text) ?? .thinking
    }

    /// The first rule the text matches, or nil when it says nothing about
    /// the kind of work. The notch character walks instead of guessing.
    static func match(for text: String) -> MateFaceExpression? {
        let words = text.lowercased()
            .split { !$0.isLetter }
            .map(String.init)
        for rule in rules where words.contains(where: { word in rule.prefixes.contains { word.hasPrefix($0) } }) {
            return rule.expression
        }
        return nil
    }
}
