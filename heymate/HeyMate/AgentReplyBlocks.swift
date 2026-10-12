//
//  AgentReplyBlocks.swift
//  HeyMate
//
//  Optional blocks an agent may append after its answer. Spoken text is what
//  remains once those blocks are removed. Nothing here schedules a routine
//  or opens a file; it only reads the message.
//

import Foundation

/// Parsed tail of an agent final message.
nonisolated struct AgentReplyBlocks: Equatable {
    /// Answer prose with the blocks removed.
    var spokenText: String
    /// `<SUMMARY>` body, uncut.
    var summary: String?
    /// Summary capped for chat and speech.
    var presentedSummary: String?
    /// Every `<NEXT_ACTIONS>` line, uncut.
    var nextActions: [String]
    /// At most four lines, each capped, for a later chip row.
    var presentedNextActions: [String]
    /// Every `<ARTIFACTS>` line, including scratch paths.
    var artifacts: [String]
    /// Artifact lines worth showing. Scratch under `tmp/` is left out.
    var presentedArtifacts: [String]
    var doneTitle: String?
    var routine: AgentRoutineRequest?
    var computerUseRequest: String?

    static let presentedSummaryLimit = 200
    static let presentedNextActionLimit = 4
    static let presentedNextActionCharacterLimit = 40

    static func extract(from text: String) -> AgentReplyBlocks {
        guard let expression = tagExpression else {
            return bare(text)
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = expression.matches(in: text, range: range)
        guard !matches.isEmpty else { return bare(text) }

        var bodies: [String: String] = [:]
        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text) else { continue }
            bodies[String(text[nameRange])] = String(text[bodyRange])
        }

        var spoken = text
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: spoken) else { continue }
            spoken.removeSubrange(whole)
        }

        let summary = nonempty(bodies["SUMMARY"])
        let actions = list(bodies["NEXT_ACTIONS"])
        let artifacts = list(bodies["ARTIFACTS"])
        return AgentReplyBlocks(
            spokenText: tidy(spoken),
            summary: summary,
            presentedSummary: presentSummary(summary),
            nextActions: actions,
            presentedNextActions: presentActions(actions),
            artifacts: artifacts,
            presentedArtifacts: artifacts.filter { !isScratchPath($0) },
            doneTitle: oneLine(bodies["DONE_TITLE"]),
            routine: decodeRoutine(bodies["ROUTINE"]),
            computerUseRequest: nonempty(bodies["COMPUTER_USE_REQUEST"])
        )
    }

    private static let tagExpression = try? NSRegularExpression(
        pattern: #"<(SUMMARY|NEXT_ACTIONS|ARTIFACTS|DONE_TITLE|ROUTINE|COMPUTER_USE_REQUEST)>([\s\S]*?)</\1>"#
    )

    private static func bare(_ text: String) -> AgentReplyBlocks {
        AgentReplyBlocks(
            spokenText: tidy(text),
            summary: nil,
            presentedSummary: nil,
            nextActions: [],
            presentedNextActions: [],
            artifacts: [],
            presentedArtifacts: [],
            doneTitle: nil,
            routine: nil,
            computerUseRequest: nil
        )
    }

    private static func tidy(_ text: String) -> String {
        var result = text
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonempty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func oneLine(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let joined = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    private static func list(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split(whereSeparator: \.isNewline).compactMap { line in
            let cleaned = stripListMarker(String(line))
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    private static func stripListMarker(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: #"^(?:[-*•]|\d+[.)])\s+"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func presentSummary(_ summary: String?) -> String? {
        guard let summary else { return nil }
        let capped = String(summary.prefix(presentedSummaryLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return capped.isEmpty ? nil : capped
    }

    private static func presentActions(_ actions: [String]) -> [String] {
        actions.prefix(presentedNextActionLimit).compactMap { action in
            let capped = String(action.prefix(presentedNextActionCharacterLimit))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return capped.isEmpty ? nil : capped
        }
    }

    /// Workspace scratch lives in `tmp/`. Those paths stay in `artifacts` and
    /// drop out of what we would show.
    private static func isScratchPath(_ value: String) -> Bool {
        let path: String
        if let url = URL(string: value),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            path = url.path
        } else {
            path = value
        }
        return path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .contains { $0.caseInsensitiveCompare("tmp") == .orderedSame }
    }

    private static func decodeRoutine(_ raw: String?) -> AgentRoutineRequest? {
        guard var json = nonempty(raw) else { return nil }
        if json.hasPrefix("```") {
            json = json.replacingOccurrences(of: "```json", with: "")
            json = json.replacingOccurrences(of: "```", with: "")
            json = json.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = json.data(using: .utf8),
              var request = try? JSONDecoder().decode(AgentRoutineRequest.self, from: data) else {
            return nil
        }
        request.title = nonempty(request.title)
        request.task = nonempty(request.task)
        request.newTitle = nonempty(request.newTitle)
        return request
    }
}

/// What a `<ROUTINE>` block is asking HeyMate to do later.
nonisolated enum AgentRoutineAction: String, Codable, Equatable {
    case create
    case update
    case pause
    case resume
    case delete
}

nonisolated struct AgentRoutineRequest: Codable, Equatable {
    var action: AgentRoutineAction
    var everyMinutes: Int?
    var title: String?
    var task: String?
    var newTitle: String?

    enum CodingKeys: String, CodingKey {
        case action
        case everyMinutes = "every_minutes"
        case title
        case task
        case newTitle = "new_title"
    }

    /// Shaped for a later scheduler. Parsing does not create or change one.
    var declaration: AgentRoutineDeclaration {
        switch action {
        case .create:
            return .create(everyMinutes: everyMinutes, title: title, task: task)
        case .update:
            return .update(everyMinutes: everyMinutes, title: title, task: task, newTitle: newTitle)
        case .pause:
            return .pause(title: title)
        case .resume:
            return .resume(title: title)
        case .delete:
            return .delete(title: title)
        }
    }
}

nonisolated enum AgentRoutineDeclaration: Equatable {
    case create(everyMinutes: Int?, title: String?, task: String?)
    case update(everyMinutes: Int?, title: String?, task: String?, newTitle: String?)
    case pause(title: String?)
    case resume(title: String?)
    case delete(title: String?)
}

nonisolated extension AgentFinalResult {
    /// Blocks parsed from the answer this result selected.
    var replyBlocks: AgentReplyBlocks {
        AgentReplyBlocks.extract(from: answerText)
    }
}
