//
//  MateCreation.swift
//  HeyMate
//
//  Local mate commands. Parsing and naming never call a model.
//

import Foundation

nonisolated struct MateCreationRequest: Equatable {
    var name: String?
    var job: String
    var soul: String = ""
}

nonisolated enum MateCreationParser {
    static let maximumCount = 5

    /// Compatibility projection for callers that only need the jobs.
    static func parse(_ text: String) -> [String]? {
        parseRequests(text)?.map(\.job)
    }

    /// Explicit creation commands only. Quoted examples, questions, and
    /// negated requests never mutate the roster. Legacy lists are capped at
    /// five; named creation keeps the supplied name and later instructions.
    static func parseRequests(_ text: String) -> [MateCreationRequest]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let named = namedRequest(in: trimmed) { return [named] }

        if let colon = trimmed.firstIndex(of: ":") {
            let head = String(trimmed[..<colon])
            let listHead = #"(?i)^(?:please\s+)?make\s+me\s+(?:(?:a|an|one|two|three|four|five|\d+)\s+)?(?:mates?|clickys?)\s*$"#
            if head.range(of: listHead, options: .regularExpression) != nil {
                let tail = String(trimmed[trimmed.index(after: colon)...])
                guard !hasRequestQualifier(in: tail) else { return nil }
                let jobs = splitJobs(tail)
                guard !jobs.isEmpty else { return nil }
                let requested = requestedCount(in: head) ?? jobs.count
                return jobs.prefix(min(maximumCount, max(1, requested))).map {
                    MateCreationRequest(name: nil, job: $0)
                }
            }
        }

        let pattern = #"(?i)^(?:please\s+)?make\s+me\s+(?:(?:a|an|one|two|three|four|five|\d+)\s+)?(?:mate|mates|clicky|clickys)\s+(?:that|who|to)\s+(.+)$"#
        guard let job = firstCapture(pattern, in: trimmed) else { return nil }
        let jobText = job.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jobText.isEmpty, !hasRequestQualifier(in: jobText) else { return nil }
        return [MateCreationRequest(name: nil, job: jobText)]
    }

    private static func namedRequest(in text: String) -> MateCreationRequest? {
        let pattern = #"(?is)^(?:please\s+)?(?:create|make|add)\s+(?:me\s+)?(?:(?:a|an)\s+)?(?:test\s+)?mate\s+(?:named|called)\s+(?:"([^"]+)"|'([^']+)'|“([^”]+)”|([^,:\n]+?))\s*[,:]\s*(.+)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let jobRange = Range(match.range(at: 5), in: text) else { return nil }
        let name = (1...4).compactMap { index -> String? in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }.first ?? ""
        guard !name.isEmpty, !name.hasPrefix("\""), !name.hasPrefix("'"),
              !name.hasPrefix("“"), !name.hasPrefix("”") else { return nil }

        let description = String(text[jobRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty, !hasRequestQualifier(in: description, name: name) else { return nil }
        // The first sentence describes the job; the remaining sentences are
        // retained verbatim as behavior, not executed as another command.
        if let boundary = description.range(of: #"\.\s+"#, options: .regularExpression) {
            let job = String(description[..<boundary.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let soul = String(description[boundary.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !job.isEmpty else { return nil }
            return MateCreationRequest(name: name, job: job, soul: soul)
        }
        return MateCreationRequest(name: name, job: description)
    }

    /// Local mutation is reserved for one unconditional creation request.
    /// These clause-level guards leave ambiguous input to ordinary chat;
    /// behavior such as waiting before a lesson or avoiding files is valid.
    private static func hasRequestQualifier(in description: String, name: String? = nil) -> Bool {
        let clause = #"(?:^|[.!?;,\n—–])\s*"#
        let transition = #"(?:(?:actually|but|then|also|and|next|please|wait)\s*[,;:]?\s+)*"#
        let cancellationStart = "(?:" + clause + transition + #"|\b(?:but|actually)\s+)"#
        let secondCommandStart = "(?:" + clause + transition + #"|\b(?:and|then|also)\s+)"#
        let namedObject = name.map { "|" + NSRegularExpression.escapedPattern(for: $0) } ?? ""
        let mateObject = #"(?:(?:(?:a|an|the|another|any)\s+)?(?:test\s+)?mates?"# + namedObject + ")"
        let creationObject = "(?:it|that|this|" + mateObject + ")"
        let negation = #"(?:do\s+not|don['’]t|never)\s+"#
        let patterns = [
            // A cancellation targets creation itself, not files or routines.
            cancellationStart + negation + #"(?:create|add|save)\s+(?:"# + creationObject + #"\b|(?:yet|now|until)\b)"#,
            // "Don't make it boring" describes behavior, not cancellation.
            cancellationStart + negation + #"make\s+(?:"# + mateObject + #"\b|(?:it|that|this)(?:\s+(?:yet|now|until)\b|\s*[.!?;]|\s*$))"#,
            cancellationStart + #"(?:never\s*mind|cancel\s+(?:that|this|it|the\s+(?:request|creation)))\b"#,
            // A standalone approval clause applies to this request. A tutor
            // can still wait for confirmation before each lesson step.
            clause + transition + #"(?:only\s+)?(?:after|once|if|when|until)\s+(?:I|we)\s+(?:(?:explicitly|first)\s+)?(?:confirm|approve)\b"#,
            clause + #"(?:please\s+)?(?:wait|ask)\s+for\s+(?:my|our)\s+(?:approval|confirmation)\s*(?:[.!?]|$|before\s+(?:creating|making|adding|saving)\b)"#,
            clause + transition + #"is\s+(?:that|this|it)\s+(?:the|a)\s+(?:right|correct|valid)\s+(?:command|syntax)\s*\?"#,
            // Do not store a second roster command as the first mate's soul.
            secondCommandStart + #"(?:create|make|add)\s+(?:me\s+)?(?:(?:a|an|another|one|two|three|four|five|\d+)\s+)?(?:test\s+)?(?:mates?|clickys?)\b"#
        ]
        return patterns.contains { description.range(of: "(?i)" + $0, options: .regularExpression) != nil }
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
