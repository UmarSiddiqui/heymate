import Foundation

/// Pending update metadata only. Answer prose stays in the existing private run
/// store; opening/dismissing an update never changes the job or its chat receipt.
nonisolated struct FloatingAgentNotice: Codable, Equatable, Identifiable {
    let id: UUID
    let runID: UUID
    let resultKey: String
    let mateID: UUID
    let chatID: UUID
    let createdAt: Date

    func matches(_ run: AgentRun) -> Bool {
        run.id == runID && run.resultDeliveryKey == resultKey
            && run.chatOwner?.mateID == mateID && run.chatOwner?.chatID == chatID
            && run.status.isTerminal
    }
}

@MainActor
final class FloatingAgentNoticeStore {
    private struct Observed: Codable, Equatable {
        let resultKey: String
        let owner: AgentChatOwner?
    }
    private let fileURL: URL?
    private var observedResults: [UUID: Observed]?
    private var persistedResults: [UUID: Observed]?
    private(set) var notices: [FloatingAgentNotice]

    init(fileURL: URL? = HeyMateDataDirectory.url.appendingPathComponent("floating-task-updates.json")) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([FloatingAgentNotice].self, from: data) {
            var seen = Set<UUID>()
            notices = saved.filter { seen.insert($0.id).inserted }
        } else { notices = [] }
        if let fileURL {
            let observationsURL = fileURL.deletingPathExtension().appendingPathExtension("observations.json")
            if let data = try? Data(contentsOf: observationsURL) {
                persistedResults = try? JSONDecoder().decode([UUID: Observed].self, from: data)
            }
        }
    }

    /// Baseline existing jobs before subscribing: historical completions do not
    /// replay on launch, while already-pending saved updates remain available.
    func start(runs: [AgentRun]) {
        if let persistedResults {
            observedResults = persistedResults
            observe(runs: runs)
        } else {
            observedResults = snapshot(runs)
            _ = prune(runs: runs)
            persist()
        }
    }

    func stop() { observedResults = nil }

    func observe(runs: [AgentRun]) {
        guard let previous = observedResults else { start(runs: runs); return }
        let oldNotices = notices
        _ = prune(runs: runs)
        let existing = Set(notices.map { "\($0.runID):\($0.resultKey)" })
        for run in runs where run.status.isTerminal {
            guard let oldResult = previous[run.id], oldResult.resultKey != run.resultDeliveryKey,
                  let owner = run.chatOwner,
                  oldResult.owner == owner,
                  !existing.contains("\(run.id):\(run.resultDeliveryKey)") else { continue }
            notices.append(FloatingAgentNotice(id: UUID(), runID: run.id, resultKey: run.resultDeliveryKey,
                                               mateID: owner.mateID, chatID: owner.chatID,
                                               createdAt: run.finishedAt ?? Date()))
        }
        observedResults = snapshot(runs)
        notices.sort {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
        }
        if oldNotices != notices || previous != observedResults { persist() }
    }

    func dismiss(id: UUID) {
        guard notices.contains(where: { $0.id == id }) else { return }
        notices.removeAll { $0.id == id }
        persist()
    }

    private func snapshot(_ runs: [AgentRun]) -> [UUID: Observed] {
        Dictionary(runs.map { ($0.id, Observed(resultKey: $0.resultDeliveryKey, owner: $0.chatOwner)) },
                   uniquingKeysWith: { _, last in last })
    }

    private func prune(runs: [AgentRun]) -> Bool {
        let current = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let old = notices
        notices.removeAll { notice in current[notice.runID].map(notice.matches) != true }
        return old != notices
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            let parent = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(notices).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            if let observedResults {
                let observationsURL = fileURL.deletingPathExtension().appendingPathExtension("observations.json")
                try JSONEncoder().encode(observedResults).write(to: observationsURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: observationsURL.path)
                persistedResults = observedResults
            }
        } catch {
            HeyMateLog.log("HeyMate: Could not save floating task update metadata.")
        }
    }
}
