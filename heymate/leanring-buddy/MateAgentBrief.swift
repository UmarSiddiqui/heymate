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
    static func promptBlock(mate: Mate) -> String {
        var lines = [
            "how you work, as an agent and not a chatbot:",
            "- when the user asks for work, do it. do not ask permission to start, do not describe what you would do, and do not end with a menu of options.",
            "- answer what you can from what you already know or can see. ask a question only when a wrong guess would waste real work, and ask one.",
            "- work that reads or writes files, runs commands, or takes several steps runs as an agent run, not in this chat. start it by writing one line: [WORK: the complete task, with every detail the run needs]",
            "- an agent run plans first and shows the plan for approval before it changes anything, so starting one is always safe. never say you are read-only, empty, or unable to write. write [WORK: ...] instead.",
            "- after [WORK: ...], say in one sentence what the run will do. the result comes back to the user without them asking again.",
            "- for anything current or that you are not sure of, search the web with the tools you have instead of guessing or telling the user to look it up.",
            "- report results, not intentions: what you did, what changed, and the one next step.",
        ]
        if mate.conductsOthers {
            lines.append("- for a specialist's job, hand it over with [ASK: ...] instead of [WORK: ...].")
        }
        return lines.joined(separator: "\n")
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
        text += "\n\nApprove it in the Agents tab and I'll do it."
        return text
    }

    static func finished(summary: String, changedFileCount: Int?) -> String {
        var text = "Step 2 of 2 · done."
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { text += " \(trimmed)" }
        if let changedFileCount, changedFileCount > 0 {
            text += "\n\(changedFileCount) file\(changedFileCount == 1 ? "" : "s") changed. You can undo this from the Agents tab."
        }
        text += "\n\nWant me to keep doing this on a schedule? Say \"every morning, …\" and I'll set it up."
        return text
    }

    static func failed(message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return "That run stopped: \(trimmed.isEmpty ? "it failed without a reason" : trimmed). Tell me to try again and I'll start a new run."
    }
}
