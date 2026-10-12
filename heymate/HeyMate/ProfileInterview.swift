//
//  ProfileInterview.swift
//  HeyMate
//
//  Four onboarding questions that become PROFILE.md in a workspace folder.
//  No model call. A later pass wires this into first-run UI.
//

import Foundation

enum ProfileInterview {
    static let profileFileName = "PROFILE.md"
    static let emptyAnswerPlaceholder = "Not answered yet"

    static let questions: [String] = [
        "What do you mostly do — the work people would ask you about?",
        "Which apps do you live in most days?",
        "What should an agent never do without you asking first?",
        "What's one thing you want done this week?",
    ]

    static func profileMarkdown(name: String, answers: [String]) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [String] = [trimmedName.isEmpty ? "# Profile" : "# \(trimmedName)", ""]
        for (section, answer) in zip(sectionTitles, normalizedAnswers(answers)) {
            sections.append("## \(section)")
            sections.append("")
            sections.append(displayedAnswer(answer))
            sections.append("")
        }
        while sections.last == "" {
            sections.removeLast()
        }
        return sections.joined(separator: "\n") + "\n"
    }

    static func write(name: String, answers: [String], to directory: URL) throws {
        let url = directory.appendingPathComponent(profileFileName)
        let markdown = profileMarkdown(name: name, answers: answers)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    private static let sectionTitles = ["Identity", "Apps", "Boundaries", "This week"]

    private static func normalizedAnswers(_ answers: [String]) -> [String] {
        var padded = Array(answers.prefix(sectionTitles.count))
        while padded.count < sectionTitles.count {
            padded.append("")
        }
        return padded
    }

    private static func displayedAnswer(_ answer: String) -> String {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? emptyAnswerPlaceholder : trimmed
    }
}
