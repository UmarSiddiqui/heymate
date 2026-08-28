//
//  SpokenText.swift
//  leanring-buddy
//
//  Pure transcript normalization. Closed cluster: these functions only call
//  each other. HeyMate-owned rewrite of the OpenClicky SpokenText kernel.
//

import Foundation

nonisolated enum SpokenText {

    /// Lowercased, diacritic-folded, punctuation-stripped, single-spaced form
    /// of a transcript — the surface routing predicates match.
    static func normalizedSpokenCommandText(_ transcript: String) -> String {
        transcript
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            // Apostrophes collapse away rather than becoming spaces: "don't"
            // has to normalize to "dont", not "don t", or every contraction
            // pattern below silently stops matching its own input.
            .replacingOccurrences(of: "['\u{2018}\u{2019}\u{02BC}]", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]+"#, with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
    }

    /// Strips leading filler ("hey", "ok heymate", "let's try that again")
    /// and trailing punctuation so a raw transcript becomes a command.
    static func normalizedCommandCandidate(from transcript: String) -> String {
        leadingFillerStripped(from: transcript)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-\u{2013}\u{2014}\u{2026}"))
    }

    /// Same leading-filler strip as `normalizedCommandCandidate`, but keeps
    /// trailing punctuation. Prefix matchers need the comma in "agent," to
    /// still be there.
    static func leadingFillerStripped(from transcript: String) -> String {
        var candidate = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        let prefixPatterns = [
            #"(?i)^\s*(?:hey|ok|okay|right|so)[\s,]+"#,
            #"(?i)^\s*(?:heymate|hey mate|mate)[\s,]+"#,
            #"(?i)^\s*i\s+(?:said|asked|told)\s+(?:for\s+you\s+to|you\s+to|to)\s+"#,
            #"(?i)^\s*(?:let's|lets)\s+try\s+(?:that|this)\s+again[\s,]+"#
        ]

        var didStripPrefix = true
        while didStripPrefix {
            didStripPrefix = false
            for pattern in prefixPatterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
                guard let match = regex.firstMatch(in: candidate, range: range),
                      let matchRange = Range(match.range, in: candidate) else { continue }
                candidate.removeSubrange(matchRange)
                candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                didStripPrefix = true
            }
        }

        return candidate
    }

    /// Peels polite wrappers ("can you…", "please…", "tell an agent to…")
    /// down to the bare instruction.
    static func normalizedAgentTaskInstruction(from instruction: String) -> String {
        var candidate = normalizedCommandCandidate(from: instruction)
        guard !candidate.isEmpty else { return candidate }

        let pattern = #"(?i)^\s*(?:(?:can|could|would|will)\s+you\s+|please\s+|(?:ask|tell)\s+(?:an?\s+|the\s+)?agent\s+to\s+)(.+?)[\.\!\?]*\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return candidate }

        // Wrappers stack ("please tell an agent to …"), so peel until stable.
        // Bounded so a pathological transcript cannot spin here.
        for _ in 0..<8 {
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            guard let match = regex.firstMatch(in: candidate, range: range),
                  let taskRange = Range(match.range(at: 1), in: candidate) else { break }
            let peeled = String(candidate[taskRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
            guard !peeled.isEmpty, peeled != candidate else { break }
            candidate = peeled
        }

        return candidate
    }

    static func cleanedAgentTaskInstruction(_ instruction: String) -> String {
        instruction
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t.,:;!?-"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
