//
//  AgentRunRecovery.swift
//  HeyMate
//
//  Copy and timing helpers for failed-run retry and quick-stop messaging.
//

import Foundation

nonisolated enum AgentRunRecovery {

    /// Seconds from job start to cancel that mark a run as not counting.
    static let quickStopThreshold: TimeInterval = 10

    static func didStopQuickly(
        startedAt: Date?,
        createdAt: Date,
        finishedAt: Date = Date()
    ) -> Bool {
        let start = startedAt ?? createdAt
        return finishedAt.timeIntervalSince(start) <= quickStopThreshold
    }

    /// User message for a failed-run retry leg in the same CLI session.
    static func followUpInstruction(for originalPrompt: String) -> String {
        let trimmedPrompt = originalPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        This run failed earlier. Look at what is already done in this session and workspace, then continue the original task without starting over.

        Original task:
        \(trimmedPrompt)
        """
    }
}
