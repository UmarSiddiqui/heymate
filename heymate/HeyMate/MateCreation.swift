//
//  MateCreation.swift
//  HeyMate
//
//  Local mate commands. Parsing and naming never call a model.
//

import Foundation

nonisolated enum MateCreationParser {
    static let maximumCount = 5

    /// Jobs to create, capped at five. Nil when the text is not a mate command.
    /// "clicky" is an alias for "mate" in this parser only.
    static func parse(_ text: String) -> [String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folded = trimmed.lowercased()
        guard folded.contains("make"), mentionsMateAlias(folded) else { return nil }

        if let colon = trimmed.firstIndex(of: ":") {
            let head = String(trimmed[..<colon])
            guard mentionsMateAlias(head.lowercased()) else { return nil }
            let jobs = splitJobs(String(trimmed[trimmed.index(after: colon)...]))
            guard !jobs.isEmpty else { return nil }
            let requested = requestedCount(in: head) ?? jobs.count
            return Array(jobs.prefix(min(maximumCount, max(1, requested))))
        }

        let pattern = #"(?i)^(?:please\s+)?make\s+me\s+(?:(?:a|an|one|two|three|four|five|\d+)\s+)?(?:mate|mates|clicky|clickys)\s+(?:that|who|to)\s+(.+)$"#
        guard let job = firstCapture(pattern, in: trimmed) else { return nil }
        let jobText = job.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jobText.isEmpty else { return nil }
        return [jobText]
    }

    private static func mentionsMateAlias(_ folded: String) -> Bool {
        folded.range(of: #"\b(?:mates?|clickys?)\b"#, options: .regularExpression) != nil
    }

    private static func splitJobs(_ tail: String) -> [String] {
        tail.replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func requestedCount(in head: String) -> Int? {
        let words = [
            "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5
        ]
        let tokens = head.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        for token in tokens {
            if let count = words[token] { return count }
            if let count = Int(token), (1...maximumCount).contains(count) { return count }
        }
        return nil
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[capture])
    }
}

nonisolated enum MateNameGenerator {
    private static let stopWords: Set<String> = [
        "a", "an", "the", "my", "your", "our", "me", "i", "that", "this", "to", "for",
        "and", "of", "on", "in", "with", "from", "into", "at", "by", "is", "are", "be",
        "it", "watches", "watch", "watching", "checks", "check", "checking", "keep",
        "keeps", "keeping", "make", "makes", "making", "please", "who", "monitors",
        "monitor", "monitoring", "tracks", "track", "tracking", "reads", "read",
        "reading", "scans", "scan", "scanning", "looks", "look", "looking", "helps",
        "help", "helping", "handles", "handle", "handling", "manages", "manage",
        "managing", "does", "do", "doing", "buddy", "mate", "clicky"
    ]

    private static let roles = [
        "Scout", "Keeper", "Pilot", "Clerk", "Scribe", "Ranger", "Guide", "Herald", "Curator", "Warden"
    ]

    private static let prefixes = ["Keen", "Steady", "Quiet", "Bright", "Swift", "Calm", "Clear", "Early"]

    static func name(for job: String, existingNames: [String]) -> String {
        let words = contentWords(in: job)
        let taken = Set(existingNames.map(FileMateStore.normalized))
        for candidate in candidates(from: words) where isAcceptable(candidate, taken: taken) {
            return candidate
        }
        let stem = words.first.map(titleWord) ?? "Field"
        return "\(prefixes[0]) \(stem)"
    }

    private static func candidates(from words: [String]) -> [String] {
        var names: [String] = []
        if words.count >= 2 {
            names.append("\(titleWord(words[0])) \(titleWord(words[1]))")
        }
        let stem = words.first.map(titleWord) ?? "Field"
        for role in roles {
            names.append("\(stem) \(role)")
        }
        for prefix in prefixes {
            names.append("\(prefix) \(stem)")
        }
        if words.count >= 2 {
            let second = titleWord(words[1])
            for role in roles {
                names.append("\(second) \(role)")
            }
        }
        return names
    }

    private static func isAcceptable(_ name: String, taken: Set<String>) -> Bool {
        let parts = name.split(separator: " ")
        guard parts.count == 2 else { return false }
        guard !name.lowercased().hasSuffix("buddy") else { return false }
        return !taken.contains(FileMateStore.normalized(name))
    }

    private static func contentWords(in job: String) -> [String] {
        job.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    private static func titleWord(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst().lowercased()
    }
}
