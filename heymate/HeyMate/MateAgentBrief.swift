//
//  MateAgentBrief.swift
//  HeyMate
//
//  The shared agent behaviour every mate inherits. A mate's soul sets how it
//  sounds; this sets what it does: do file work with its own tools, ask once
//  when a guess would waste work, and keep teaching in this chat.
//

import Foundation

enum MateAgentBrief {
    static func promptBlock(mate: Mate, runsCanOperateApps: Bool = false) -> String {
        let workspace = mate.folderPath.map { "your folder is \($0)." }
            ?? "you have your own workspace folder."
        var lines = [
            "how you work:",
            // Pi chats have write, edit and bash. Nothing parses a [WORK: ...]
            // line any more, so a reply that ends in one does no work at all.
            "- when they ask you to create or change files or run commands, do it yourself now with your write, edit and bash tools. \(workspace) each change goes through HeyMate's permission rules, so you do not ask for a path or a second approval. never write a [WORK: ...] line or promise a later run: nothing starts from it. finish with what you did and the verified absolute paths.",
            "- when the user asks to learn, understand, or do something themselves (\"teach me\", \"show me how\", \"walk me through\"), teach directly in this chat. for screen walkthroughs follow the [PLAN: ...] and [STEP:n] instructions, guide only the current step, then wait for their progress.",
            "- do the independent part first. ask once: one short set of questions, and only when a wrong guess would waste real work. never invent the user's facts or dummy data.",
            "- confirm only before you delete or archive, overwrite something they did not ask for, send email, or spend money. email is a draft until they approve the exact draft.",
            "- put deliverables in output/ and scratch in tmp/.",
            "- the final message leads with the result. after the answer you may append <SUMMARY>, <NEXT_ACTIONS>, <ARTIFACTS>, <ROUTINE>, and <COMPUTER_USE_REQUEST>. leave out a block you do not need.",
        ]
        if runsCanOperateApps {
            // Pi chats cannot start the native run that drives apps, so the
            // brief must not promise one.
            lines.append("- when the user asks you to perform an app task for them, rather than teach them, use a connected app tool or chrome when one reaches it. if none does, say plainly which app you could not reach and offer to walk them through it.")
            // Without this the brief above sent "how many emails today?" to a
            // run that drove Mail.app, when connected Gmail answers in seconds.
            lines.append("- for email, calendar, and other services listed as connected apps, use those tools directly in this chat. they answer in seconds; a run is slower and needs the user's approval.")
        }
        if mate.conductsOthers {
            lines.append("- send a specialist's execution work to them with send_to_mate. keep a requested teaching walkthrough in this chat.")
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
            : "That plan is still waiting for you. Approve it below or in Activity and I'll start, or dismiss it and ask again."
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
        let body = AgentReceiptPrivacy.safeResult(plan)
        var text = "Step 1 of 2 · plan ready. Nothing has changed yet."
        if !body.isEmpty { text += "\n\n\(body)" }
        text += "\n\nApprove the plan below or in Activity, and I'll do it."
        return text
    }

    static func finished(summary: String, changedFileCount: Int?) -> String {
        let blocks = AgentReplyBlocks.extract(from: summary)
        let summaryLead = blocks.presentedSummary
            .map { AgentReceiptPrivacy.privateAnswer($0) }
            .flatMap { AgentFinalResult.hasUsableAnswer($0) ? $0 : nil }
        let spoken = AgentReceiptPrivacy.privateAnswer(blocks.spokenText)
        let spokenLead = AgentFinalResult.hasUsableAnswer(spoken) ? spoken : nil
        let lead = summaryLead ?? spokenLead
        var text = lead.map { "Result\n\n\($0)" } ?? AgentFinalResult.missingMessage
        if lead != nil {
            let artifactCount = blocks.presentedArtifacts.count
            if artifactCount > 0 {
                text += "\n\(artifactCount) artifact\(artifactCount == 1 ? "" : "s")."
            }
        }
        if let changedFileCount, changedFileCount > 0 {
            text += "\n\(changedFileCount) file\(changedFileCount == 1 ? "" : "s") changed. You can undo this from Activity."
        }
        return text
    }

    static func failed(message: String) -> String {
        let trimmed = AgentReceiptPrivacy.privateAnswer(message)
        return "That run stopped: \(trimmed.isEmpty ? "it failed without a reason" : trimmed). Tell me to try again and I'll start a new run."
    }

    static func cancelled(summary: String) -> String {
        summary.hasPrefix("Handed off to Terminal")
            ? "This work was handed off to Terminal. HeyMate has no final result yet."
            : "This work was cancelled. It did not report a completed result."
    }
}
