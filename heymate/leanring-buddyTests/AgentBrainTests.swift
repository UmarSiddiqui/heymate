//
//  AgentBrainTests.swift
//  leanring-buddyTests
//
//  The Brain picker is the one choice of what runs HeyMate. These tests
//  lock the mapping so Talk vs Agents cannot drift back into two pickers.
//

import Testing
@testable import HeyMate

struct AgentBrainTests {

    @Test func displayNamesMatchThePickerLabels() {
        #expect(AgentBrain.codex.displayName == "Codex")
        #expect(AgentBrain.claudeCode.displayName == "Claude")
        #expect(AgentBrain.openCode.displayName == "OpenCode")
        #expect(AgentBrain.customAPI.displayName == "Custom API")
    }

    @Test func claudeAndCodexAndOpenCodeRunAgentJobs() {
        #expect(AgentBrain.claudeCode.executor == .claudeCode)
        #expect(AgentBrain.openCode.executor == .openCode)
        #expect(AgentBrain.codex.executor == .codex)
        #expect(AgentBrain.customAPI.executor == nil)
    }

    @Test func onlyCustomAPICannotStartAJob() {
        #expect(AgentBrain.customAPI.unavailableReason != nil)
        #expect(AgentBrain.codex.unavailableReason == nil)
        #expect(AgentBrain.claudeCode.unavailableReason == nil)
        #expect(AgentBrain.openCode.unavailableReason == nil)
    }

    @Test func subscriptionBrainsTalkThroughTheirCLI() {
        #expect(AgentBrain.claudeCode.talkNeedsSeparateVisionEndpoint == false)
        #expect(AgentBrain.codex.talkNeedsSeparateVisionEndpoint == false)
        #expect(AgentBrain.openCode.talkNeedsSeparateVisionEndpoint == false)
        #expect(AgentBrain.customAPI.talkNeedsSeparateVisionEndpoint == false)
    }
}
