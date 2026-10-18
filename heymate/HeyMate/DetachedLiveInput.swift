import Foundation

/// Public, provider-independent metadata. Turn handles are random capabilities,
/// never Codex thread/turn IDs. Text remains only in private app/command storage.
nonisolated struct DetachedLiveInputReceipt: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case sending, accepted, rejected, unavailable, unknown }
    let messageID: UUID
    let turnToken: UUID
    var status: Status
}

nonisolated struct AgentLiveInputDelivery: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case sending, accepted, queued, failed, unknown }
    let id: UUID
    let attemptID: UUID
    let turnToken: UUID
    let text: String
    var status: Status

    var summary: String {
        switch status {
        case .sending: return "Sending update to live execution turn…"
        case .accepted: return "Codex acknowledged update in the live execution turn."
        case .queued: return "Live turn unavailable; update queued for a new plan to approve."
        case .failed: return "Live update was not accepted. Not retried; your input remains in task activity."
        case .unknown: return "Live update delivery unknown. Not retried; Codex may have received it."
        }
    }
}

/// Bootstrap-only data, inherited through the existing private runner pipe.
nonisolated struct CodexExecutionLaunch: Codable, Equatable, Sendable {
    let threadID: String
    let model: String?
    let effort: String?
    let mcpArguments: [String]
    let approvalPolicy: String
}

nonisolated enum AgentPrivateApprovalStore {
    static func url(root: URL, runID: UUID, attemptID: UUID, token: UUID) -> URL {
        DetachedAgentRuntimePaths.attemptDirectoryURL(rootDirectoryURL: root, runID: runID, attemptID: attemptID)
            .appendingPathComponent("approval-\(token.uuidString.lowercased()).txt")
    }
    static func save(_ text: String, root: URL, runID: UUID, attemptID: UUID, token: UUID) throws {
        let safe = AgentReceiptPrivacy.privateToolDetails(text)
        try DetachedAgentSecureFiles.atomicDurableWrite(Data(safe.utf8), to: url(root: root, runID: runID, attemptID: attemptID, token: token))
    }
    static func load(root: URL, runID: UUID, attemptID: UUID, token: UUID) -> String? {
        let path = url(root: root, runID: runID, attemptID: attemptID, token: token)
        guard (try? DetachedAgentSecureFiles.validateDirectory(root)) != nil,
              (try? DetachedAgentSecureFiles.validateDirectory(DetachedAgentRuntimePaths.runDirectoryURL(rootDirectoryURL: root, runID: runID))) != nil,
              (try? DetachedAgentSecureFiles.validateDirectory(path.deletingLastPathComponent())) != nil,
              let data = try? DetachedAgentSecureFiles.readRegularFile(path, maximumByteCount: 32 * 1024) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
