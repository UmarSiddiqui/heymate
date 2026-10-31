import Foundation

/// Presentation-only state. Runtime adapters supply snapshots; the notch never
/// starts work or changes an approval through this model.
nonisolated struct NotchCompactStatus {
    enum Phase: Equatable {
        case queued, planning, working, needsUser, succeeded, failed, cancelled

        var isTerminal: Bool {
            switch self {
            case .succeeded, .failed, .cancelled: return true
            default: return false
            }
        }

        var label: String {
            switch self {
            case .queued: return "Queued"
            case .planning: return "Planning"
            case .working: return "Working"
            case .needsUser: return "Approval needed"
            case .succeeded: return "Done"
            case .failed: return "Task failed"
            case .cancelled: return "Stopped"
            }
        }
    }

    struct Snapshot: Equatable, Identifiable {
        let id: UUID
        let title: String
        let action: String
        let phase: Phase
        let hue: Double
        let createdAt: Date

        var displayText: String {
            // Terminal and approval states must never show the previous tool
            // action as if it were still running.
            guard phase == .working || phase == .planning else { return phase.label }
            let line = action.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return line.isEmpty ? phase.label : String(line.prefix(80))
        }
    }

    private var previousPhases: [UUID: Phase] = [:]
    private var completion: Snapshot?
    private(set) var expiresAt: Date?
    private(set) var selected: Snapshot?
    private(set) var activeCount = 0

    mutating func update(_ snapshots: [Snapshot], now: Date = Date()) {
        if let expiresAt, expiresAt <= now {
            completion = nil
            self.expiresAt = nil
        }
        // Do not replay saved completions at launch. Only a run observed alive
        // in this process can produce a transient completion.
        let finished = snapshots.filter {
            $0.phase.isTerminal && previousPhases[$0.id].map { !$0.isTerminal } == true
        }.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        if let newest = finished.last {
            completion = newest
            expiresAt = now.addingTimeInterval(6)
        }
        previousPhases = Dictionary(snapshots.map { ($0.id, $0.phase) }, uniquingKeysWith: { _, new in new })
        let live = snapshots.filter { !$0.phase.isTerminal }.sorted {
            let left = $0.phase == .needsUser ? 0 : ($0.phase == .queued ? 2 : 1)
            let right = $1.phase == .needsUser ? 0 : ($1.phase == .queued ? 2 : 1)
            if left != right { return left < right }
            return ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }
        activeCount = live.count
        selected = live.first ?? completion
    }
}
