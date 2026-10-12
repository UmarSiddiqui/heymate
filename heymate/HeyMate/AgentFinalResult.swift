import Foundation

/// Selects the final assistant answer, never a tool's raw output. Callers only
/// deliver this after a successful process exit. Older agents need not emit
/// the preferred marker: Claude's result or the last post-tool answer works.
nonisolated struct AgentFinalResult {
    static let marker = "HEYMATE_RESULT:"
    static let missingMessage = "The agent ended without a final result. Its outcome could not be verified."
    static let availableSummary = "Final answer available in this agent's activity and its chat."
    static let blockedSummary = "The agent reported that it could not finish the task."
    static let maximumAnswerBytes = 32 * 1_024

    enum Outcome: Equatable {
        case reported(String)
        case blocked(String)
        case missing
        case failed
    }

    private var candidate: Outcome?
    private var reportedFailure = false

    mutating func consume(_ event: AgentEvent) {
        switch event {
        case .text(let text), .finished(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix(Self.marker) {
                let answer = AgentReceiptPrivacy.privateAnswer(String(trimmed.dropFirst(Self.marker.count)))
                candidate = Self.hasUsableAnswer(answer) ? .reported(answer) : nil
            } else if trimmed.hasPrefix(headlessAgentBlockedMarker) {
                let reason = AgentReceiptPrivacy.privateAnswer(String(trimmed.dropFirst(headlessAgentBlockedMarker.count)))
                candidate = .blocked(reason.isEmpty ? "The agent could not finish the task." : reason)
            } else {
                let answer = AgentReceiptPrivacy.privateAnswer(trimmed)
                if case .finished = event, !Self.hasUsableAnswer(answer) { return }
                candidate = Self.hasUsableAnswer(answer) ? .reported(answer) : nil
            }
        case .tool:
            // A marked message before a later action was not the final answer.
            candidate = nil
        case .failed:
            reportedFailure = true
        default:
            break
        }
    }

    var outcome: Outcome {
        reportedFailure ? .failed : candidate ?? .missing
    }

    /// Text selected as the answer, including any trailing blocks. Empty when
    /// the job failed or no answer was selected. `AgentReplyBlocks` reads this
    /// from the app target; this file stays free of that type because the
    /// agent runner compiles it on its own.
    var answerText: String {
        switch outcome {
        case .reported(let text):
            return text
        case .blocked(let text):
            return text
        case .missing, .failed:
            return ""
        }
    }

    static func hasUsableAnswer(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
            .lowercased()
        return !normalized.isEmpty && !["done", "work completed", "completed", "success", "task completed"].contains(normalized)
            && text != missingMessage && text != availableSummary
    }
}

/// The journal carries metadata only. This private, attempt-scoped artifact
/// is durably written before its terminal event, so journal-before-state
/// recovery can still retrieve the answer without persisting prose in logs.
nonisolated enum AgentPrivateResultStore {
    static func fileURL(root: URL, runID: UUID, attemptID: UUID) -> URL {
        DetachedAgentRuntimePaths.attemptDirectoryURL(rootDirectoryURL: root, runID: runID, attemptID: attemptID)
            .appendingPathComponent("final-answer.txt", isDirectory: false)
    }

    static func save(_ answer: String, root: URL, runID: UUID, attemptID: UUID) throws {
        let bounded = AgentReceiptPrivacy.privateAnswer(answer)
        try DetachedAgentSecureFiles.atomicDurableWrite(Data(bounded.utf8), to: fileURL(root: root, runID: runID, attemptID: attemptID))
    }

    static func load(root: URL, runID: UUID, attemptID: UUID) throws -> String? {
        let url = fileURL(root: root, runID: runID, attemptID: attemptID)
        guard DetachedAgentSecureFiles.pathExistsWithoutFollowingLinks(url) else { return nil }
        try DetachedAgentSecureFiles.validateDirectory(root)
        try DetachedAgentSecureFiles.validateDirectory(DetachedAgentRuntimePaths.runDirectoryURL(rootDirectoryURL: root, runID: runID))
        try DetachedAgentSecureFiles.validateDirectory(url.deletingLastPathComponent())
        let data = try DetachedAgentSecureFiles.readRegularFile(url, maximumByteCount: UInt64(AgentFinalResult.maximumAnswerBytes))
        guard let answer = String(data: data, encoding: .utf8) else { return nil }
        let sanitized = AgentReceiptPrivacy.privateAnswer(answer)
        return AgentFinalResult.hasUsableAnswer(sanitized) ? sanitized : nil
    }
}
