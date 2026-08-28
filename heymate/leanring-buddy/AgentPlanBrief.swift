//
//  AgentPlanBrief.swift
//  leanring-buddy
//
//  What leg one is told about the deal it is in.
//
//  Without this, a CLI in plan mode does not know why its write tools keep
//  refusing. Observed behaviour on a task the model judged trivial: it tried
//  to write the file, was blocked, reached for `ExitPlanMode`, found it
//  disabled under `-p`, and then spent the rest of the turn narrating that
//  confusion — leaving a "plan" that was mostly an apology about tooling.
//
//  The brief is deliberately about the *contract*, not about how to plan.
//  Telling a coding model how to think produces worse plans; telling it what
//  will happen to its output produces better ones.
//

import Foundation

nonisolated enum AgentPlanBrief {

    /// Appended to the system prompt of a read-only leg.
    static let planningContract = """
    You are in the planning half of a two-step flow inside HeyMate.

    Right now you cannot write files, run commands that change anything, or \
    finish the task. That is deliberate and is not a malfunction — read, \
    inspect, and think, then answer with the plan itself.

    A human is about to read your plan and either approve it, send it back \
    with changes, or throw it away. If they approve, this same session resumes \
    with write access and you carry the plan out then.

    So: do not attempt the work, do not try to leave plan mode, and do not \
    comment on your own tooling. End your turn with the plan, written for the \
    person deciding — what you will change, which files, and anything you had \
    to assume. Short is fine. If the task is trivial, say so in one line and \
    give the one-line plan.
    """

    /// Appended when the user sent a plan back with an objection.
    static let replanContract = """
    \(planningContract)

    The person read your previous plan and asked for changes. Their note \
    follows. Revise the plan to match it — do not defend the old one.
    """

    /// Appended when the user asks for more work on a job that already
    /// finished.
    static let followUpContract = """
    \(planningContract)

    This session already completed a piece of work. The person is now asking \
    for something further. Build on what is already there — check the current \
    state before assuming your earlier plan still describes it — and plan only \
    the new work.
    """

    static func contract(for leg: AgentRunLeg) -> String? {
        switch leg {
        case .plan:
            return planningContract
        case .replan:
            return replanContract
        case .followUp:
            return followUpContract
        case .execute:
            // Leg two needs no framing: the approved plan is already the most
            // recent thing in its own context.
            return nil
        }
    }
}
