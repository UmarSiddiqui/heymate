import Foundation

/// Read-only context for the conductor. Never sends a follow-up or launches work.
nonisolated enum HarnessJobStatus {
    static func report(mateName: String, mateID: UUID, runs: [AgentRun]) -> String {
        let owned = runs.filter { $0.chatOwner?.mateID == mateID }
            .sorted { $0.createdAt > $1.createdAt }
        guard !owned.isEmpty else { return "\(mateName): no recorded jobs." }
        // Prioritize live work over terminal history within the context budget.
        let visible = Array((owned.filter { !$0.status.isTerminal } + owned.filter { $0.status.isTerminal }).prefix(6))
        var rows = ["\(mateName) jobs (persisted state; agent reports require evidence review):"]
        for run in visible {
            rows.append("Run \(run.id.uuidString): \(bounded(run.title, limit: 160)) — \(run.status.rawValue)")
            if !run.latestAction.isEmpty { rows.append("Latest activity: \(bounded(run.latestAction, limit: 400))") }
            switch run.status {
            case .awaitingPlanApproval:
                rows.append("Next: user must review and approve the plan. Reading status does not approve it.")
                rows.append("Plan: \(bounded(run.planText, limit: 2_000))")
            case .waitingForApproval:
                rows.append("Next: user must answer the tool approval card.")
            case .succeeded:
                rows.append("Agent final answer: \(bounded(run.finalAnswer ?? AgentFinalResult.missingMessage, limit: 6_000))")
            case .failed:
                rows.append("Failure: \(bounded(run.privateFinalResult ?? run.error, limit: 2_000))")
            case .cancelled:
                rows.append("Stopped; task completion is not established.")
            case .queued, .planning, .running:
                rows.append("Work remains in progress. No final outcome yet.")
            }
        }
        if owned.count > visible.count {
            let omittedLive = owned.filter { !$0.status.isTerminal }.count - visible.filter { !$0.status.isTerminal }.count
            rows.append("\(owned.count - visible.count) more recorded jobs omitted (\(omittedLive) still active).")
        }
        return rows.joined(separator: "\n")
    }

    private static func bounded(_ text: String, limit: Int) -> String {
        let sanitized = AgentReceiptPrivacy.privateAnswer(text)
        return sanitized.count > limit ? String(sanitized.prefix(limit)) + "… [truncated]" : sanitized
    }
}
