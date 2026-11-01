import Foundation

/// Read-only context for the conductor. Never sends a follow-up or launches work.
nonisolated enum HarnessJobStatus {
    static func report(mateName: String, mateID: UUID, runs: [AgentRun], handoffs: [HandoffRecord] = []) -> String {
        let owned = runs.filter { $0.chatOwner?.mateID == mateID }
            .sorted { $0.createdAt > $1.createdAt }
        let handed = handoffs.filter { $0.mateID == mateID }.sorted { $0.queuedAt > $1.queuedAt }
        guard !owned.isEmpty || !handed.isEmpty else {
            return "\(mateName): no recorded jobs and no handoffs since HeyMate launched. Handoffs queued before a relaunch or a Stop are not kept; send the task again if it never reported."
        }
        var rows: [String] = []
        if !handed.isEmpty { rows += handoffRows(mateName: mateName, handoffs: handed) }
        guard !owned.isEmpty else {
            rows.append("\(mateName): no agent runs recorded.")
            return rows.joined(separator: "\n")
        }
        // Prioritize live work over terminal history within the context budget.
        let visible = Array((owned.filter { !$0.status.isTerminal } + owned.filter { $0.status.isTerminal }).prefix(6))
        rows.append("\(mateName) jobs (persisted state; agent reports require evidence review):")
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

    /// Handoffs are chat turns in the specialist's chat, held in memory for this app session.
    private static func handoffRows(mateName: String, handoffs: [HandoffRecord]) -> [String] {
        let visible = Array((handoffs.filter { !$0.state.isTerminal } + handoffs.filter { $0.state.isTerminal }).prefix(6))
        var rows = ["\(mateName) handoffs (this app session only; a report is the specialist's claim, not proof of execution):"]
        for record in visible {
            rows.append("Handoff \(record.id.uuidString): \(bounded(record.instruction, limit: 160)) — \(record.state.rawValue)")
            switch record.state {
            case .queued: rows.append("Accepted, not started. It starts after the current reply finishes.")
            case .running: rows.append("Its turn is running in \(mateName)'s chat. No outcome yet.")
            case .reported: rows.append("\(mateName) replied and the report went back to the asking chat.")
            case .failed: rows.append("Did not finish.")
            case .cancelled: rows.append("Stopped before finishing; task completion is not established.")
            }
            if !record.note.isEmpty { rows.append("Note: \(bounded(record.note, limit: 400))") }
            if !record.runIDs.isEmpty {
                rows.append("Work runs requested: " + record.runIDs.map(\.uuidString).joined(separator: ", "))
            }
        }
        if handoffs.count > visible.count { rows.append("\(handoffs.count - visible.count) older handoffs omitted.") }
        return rows
    }

    private static func bounded(_ text: String, limit: Int) -> String {
        let sanitized = AgentReceiptPrivacy.privateAnswer(text)
        return sanitized.count > limit ? String(sanitized.prefix(limit)) + "… [truncated]" : sanitized
    }
}
