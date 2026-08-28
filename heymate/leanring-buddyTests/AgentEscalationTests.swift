//
//  AgentEscalationTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct AgentEscalationTests {

    @Test func filesystemCapabilityRefusalEscalatesToAgent() {
        #expect(
            AgentEscalation.shouldEscalate(
                responseText: "i don't have access to your file system directly, so i can't browse your desktop files.",
                transcript: "what files are on my desktop?"
            )
        )
        #expect(
            AgentEscalation.agentInstruction(from: "what files are on my desktop?")
                .contains("Inspect the relevant local files or folders")
        )
    }

    @Test func screenQuestionsDoNotEscalate() {
        #expect(
            !AgentEscalation.shouldEscalate(
                responseText: "i can't see your files from here.",
                transcript: "what's on my screen?"
            )
        )
    }

    @Test func ordinaryTalkRefusalsDoNotEscalate() {
        #expect(
            !AgentEscalation.shouldEscalate(
                responseText: "i don't know the capital of that.",
                transcript: "what's the capital of france?"
            )
        )
    }

    @Test func heymateAgentRefusalEscalatesSuitableWork() {
        #expect(
            AgentEscalation.shouldEscalate(
                responseText: "that needs heymate's agent route.",
                transcript: "inspect the github repo"
            )
        )
    }
}
