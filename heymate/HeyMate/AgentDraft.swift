//
//  AgentDraft.swift
//  HeyMate
//
//  A new agent, drafted from one sentence the person writes. The model fills
//  in the parts people skip when they make an agent by hand: how it should
//  work, what it must ask before doing, and a first task worth running. The
//  person edits every field before anything is created.
//

import Foundation

nonisolated struct AgentDraft: Equatable, Sendable {
    var name: String
    /// One line: what this agent does for the person. Stored as the job.
    var role: String
    /// One or two sentences on tone. Stored as the soul.
    var personality: String
    /// Habits the agent keeps on every task. Written to AGENTS.md.
    var howItWorks: [String]
    /// Actions the agent must confirm first. Written to AGENTS.md.
    var asksFirst: [String]
    /// A concrete first request, offered in the new chat. Never sent for them.
    var firstTask: String
    /// Apps this agent would use, by the names people know (Gmail, Notion).
    var integrations: [String]

    static let empty = AgentDraft(
        name: "", role: "", personality: "", howItWorks: [], asksFirst: [], firstTask: "", integrations: []
    )
}

nonisolated enum AgentDrafter {
    static let maxHowItWorks = 5
    static let maxAsksFirst = 4
    static let maxIntegrations = 4

    static let systemPrompt = """
    You design one assistant agent for a person, from their short description. Reply with JSON only, no prose and no code fence.

    Keys:
    - "name": two words at most, a real-sounding name that hints at the work (for example "Ledger", "Inbox Ivy", "Scout"). Never "Agent", "Assistant" or "Bot".
    - "role": one line under 80 characters saying what it does for this person, starting with a verb.
    - "personality": one or two short sentences on how it talks and behaves. Specific, not generic praise.
    - "how_it_works": 3 to 5 habits it keeps on every task, each under 90 characters, written as instructions to the agent. Include where results go and how it reports back.
    - "asks_first": 1 to 3 actions it must confirm before doing, such as sending, deleting, spending or posting. Short phrases.
    - "first_task": one concrete request the person could send right now, written in their voice, under 140 characters.
    - "integrations": up to 4 apps it would use, by product name. Empty when none are needed.

    Never invent facts about the person. When the description is vague, keep the agent narrow and say what it needs from them in first_task.
    """

    static func userPrompt(description: String, connectedIntegrations: [String], existingNames: [String]) -> String {
        var lines = ["Description: \(description.trimmingCharacters(in: .whitespacesAndNewlines))"]
        if !connectedIntegrations.isEmpty {
            lines.append("Apps already connected: \(connectedIntegrations.joined(separator: ", "))")
        }
        if !existingNames.isEmpty {
            lines.append("Names already taken: \(existingNames.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    /// Reads the model's reply. Tolerates a code fence or prose around the
    /// object. Nil when there is no usable name and role.
    static func parse(_ reply: String, existingNames: [String]) -> AgentDraft? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func text(_ key: String) -> String {
            (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func list(_ key: String) -> [String] {
            (object[key] as? [Any])?.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) } ?? []
        }
        let draft = AgentDraft(
            name: text("name"),
            role: text("role"),
            personality: text("personality"),
            howItWorks: list("how_it_works"),
            asksFirst: list("asks_first"),
            firstTask: text("first_task"),
            integrations: list("integrations")
        )
        guard !draft.name.isEmpty, !draft.role.isEmpty else { return nil }
        return sanitized(draft, existingNames: existingNames)
    }

    /// Used when no model can be reached. Plain and honest rather than clever:
    /// the role is the person's own words and the habits are safe defaults.
    static func localDraft(description: String, existingNames: [String]) -> AgentDraft {
        let role = sentenceCased(description.trimmingCharacters(in: .whitespacesAndNewlines))
        return sanitized(AgentDraft(
            name: MateNameGenerator.name(for: role, existingNames: existingNames),
            role: role,
            personality: "Clear and brief. Says plainly what it did and what it could not do.",
            howItWorks: [
                "Lead with the result, then the detail.",
                "Save anything longer than a short answer as a file in output/.",
                "When something is unclear, do the part that does not depend on it, then ask once."
            ],
            asksFirst: ["Sending, posting or deleting anything"],
            firstTask: "Here's what I need first: ",
            integrations: []
        ), existingNames: existingNames)
    }

    static func sanitized(_ draft: AgentDraft, existingNames: [String]) -> AgentDraft {
        var draft = draft
        draft.name = String(draft.name.prefix(40))
        let taken = Set(existingNames.map(FileMateStore.normalized))
        if taken.contains(FileMateStore.normalized(draft.name)) {
            var suffix = 2
            while taken.contains(FileMateStore.normalized("\(draft.name) \(suffix)")) { suffix += 1 }
            draft.name = "\(draft.name) \(suffix)"
        }
        draft.role = String(draft.role.prefix(160))
        draft.personality = String(draft.personality.prefix(280))
        draft.howItWorks = cleanedList(draft.howItWorks, limit: maxHowItWorks)
        draft.asksFirst = cleanedList(draft.asksFirst, limit: maxAsksFirst)
        draft.integrations = cleanedList(draft.integrations, limit: maxIntegrations)
        draft.firstTask = String(draft.firstTask.prefix(240))
        return draft
    }

    /// The Standing preferences section of AGENTS.md for this draft.
    static func standingLines(for draft: AgentDraft) -> [String] {
        draft.howItWorks + draft.asksFirst.map { "\(askFirstPrefix)\($0)" }
    }

    static let askFirstPrefix = "Ask me before: "

    /// Splits saved standing lines back into habits and ask-first items.
    static func split(standing lines: [String]) -> (howItWorks: [String], asksFirst: [String]) {
        var habits: [String] = []
        var asks: [String] = []
        for line in lines {
            if line.hasPrefix(askFirstPrefix) {
                asks.append(String(line.dropFirst(askFirstPrefix.count)))
            } else {
                habits.append(line)
            }
        }
        return (habits, asks)
    }

    private static func cleanedList(_ items: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            let trimmed = item
                .trimmingCharacters(in: CharacterSet(charactersIn: "-•* ").union(.whitespacesAndNewlines))
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, seen.insert(key).inserted else { continue }
            result.append(String(trimmed.prefix(160)))
            if result.count == limit { break }
        }
        return result
    }

    private static func sentenceCased(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
