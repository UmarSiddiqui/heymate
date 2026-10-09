//
//  MateAgentBrief.swift
//  leanring-buddy
//
//  The shared agent behaviour every mate inherits. A mate's soul sets how it
//  sounds; this sets what it does: act instead of ask, and when the work
//  needs files or tools, start an approval-gated run instead of refusing.
//

import Foundation

enum MateAgentBrief {
    static func promptBlock(mate: Mate, runsCanOperateApps: Bool = false) -> String {
        let workspace = mate.folderPath.map { "your files live in \($0)." }
            ?? "your files live in your own workspace folder."
        var lines = [
            "how you work, as an agent and not a chatbot:",
            "- this chat window cannot read or write files, and it is not your workspace. \(workspace) you never need the user to tell you where they are.",
            "- the only way you do file work, run commands, or take several steps is an agent run. start it by ending your reply with exactly one line: [WORK: the complete task, with every detail the run needs]",
            "- a run plans first and shows the user the plan for approval before it changes anything, so you never ask for approval, a path, or confirmation yourself. do not write a plan, a list of steps, or a question in the chat. write [WORK: ...] instead.",
            "- never say you are read-only, empty, or unable to write, and never give the user drafted file contents to paste. the run does the writing.",
            "- your reply is at most two sentences: what the run will do, then the [WORK: ...] line. the result comes back to the user without them asking again.",
            "- when no file or command work is needed, answer directly and briefly. ask a question only when a wrong guess would waste real work, and ask one.",
            "- for anything current or that you are not sure of, search the web with the tools you have instead of guessing or telling the user to look it up.",
        ]
        if runsCanOperateApps {
            // Without this the chat model only sees its own tools and answers
            // "no app control is available here" instead of starting the run
            // that has it.
            lines.append("- a run can also operate other mac apps in the background: open an app, click, type, use menus, without taking the user's cursor. when the user asks you to do something in an app that none of your connected apps can reach, start a [WORK: ...] run for it. never say app control is unavailable.")
            // Without this the brief above sent "how many emails today?" to a
            // run that drove Mail.app, when connected Gmail answers in seconds.
            lines.append("- for email, calendar, and other services listed as connected apps, use those tools directly in this chat. they answer in seconds; a run is slower and needs the user's approval.")
        }
        if mate.conductsOthers {
            lines.append("- for a specialist's job, hand it over with [ASK: ...] instead of [WORK: ...].")
        }
        return lines.joined(separator: "\n")
    }
}

/// Keeps a mate from stacking runs. A follow-up like "well?" while a plan
/// waits for approval used to start a second, duplicate run.
enum MateWorkGate {
    /// The run this mate is already waiting on the user for, if any.
    static func runAwaitingUser(
        ownedBy mateID: UUID,
        owners: [UUID: UUID],
        runs: [AgentRun]
    ) -> AgentRun? {
        runs.first { run in
            owners[run.id] == mateID && (run.status == .awaitingPlanApproval || run.status == .planning)
        }
    }

    static func reminder(for run: AgentRun) -> String {
        run.status == .planning
            ? "I'm still writing the plan for that. You'll see it here in a moment, and nothing changes until you approve it."
            : "That plan is still waiting for you. Approve it below or in Jobs and I'll start, or dismiss it and ask again."
    }
}

enum MateWorkParser {
    struct Result: Equatable {
        var spokenText: String
        var tasks: [String]
    }

    /// Pulls `[WORK: task]` out of a reply. The spoken text loses the markup
    /// so it is never read aloud.
    static func extract(from text: String) -> Result {
        guard let expression = try? NSRegularExpression(
            pattern: #"\[WORK:\s*([^\]]+?)\s*\]"#,
            options: []
        ) else {
            return Result(spokenText: text, tasks: [])
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: range)
        guard !matches.isEmpty else { return Result(spokenText: text, tasks: []) }

        let tasks: [String] = matches.compactMap { match in
            guard let taskRange = Range(match.range(at: 1), in: text) else { return nil }
            let task = String(text[taskRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            return task.isEmpty ? nil : task
        }
        let spoken = expression.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(
            spokenText: spoken.isEmpty && !tasks.isEmpty ? "On it. I'll plan it and show you before I change anything." : spoken,
            tasks: tasks
        )
    }
}

/// What a mate says in its own chat as an agent run moves along, so the run
/// reads as steps the mate took rather than a card the user has to go find.
enum MateRunReport {
    static func planReady(plan: String) -> String {
        let body = plan.count > 700 ? String(plan.prefix(699)) + "…" : plan
        var text = "Step 1 of 2 · plan ready. Nothing has changed yet."
        if !body.isEmpty { text += "\n\n\(body)" }
        text += "\n\nApprove the plan below or in Jobs, and I'll do it."
        return text
    }

    static func finished(summary: String, changedFileCount: Int?) -> String {
        var text = "Step 2 of 2 · done."
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { text += " \(trimmed)" }
        if let changedFileCount, changedFileCount > 0 {
            text += "\n\(changedFileCount) file\(changedFileCount == 1 ? "" : "s") changed. You can undo this from Jobs."
        }
        text += "\n\nWant me to keep doing this on a schedule? Say \"every morning, …\" and I'll set it up."
        return text
    }

    static func failed(message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return "That run stopped: \(trimmed.isEmpty ? "it failed without a reason" : trimmed). Tell me to try again and I'll start a new run."
    }
}
