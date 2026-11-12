//
//  MateMarkdown.swift
//  HeyMate
//
//  One agent as a Markdown file someone can read, edit, and share: who it
//  is, how it works, what it remembers, what it does on a schedule, and
//  when it offers to help. Chats, folders, keys, and integration sign-ins
//  never go in the file. Reading and writing never call a model.
//

import Foundation

nonisolated struct MateMarkdownRoutine: Equatable {
    var when: String
    var task: String
    var maxRunMinutes: Int?
}

nonisolated struct MateMarkdownDocument: Equatable {
    var name: String
    var job: String
    var soul: String = ""
    var brainRawValue: String?
    var backupBrainRawValue: String?
    var howItWorks: [String] = []
    var asksFirst: [String] = []
    var memory: String = ""
    var routines: [MateMarkdownRoutine] = []
    var wakeKind: MateWakeKind?
    var wakeMatch: String = ""
}

nonisolated enum MateMarkdown {
    static let formatMarker = "heymate-agent: 1"
    static let fileExtension = "md"
    static let maximumBytes = 64 * 1024

    private enum Heading: String, CaseIterable {
        case personality = "Personality"
        case howItWorks = "How it works"
        case asksFirst = "Asks you before"
        case memory = "Memory"
        case routines = "Routines"
        case offers = "Offers to help when"
    }

    static func suggestedFileName(for name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Agent" : cleaned) + ".\(fileExtension)"
    }

    // MARK: Writing

    static func render(_ document: MateMarkdownDocument) -> String {
        var lines = ["---", formatMarker, "name: \(oneLine(document.name))", "job: \(oneLine(document.job))"]
        if let brain = document.brainRawValue { lines.append("brain: \(brain)") }
        if let backup = document.backupBrainRawValue { lines.append("backup-brain: \(backup)") }
        lines += ["---", "", "# \(oneLine(document.name))", "", oneLine(document.job)]

        func section(_ heading: Heading, _ body: [String]) {
            guard !body.isEmpty else { return }
            lines += ["", "## \(heading.rawValue)", ""] + body
        }
        section(.personality, paragraph(document.soul))
        section(.howItWorks, document.howItWorks.map { "- \(oneLine($0))" })
        section(.asksFirst, document.asksFirst.map { "- \(oneLine($0))" })
        section(.memory, paragraph(document.memory))
        section(.routines, document.routines.map { routine in
            let limit = routine.maxRunMinutes.map { " (limit \($0) min)" } ?? ""
            return "- \(oneLine(routine.when))\(limit): \(oneLine(routine.task))"
        })
        if let kind = document.wakeKind {
            let match = document.wakeMatch.isEmpty ? "" : ": \(oneLine(document.wakeMatch))"
            section(.offers, ["- \(kind.rawValue)\(match)"])
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func paragraph(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // A line that looks like a heading would end the section on import.
        return trimmed.components(separatedBy: .newlines).map { line in
            line.hasPrefix("#") ? "\\" + line : line
        }
    }

    // MARK: Reading

    enum ReadError: Error, Equatable {
        case notAnAgentFile
        case missingName
        case missingJob
        case tooLarge

        var message: String {
            switch self {
            case .notAnAgentFile: return "That file isn't a HeyMate agent. It needs the \"\(MateMarkdown.formatMarker)\" line at the top."
            case .missingName: return "The file has no name for the agent."
            case .missingJob: return "The file doesn't say what the agent does (job)."
            case .tooLarge: return "That file is too large to be an agent."
            }
        }
    }

    static func parse(_ text: String) -> Result<MateMarkdownDocument, ReadError> {
        guard text.utf8.count <= maximumBytes else { return .failure(.tooLarge) }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return .failure(.notAnAgentFile)
        }
        var front: [String: String] = [:]
        var sawMarker = false
        for line in lines[1..<close] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == formatMarker { sawMarker = true; continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            front[key] = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard sawMarker else { return .failure(.notAnAgentFile) }
        guard let name = front["name"], !name.isEmpty else { return .failure(.missingName) }
        guard let job = front["job"], !job.isEmpty else { return .failure(.missingJob) }

        var document = MateMarkdownDocument(name: String(name.prefix(60)), job: String(job.prefix(240)))
        document.brainRawValue = front["brain"].flatMap { AgentBrain(rawValue: $0)?.rawValue }
        document.backupBrainRawValue = front["backup-brain"].flatMap { AgentBrain(rawValue: $0)?.rawValue }

        var sections: [Heading: [String]] = [:]
        var current: Heading?
        for line in lines[(close + 1)...] {
            if line.hasPrefix("## ") {
                let title = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                current = Heading.allCases.first { $0.rawValue.caseInsensitiveCompare(title) == .orderedSame }
                continue
            }
            if line.hasPrefix("# ") { current = nil; continue }
            guard let current else { continue }
            sections[current, default: []].append(line.hasPrefix("\\#") ? String(line.dropFirst()) : line)
        }
        func sectionText(_ heading: Heading) -> String {
            (sections[heading] ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func bullets(_ heading: Heading) -> [String] {
            (sections[heading] ?? []).compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return nil }
                let item = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return item.isEmpty ? nil : String(item.prefix(240))
            }
        }
        document.soul = String(sectionText(.personality).prefix(2_000))
        document.memory = String(sectionText(.memory).prefix(4_000))
        document.howItWorks = Array(bullets(.howItWorks).prefix(AgentDrafter.maxHowItWorks))
        document.asksFirst = Array(bullets(.asksFirst).prefix(AgentDrafter.maxAsksFirst))
        document.routines = bullets(.routines).prefix(CompanionManager.routineLimitPerMate).compactMap(routine(from:))
        if let offer = bullets(.offers).first {
            let parts = offer.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if let kind = MateWakeKind(rawValue: parts[0]) {
                document.wakeKind = kind
                document.wakeMatch = parts.count > 1 ? parts[1] : ""
            }
        }
        return .success(document)
    }

    /// "every weekday at 9am (limit 30 min): check the inbox"
    private static func routine(from item: String) -> MateMarkdownRoutine? {
        guard let colon = item.range(of: ": ") else { return nil }
        var when = item[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
        let task = item[colon.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !when.isEmpty, !task.isEmpty else { return nil }
        var limit: Int?
        if let range = when.range(of: #"\(limit (\d+) min\)"#, options: .regularExpression) {
            limit = Int(when[range].filter(\.isNumber))
            when = when.replacingCharacters(in: range, with: "").trimmingCharacters(in: .whitespaces)
        }
        return MateMarkdownRoutine(when: when, task: task, maxRunMinutes: limit)
    }
}
