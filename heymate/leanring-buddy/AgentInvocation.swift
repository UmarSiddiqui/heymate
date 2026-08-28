//
//  AgentInvocation.swift
//  leanring-buddy
//
//  Detects spoken/typed agent launches so Talk can hand off to a headless
//  coding session instead of answering in the vision chat path. Matching is
//  prefix-only for “agent,”; construction phrases like “build a landing page”
//  also count because users type those into Ask anything without the prefix.
//

import Foundation

/// Pulls a task string out of a Talk/typed transcript when the user asked
/// for an agent. `nil` means this turn is ordinary Talk.
nonisolated enum AgentInvocation {

    /// Returns the task to hand to the coding agent, trimmed. Empty remainder
    /// after an explicit `agent,` prefix still counts as an invocation (the
    /// launcher fails the job with a clear error rather than silently Talk).
    static func parse(_ transcript: String) -> String? {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return nil }

        // Prefix matching runs before trailing punctuation is trimmed, so the
        // comma in "agent," is still there to match against.
        let prefixCandidate = SpokenText.leadingFillerStripped(from: trimmedTranscript)
        guard !prefixCandidate.isEmpty else { return nil }

        for prefix in prefixes {
            if let remainder = remainder(afterPrefix: prefix, in: prefixCandidate) {
                return remainder
            }
        }

        let candidate = SpokenText.normalizedCommandCandidate(from: trimmedTranscript)
        guard !candidate.isEmpty else { return nil }

        if looksLikeCodingTask(candidate) {
            return candidate
        }
        return nil
    }

    /// True when Talk should skip the vision pipeline.
    static func isAgentRequest(_ transcript: String) -> Bool {
        parse(transcript) != nil
    }

    /// The task when the user *said the word* — "agent, …", "run an agent".
    /// Nil otherwise, including for construction phrases.
    ///
    /// Split out from `parse` because an explicit prefix is a decision the
    /// user already made: it skips the intent classifier entirely rather than
    /// paying a round trip to be told what the sentence plainly says.
    static func explicitPrefixTask(_ transcript: String) -> String? {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return nil }

        let prefixCandidate = SpokenText.leadingFillerStripped(from: trimmedTranscript)
        guard !prefixCandidate.isEmpty else { return nil }

        for prefix in prefixes {
            if let remainder = remainder(afterPrefix: prefix, in: prefixCandidate) {
                return remainder
            }
        }
        return nil
    }

    // Longer prefixes first so “hey mate agent,” wins over “agent,”.
    private static let prefixes = [
        "hey mate agent,",
        "heymate agent,",
        "run an agent,",
        "run an agent",
        "agent,"
    ]

    private static let constructionStarters = [
        "build ",
        "scaffold ",
        "implement ",
        "make a ",
        "make an ",
        "make me a ",
        "make me an ",
        "create a ",
        "create an ",
        "generate a ",
        "generate an ",
        "write a ",
        "write an "
    ]

    private static let codingArtifacts = [
        "landing page",
        "landing-page",
        "website",
        "web page",
        "webpage",
        "web app",
        "html",
        "macos app",
        "mac app",
        "component",
        "project"
    ]

    private static func remainder(afterPrefix prefix: String, in transcript: String) -> String? {
        guard transcript.lowercased().hasPrefix(prefix) else { return nil }
        let remainderStart = transcript.index(transcript.startIndex, offsetBy: prefix.count)
        return String(transcript[remainderStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// “build …” is always a coding job. “make/create/write a …” only if the
    /// rest names something you would put in a project folder — so “make this
    /// louder” stays Talk.
    ///
    /// This word list is no longer the routing brain; `VoiceIntentClassifier`
    /// is. It survives as the offline fallback for when that call fails, and
    /// is why "clean up my Downloads folder" used to vanish into Talk.
    private static func looksLikeCodingTask(_ transcript: String) -> Bool {
        let lowered = transcript.lowercased()
        if lowered.hasPrefix("build ") || lowered.hasPrefix("scaffold ") || lowered.hasPrefix("implement ") {
            return true
        }
        let startsWithConstruction = constructionStarters.contains { lowered.hasPrefix($0) }
        guard startsWithConstruction else { return false }
        return codingArtifacts.contains { lowered.contains($0) }
    }
}
