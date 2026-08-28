//
//  AgentEscalation.swift
//  leanring-buddy
//
//  Post-hoc gate: if Talk just refused a filesystem/agent-suitable request,
//  hand the same transcript to a headless agent. This is not a router.
//

import Foundation

nonisolated enum AgentEscalation {

    static func shouldEscalate(responseText: String, transcript: String) -> Bool {
        let normalizedTranscript = SpokenText.normalizedSpokenCommandText(transcript)
        guard isAgentSuitableTask(transcript, normalizedTranscript: normalizedTranscript) else {
            return false
        }
        guard !isScreenQuestion(normalizedTranscript) else { return false }

        let normalizedResponse = SpokenText.normalizedSpokenCommandText(responseText)
        if normalizedResponse.range(of: filesystemRefusalPattern, options: .regularExpression) != nil {
            return true
        }
        return agentRouteRefusalPatterns.contains {
            normalizedResponse.range(of: $0, options: .regularExpression) != nil
        }
    }

    /// Instruction to hand the coding agent when escalating a Talk refusal.
    static func agentInstruction(from transcript: String) -> String {
        if let parsed = AgentInvocation.parse(transcript), !parsed.isEmpty {
            return parsed
        }
        let candidate = SpokenText.normalizedAgentTaskInstruction(from: transcript)
        if isFilesystemInspectionRequest(SpokenText.normalizedSpokenCommandText(candidate)) {
            return "Inspect the relevant local files or folders for this request, then answer succinctly: \(candidate)"
        }
        return SpokenText.cleanedAgentTaskInstruction(candidate)
    }

    private static func isAgentSuitableTask(
        _ transcript: String,
        normalizedTranscript: String
    ) -> Bool {
        if AgentInvocation.isAgentRequest(transcript) { return true }
        if isFilesystemInspectionRequest(normalizedTranscript) { return true }
        return VoiceRouter.looksLikeAgentWork(normalizedTranscript)
    }

    static func isFilesystemInspectionRequest(_ normalized: String) -> Bool {
        let actionPattern = #"\b(?:whats\s+on|what\s+is\s+on|what\s+files|list|show|check|inspect|review|find|search|look\s+at|read|summari[sz]e)\b"#
        let interrogativePattern = #"\b(?:what|which)\b"#
        let filesystemTargetPattern = #"\b(?:desktop|downloads?|documents?|folder|folders|file|files|directory|directories)\b"#
        let hasTarget = normalized.range(of: filesystemTargetPattern, options: .regularExpression) != nil
        let hasAction = normalized.range(of: actionPattern, options: .regularExpression) != nil
        let hasInterrogative = normalized.range(of: interrogativePattern, options: .regularExpression) != nil
        return hasTarget && (hasAction || hasInterrogative)
    }

    static func isScreenQuestion(_ normalized: String) -> Bool {
        let pattern = #"\b(?:whats\s+on\s+my\s+screen|what\s+is\s+on\s+my\s+screen|on\s+my\s+screen|this\s+screen)\b"#
        return normalized.range(of: pattern, options: .regularExpression) != nil
    }

    private static let filesystemRefusalPattern =
        #"\b(?:i\s+(?:do\s+not|dont)\s+have\s+access|i\s+(?:cant|cannot)|unable\s+to|not\s+able\s+to)\b.{0,96}\b(?:file\s*system|files?|folders?|desktop|downloads?|documents?|browse|inspect|read)\b"#

    private static let agentRouteRefusalPatterns = [
        #"\bthat\s+needs\s+heymates?\s+agent\b"#,
        #"\bit\s+did(?:nt| not)\s+start\s+from\s+this\s+voice\s+turn\b"#,
        #"\bneeds\s+agent\s+mode\b"#,
        #"\bstart\s+an\s+agent\b"#
    ]
}
