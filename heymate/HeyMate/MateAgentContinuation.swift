import Foundation

/// Long runs: a task that outlasts one turn. The runtime caps a turn at its
/// step and time budget (the native client waits 300 s per turn). When a turn
/// runs out of budget with work still in progress, the runtime ends it at a
/// checkpoint instead of a wrapped-up partial answer, and this loop starts a
/// continuation turn on the same session without the user typing, up to a
/// bounded number of times. The chat shows one "still working" state across
/// the chain. Stop cancels the whole chain (task cancellation); a pending
/// approval or question pauses a turn's clock as before; the stall watchdog is
/// untouched, and a stalled, failed or cancelled turn is never continued.
enum MateAgentContinuation {
    /// Continuation turns after the first, so one task runs at most 13 turns.
    nonisolated static let maxContinuations = 12

    /// Sent as the user message of each continuation turn. Pi keeps the
    /// session's history, so the model sees what it already did.
    static let prompt = """
    HeyMate: the previous turn reached its time or step limit while this task was still in progress. \
    Continue the same task from where it stopped. Do not redo finished steps: check earlier tool results first. \
    If an action reports that it may already have run, check its outcome instead of repeating it. \
    When the whole task is done, give the final answer.
    """

    struct Step: Equatable {
        /// 0 for the turn the user started, then 1, 2, ...
        let index: Int
        /// The runtime treats this turn as resuming earlier work (side-effect fingerprints apply).
        let isContinuation: Bool
        /// The runtime may end this turn at a checkpoint rather than salvage an answer.
        let allowsContinuation: Bool
    }

    static func allowsAnother(used: Int, max: Int = maxContinuations) -> Bool { used < max }

    /// Whether a finished turn should be followed by a continuation turn.
    static func shouldContinue(status: String, continues: Bool, used: Int, isCancelled: Bool,
                               max: Int = maxContinuations) -> Bool {
        !isCancelled && status == "complete" && continues && allowsAnother(used: used, max: max)
    }

    /// Runs the first turn and any continuation turns. `submit` runs one turn;
    /// `paused` runs between turns (close the checkpoint turn, show progress)
    /// and may throw to end the chain. Errors and cancellation end it at once.
    static func run<R>(
        startsAsContinuation: Bool = false,
        max: Int = maxContinuations,
        submit: (Step) async throws -> R,
        status: (R) -> String,
        continues: (R) -> Bool,
        paused: (R, Int) async throws -> Void
    ) async throws -> R {
        var used = 0
        while true {
            try Task.checkCancellation()
            let step = Step(index: used, isContinuation: startsAsContinuation || used > 0,
                            allowsContinuation: allowsAnother(used: used, max: max))
            let result = try await submit(step)
            guard shouldContinue(status: status(result), continues: continues(result), used: used,
                                 isCancelled: Task.isCancelled, max: max) else { return result }
            used += 1
            try await paused(result, used)
        }
    }
}
