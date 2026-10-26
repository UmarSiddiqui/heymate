// From vinzdg/codenotch, MIT, revision 6522e9f.
import SwiftUI

/// What the activity cell shows: the state of every live session, reduced to
/// the one thing worth knowing at a glance.
nonisolated struct CNActivitySummary: Equatable {
    enum State: Equatable {
        case working
        case waiting
        case success
        case idle
    }

    let state: State
    let sessions: [CNAgentSession]
    /// Requests lined up behind the one running — a local runtime's queue.
    /// Zero for every cloud agent, which has no such line to report.
    let queued: Int
    /// What the tooltip's header says while this is going on, where a local
    /// runtime names the phase. Nil leaves the header to the session's name.
    let note: String?

    /// Nil when nothing is running — the cell disappears rather than sitting
    /// there saying nothing.
    init?(sessions: [CNAgentSession], queued: Int = 0, note: String? = nil) {
        guard !sessions.isEmpty else { return nil }
        self.sessions = sessions
        self.queued = max(0, queued)
        self.note = note
        // Anything blocked on you outranks anything merely busy: it is the only
        // state where the notch is asking for something.
        if sessions.contains(where: { $0.state == .waiting }) {
            state = .waiting
        } else if sessions.contains(where: { $0.state == .busy }) {
            state = .working
        } else if sessions.contains(where: { $0.state == .success }) {
            state = .success
        } else {
            state = .idle
        }
    }

    /// One short word, for the tooltip.
    var label: String {
        switch state {
        case .working: return CNL10n.t("working")
        case .waiting: return CNL10n.t("waiting")
        case .success: return CNL10n.t("complete")
        case .idle:    return CNL10n.t("idle")
        }
    }

    /// The ring draws working either as the neutral arc, which uses this colour
    /// (the default), or as the brand-coloured `BusyWave` when the user chose
    /// the breathing disc in Settings. The neutral value stays off the green /
    /// amber / red that already means "how much of your limit is gone".
    /// Waiting keeps amber in both because it is the one state that wants
    /// something from you.
    var color: Color {
        switch state {
        case .working: return Color.white
        case .waiting: return Color.orange
        case .success: return Color.green
        case .idle:    return Color.gray
        }
    }

    var waitingSessions: [CNAgentSession] { sessions.filter { $0.state == .waiting } }
}
