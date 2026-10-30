//
//  TalkContextPolicy.swift
//  HeyMate
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
        if asksToActOnScreen(transcript) { return true }

        // "how do i export this" and "walk me through it" are asking to be
        // shown, and showing needs the screen the buddy will point at.
        let guidanceCue = #"^(?:how\s+(?:do|can|would|should)\s+i|where\s+(?:is|are|do\s+i|can\s+i)|wheres|show\s+me|walk\s+me\s+through|guide\s+me|teach\s+me|help\s+me\s+(?:find|get\s+to|set\s+up|use))\b"#
        if normalized.range(of: guidanceCue, options: .regularExpression) != nil { return true }

        let explicitVisualCue = #"\b(?:screen|display|window|page|button|menu|icon|field|selected|highlighted|visible|cursor|point|click|press|scroll)\b"#
        return normalized.range(of: explicitVisualCue, options: .regularExpression) != nil
    }

    /// "Use the browser to …", "open chrome", "go to my inbox": the request
    /// names no screen word, yet the work happens on screen and starts from
    /// what is open now.
    static func asksToActOnScreen(_ transcript: String) -> Bool {
        let candidate = SpokenText.normalizedCommandCandidate(from: transcript)
        let normalized = SpokenText.normalizedSpokenCommandText(candidate)
        let surface = #"\b(?:browser|chrome|safari|firefox|tab|tabs|website|webpage|url)\b"#
        if normalized.range(of: surface, options: .regularExpression) != nil { return true }
        let action = #"^(?:(?:can|could|would|will)\s+you\s+|please\s+)?(?:open|go\s+to|navigate\s+to|search\s+(?:for|on)|look\s+up|switch\s+to|fill\s+(?:in|out)|use\s+(?:the\s+|my\s+)?(?:computer|mac))\b"#
        return normalized.range(of: action, options: .regularExpression) != nil
    }

    /// Typed chat inside HeyMate must not attach a picture of HeyMate.
    /// Voice and dictation in another app still may. A request to act on
    /// screen still captures: HeyMate's own windows are cut from the
    /// capture, so the model sees the app the user means.
    static func allowCapture(
        wantsScreen: Bool,
        typedInsideHeyMate: Bool,
        frontmostIsHeyMate: Bool,
        hasSpatialSelection: Bool = false,
        actsOnScreen: Bool = false
    ) -> Bool {
        if hasSpatialSelection { return true }
        if typedInsideHeyMate && frontmostIsHeyMate { return actsOnScreen }
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
