import Foundation

/// What happened to each send_to_mate handoff this app session. A handoff is a
/// chat turn in the specialist's chat, not an agent run, so the run store never
/// sees it; without this, get_mate_status reported "no recorded jobs" for work
/// it had just accepted. Kept in memory only: the queue itself is in memory, so
/// a relaunch loses both, and status says so.
nonisolated struct HandoffRecord: Equatable, Identifiable {
    enum State: String, Equatable {
        /// Accepted and waiting for the current reply to finish.
        case queued
        /// Its turn is running in the specialist's chat.
        case running
        /// The specialist's reply returned to the asking chat. Not proof of execution.
        case reported
        /// The turn failed, or the reply asked for work nothing started.
        case failed
        /// Stopped, or dropped before it ran.
        case cancelled

        var isTerminal: Bool { self == .reported || self == .failed || self == .cancelled }
    }

    let id: UUID
    let mateID: UUID
    let instruction: String
    var state: State
    var queuedAt: Date
    var updatedAt: Date
    var note = ""
    var runIDs: [UUID] = []
}

nonisolated struct HandoffLedger: Equatable {
    static let limit = 50
    private(set) var records: [HandoffRecord] = []

    mutating func queued(_ handoff: MateHandoff, note: String = "", at date: Date = Date()) {
        records.removeAll { $0.id == handoff.id }
        records.append(HandoffRecord(id: handoff.id, mateID: handoff.mateID, instruction: handoff.instruction,
                                     state: .queued, queuedAt: date, updatedAt: date, note: note))
        if records.count > Self.limit {
            // Drop finished history first so live handoffs stay visible.
            if let index = records.firstIndex(where: { $0.state.isTerminal }) { records.remove(at: index) }
            else { records.removeFirst() }
        }
    }

    mutating func mark(_ id: UUID, _ state: HandoffRecord.State, note: String? = nil, runIDs: [UUID]? = nil,
                       at date: Date = Date()) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].state = state
        records[index].updatedAt = date
        if let note { records[index].note = note }
        if let runIDs { records[index].runIDs = runIDs }
    }

    func records(for mateID: UUID) -> [HandoffRecord] {
        records.filter { $0.mateID == mateID }.sorted { $0.queuedAt > $1.queuedAt }
    }
}
