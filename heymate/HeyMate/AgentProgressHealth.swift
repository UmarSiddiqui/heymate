import Foundation

/// Provider tool progress, never runner heartbeats or local status messages.
/// Silence is an observation, not evidence of failure or permission to kill.
nonisolated enum AgentProgressHealth {
    static func summary(for run: AgentRun, now: Date = Date()) -> String {
        guard run.status == .running || run.status == .planning,
              let anchor = run.lastToolProgressAt ?? run.progressObservationStartedAt ?? run.startedAt,
              now.timeIntervalSince(anchor) >= 120 else { return "" }
        let minutes = max(2, Int(now.timeIntervalSince(anchor) / 60))
        return " No new tool progress reported for \(minutes) minutes. A live runner does not confirm progress; the task may still be waiting. You can keep waiting or cancel."
    }
}
