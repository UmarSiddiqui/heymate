//
//  OnboardingInterview.swift
//  HeyMate
//
//  The "getting to know you" step of the welcome tour. HeyMate asks three
//  short questions, reacts to each answer, and at the end suggests three
//  mates shaped around what it heard. The questions after the first come
//  from the user's own AI, so they follow the conversation; when that AI
//  can't be reached the interview falls back to fixed questions and simply
//  doesn't suggest mates.
//
//  Pure value types: the coordinator does the asking and the speaking.
//

import Foundation

/// One line in the interview, shown as a speech bubble.
struct OnboardingInterviewLine: Identifiable, Equatable {
    enum Speaker: Equatable {
        case heyMate
        case user
    }

    let id = UUID()
    let speaker: Speaker
    let text: String

    static func == (lhs: OnboardingInterviewLine, rhs: OnboardingInterviewLine) -> Bool {
        lhs.speaker == rhs.speaker && lhs.text == rhs.text
    }
}

/// A mate the interview suggests making.
struct OnboardingMateSuggestion: Equatable, Decodable {
    let name: String
    let job: String
}

/// What the AI sends back after each answer.
enum OnboardingInterviewReply: Equatable {
    /// A short reaction, then the next question.
    case next(reaction: String, question: String)
    /// A short reaction, one line on what HeyMate took away, and the mates.
    case wrapUp(reaction: String, summary: String, mates: [OnboardingMateSuggestion])
}

enum OnboardingInterview {
    /// Answers HeyMate collects before wrapping up.
    static let answerCount = 3

    static let openingQuestion = "What are you working on these days?"

    /// Used in order when the AI can't be reached.
    static let fallbackQuestions = [
        "What would you most like to get done this month?",
        "Which apps do you spend most of your day in?",
    ]

    static let fallbackReactions = ["Love that.", "Got it.", "Nice."]

    static let systemPrompt = """
    you are heymate, a friendly companion that lives in the mac's notch. a new user is setting you up, and you are getting to know them with a few short questions so you can be useful from day one.

    the conversation so far is below, one line per turn. ask about one thing at a time: what they're working on, what they want to get done soon, and the apps or tools they use most. build on what they actually said.

    keep it warm and short. a reaction is at most ten words and never repeats their words back. a question is at most sixteen words. no emojis.

    after the user has answered \(answerCount) questions, wrap up: one reaction, one sentence on what you took away about them, and exactly three mates for them. a mate is a helper with its own job. each mate has a short friendly name (one or two words, title case, not a person's real name) and a job: one sentence, starting with a verb, about work that mate will do for this user specifically.

    reply with json only, nothing before or after it. while asking:
    {"reaction": "...", "question": "..."}
    when wrapping up:
    {"reaction": "...", "summary": "...", "mates": [{"name": "...", "job": "..."}, {"name": "...", "job": "..."}, {"name": "...", "job": "..."}]}
    """

    /// The transcript the AI sees: who said what, in order.
    static func transcript(_ lines: [OnboardingInterviewLine]) -> String {
        lines.map { line in
            (line.speaker == .heyMate ? "heymate: " : "user: ") + line.text
        }
        .joined(separator: "\n")
    }

    /// Reads the AI's reply. Tolerates prose or code fences around the JSON.
    /// Nil when there is nothing usable, so the caller falls back.
    static func parseReply(_ text: String) -> OnboardingInterviewReply? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawReply.self, from: data)
        else { return nil }

        let reaction = clean(raw.reaction)
        if let mates = raw.mates {
            let usable = mates
                .map { OnboardingMateSuggestion(name: clean($0.name), job: clean($0.job)) }
                .filter { !$0.name.isEmpty && !$0.job.isEmpty }
            guard !usable.isEmpty else { return nil }
            return .wrapUp(reaction: reaction, summary: clean(raw.summary), mates: Array(usable.prefix(3)))
        }
        let question = clean(raw.question)
        guard !question.isEmpty else { return nil }
        return .next(reaction: reaction, question: question)
    }

    private struct RawReply: Decodable {
        let reaction: String?
        let question: String?
        let summary: String?
        let mates: [OnboardingMateSuggestion]?
    }

    private static func clean(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Name

    /// The name in "my name is Sam", "I'm Sam", "call me Sam" or just "Sam".
    /// Nil when the answer doesn't look like a name, so HeyMate doesn't
    /// greet someone as "Testing".
    static func name(fromIntroduction transcript: String) -> String? {
        let words = transcript
            .replacingOccurrences(of: "[^\\p{L}\\p{M}'\\- ]", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
        guard !words.isEmpty else { return nil }

        let lowered = words.map { $0.lowercased() }
        let markers: [[String]] = [["my", "name", "is"], ["name", "is"], ["i", "am"], ["i'm"], ["im"], ["call", "me"], ["it's"], ["this", "is"]]
        var candidate: String?
        for marker in markers {
            if let range = firstRange(of: marker, in: lowered), range.upperBound < words.count {
                candidate = words[range.upperBound]
                break
            }
        }
        if candidate == nil, words.count <= 2 {
            candidate = words.first(where: { !greetings.contains($0.lowercased()) })
        }
        guard let name = candidate, name.count >= 2, name.count <= 24,
              !notNames.contains(name.lowercased()) else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private static let greetings: Set<String> = ["hi", "hey", "hello", "yo", "heymate", "hey-mate"]
    private static let notNames: Set<String> = [
        "testing", "test", "here", "just", "not", "so", "a", "the", "hi", "hey", "hello",
        "fine", "good", "ok", "okay", "yes", "no", "doing", "going", "working", "trying",
    ]

    private static func firstRange(of needle: [String], in haystack: [String]) -> Range<Int>? {
        guard needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<start + needle.count]) == needle {
            return start..<start + needle.count
        }
        return nil
    }
}
