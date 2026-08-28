//
//  SpokenTextTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct SpokenTextTests {

    @Test func normalizedSpokenCommandTextFoldsCaseAndStripsPunctuation() {
        #expect(
            SpokenText.normalizedSpokenCommandText("Hey, Café!") == "hey cafe"
        )
        #expect(
            SpokenText.wordCount(in: SpokenText.normalizedSpokenCommandText("one, two; three")) == 3
        )
    }

    @Test func normalizedCommandCandidateStripsHeyMateFiller() {
        #expect(
            SpokenText.normalizedCommandCandidate(from: "ok heymate, open Safari") == "open Safari"
        )
        #expect(
            SpokenText.normalizedCommandCandidate(from: "hey mate, volume up") == "volume up"
        )
        #expect(
            SpokenText.normalizedCommandCandidate(from: "let's try that again, build a landing page")
                == "build a landing page"
        )
    }

    @Test func normalizedAgentTaskInstructionPeelsPoliteWrappers() {
        #expect(
            SpokenText.normalizedAgentTaskInstruction(from: "can you inspect the logs")
                == "inspect the logs"
        )
        #expect(
            SpokenText.normalizedAgentTaskInstruction(from: "please tell an agent to fix the build")
                == "fix the build"
        )
    }
}
