//
//  SpokenText.swift
//  HeyMate
//
//  Turns a raw transcript into the forms the voice router matches against:
//  a folded, punctuation-free surface for word matching, and a command with
//  the "hey mate, okay, so…" lead-in and polite wrappers peeled off.
//

import Foundation

/// A regular expression compiled once, for matching transcripts.
nonisolated struct TextPattern: @unchecked Sendable {
    private let regex: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool = false) {
        if let regex = try? NSRegularExpression(
            pattern: pattern,
            options: caseInsensitive ? [.caseInsensitive] : []
        ) {
            self.regex = regex
        } else {
            assertionFailure("Invalid pattern: \(pattern)")
            // Never matches, so a bad rule disables itself instead of crashing.
            self.regex = try! NSRegularExpression(pattern: "(?!)")
        }
    }

    /// Any of `phrases` as whole words, where a space in a phrase stands for
    /// any run of whitespace. Phrases are literal text, not patterns.
    static func anyOf(_ phrases: [String], atStart: Bool = false) -> TextPattern {
        let alternatives = phrases.map {
            NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"\s+"#)
        }
        return TextPattern((atStart ? "^" : "") + #"\b(?:"# + alternatives.joined(separator: "|") + #")\b"#)
    }

    func matches(_ text: String) -> Bool {
        firstMatch(in: text) != nil
    }

    func firstMatch(in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
}

nonisolated enum SpokenText {
    /// Lowercase, accents folded, apostrophes dropped ("don't" becomes
    /// "dont", so contractions still match), every other non-alphanumeric
    /// run turned into one space, trimmed. One pass, no regex.
    static func normalizedSpokenCommandText(_ transcript: String) -> String {
        let folded = transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        var result = ""
        result.reserveCapacity(folded.utf8.count)
        var needsSpace = false
        for character in folded {
            if apostrophes.contains(character) { continue }
            if character.isLetter || character.isNumber {
                if needsSpace && !result.isEmpty { result.append(" ") }
                needsSpace = false
                result.append(character)
            } else {
                needsSpace = true
            }
        }
        return result
    }

    static func wordCount(in text: String) -> Int {
        text.split { !$0.isLetter && !$0.isNumber }.count
    }

    /// The transcript as a command: lead-in removed and trailing
    /// punctuation trimmed ("ok heymate, open Safari." → "open Safari").
    static func normalizedCommandCandidate(from transcript: String) -> String {
        leadingFillerStripped(from: transcript).trimmingCharacters(in: commandEdgePunctuation)
    }

    /// Removes the lead-in but keeps trailing punctuation, which prefix
    /// matchers rely on (the comma in "agent, …").
    static func leadingFillerStripped(from transcript: String) -> String {
        var command = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Lead-ins stack ("hey mate, okay, …"); peel until none is left.
        while let match = leadIn.firstMatch(in: command), match.range.length > 0,
              let range = Range(match.range, in: command) {
            command.removeSubrange(range)
            command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return command
    }

    /// The bare instruction inside a polite request: "can you inspect the
    /// logs" and "please tell an agent to fix the build" become "inspect
    /// the logs" and "fix the build".
    static func normalizedAgentTaskInstruction(from instruction: String) -> String {
        var task = normalizedCommandCandidate(from: instruction)
        // Wrappers stack; peel a bounded number so odd input can't spin.
        for _ in 0..<8 {
            guard let match = politeWrapper.firstMatch(in: task),
                  let range = Range(match.range(at: 1), in: task) else { break }
            let inner = task[range].trimmingCharacters(in: taskEdgePunctuation)
            guard !inner.isEmpty, inner != task else { break }
            task = inner
        }
        return task
    }

    static func cleanedAgentTaskInstruction(_ instruction: String) -> String {
        instruction
            .trimmingCharacters(in: taskEdgePunctuation)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Tables

    private static let apostrophes: Set<Character> = ["'", "\u{2018}", "\u{2019}", "\u{02BC}"]
    private static let taskEdgePunctuation = CharacterSet(charactersIn: " \n\t.,:;!?-")
    private static let commandEdgePunctuation = CharacterSet(charactersIn: " \n\t.,:;!?-\u{2013}\u{2014}\u{2026}")

    /// One lead-in at the start of a transcript, with what separates it
    /// from the rest. Matched against the raw transcript, ignoring case.
    private static let leadIn: TextPattern = {
        let greetings = "(?:hey|ok|okay|right|so)"
        let wakeWords = "(?:heymate|hey mate|mate)"
        let repeats = #"i\s+(?:said|asked|told)\s+(?:for\s+you\s+to|you\s+to|to)"#
        let retries = #"(?:let's|lets)\s+try\s+(?:that|this)\s+again"#
        return TextPattern(
            #"^\s*(?:"# + "\(greetings)[\\s,]+|\(wakeWords)[\\s,]+|\(repeats)\\s+|\(retries)[\\s,]+" + ")",
            caseInsensitive: true
        )
    }()

    /// "can you / could you / would you / will you / please / ask (an|a|the)
    /// agent to / tell (an|a|the) agent to" followed by the task (group 1).
    private static let politeWrapper = TextPattern(
        #"^\s*(?:(?:can|could|would|will)\s+you\s+|please\s+|(?:ask|tell)\s+(?:an?\s+|the\s+)?agent\s+to\s+)(.+?)[.!?]*\s*$"#,
        caseInsensitive: true
    )
}
