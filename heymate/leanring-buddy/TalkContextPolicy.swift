//
//  TalkContextPolicy.swift
//  leanring-buddy
//

import Foundation

/// Decides whether Talk needs screen pixels. Ordinary conversation stays
/// text-only and can use Codex Spark; visible/referential requests keep vision.
nonisolated enum TalkContextPolicy {
    static func shouldCaptureScreen(
        for transcript: String,
        hasSpatialSelection: Bool
    ) -> Bool {
        if hasSpatialSelection { return true }

        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
        if VoiceRouter.isScreenQuestion(normalized)
            || VoiceRouter.containsReferentialWorkTarget(normalized) {
            return true
        }

        if VoiceRouter.isPerceptionQuestion(normalized) { return true }

        let explicitVisualCue = #"\b(?:screen|display|window|page|button|menu|icon|field|selected|highlighted|visible|cursor|point|click|press|scroll)\b"#
        return normalized.range(of: explicitVisualCue, options: .regularExpression) != nil
    }

    /// Typed chat inside HeyMate must not attach a picture of HeyMate.
    /// Voice and dictation in another app still may.
    static func allowCapture(
        wantsScreen: Bool,
        typedInsideHeyMate: Bool,
        frontmostIsHeyMate: Bool,
        hasSpatialSelection: Bool = false
    ) -> Bool {
        if hasSpatialSelection { return true }
        if typedInsideHeyMate && frontmostIsHeyMate { return false }
        return wantsScreen
    }

    /// Replay keeps words. It drops lines that point at an earlier screenshot
    /// so a later turn does not carry that image along.
    static func withoutPriorScreenshots(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let folded = line.lowercased()
                if folded.contains("heymate-talk-") { return false }
                if folded.hasPrefix("screenshot ") { return false }
                if folded.contains(".jpg"), folded.contains("/") { return false }
                return true
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
