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

        let explicitVisualCue = #"\b(?:screen|display|window|page|button|menu|icon|field|selected|highlighted|visible|cursor|point|click|press|scroll)\b"#
        return normalized.range(of: explicitVisualCue, options: .regularExpression) != nil
    }
}
