//
//  AgentInvocationTests.swift
//  leanring-buddyTests
//
//  Talk is screen-aware conversation. Agents launch only from an explicit
//  prefix or a construction phrase that names something to build.
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct AgentInvocationTests {

    @Test func agentCommaAtStartIsAnInvocation() {
        #expect(AgentInvocation.parse("agent, make a landing page") == "make a landing page")
        #expect(AgentInvocation.parse("Agent,  research cameras") == "research cameras")
    }

    @Test func fillerPrefixesStillReachAgentComma() {
        #expect(AgentInvocation.parse("ok heymate agent, draft a brief") == "draft a brief")
        #expect(AgentInvocation.parse("hey mate, agent, inspect the logs") == "inspect the logs")
    }

    @Test func heymatePrefixesAreRecognized() {
        #expect(AgentInvocation.parse("HeyMate agent, draft a brief") == "draft a brief")
        #expect(AgentInvocation.parse("hey mate agent, draft a brief") == "draft a brief")
        #expect(AgentInvocation.parse("run an agent to summarize this") == "to summarize this")
        #expect(AgentInvocation.parse("run an agent, summarize this") == "summarize this")
    }

    @Test func typedBuildALandingPageIsAnAgentTask() {
        #expect(AgentInvocation.parse("build a landing page") == "build a landing page")
        #expect(AgentInvocation.parse("Build a landing page") == "Build a landing page")
        #expect(AgentInvocation.parse("make a landing page") == "make a landing page")
        #expect(AgentInvocation.parse("create a website for this product") == "create a website for this product")
    }

    @Test func screenQuestionsAreStillTalk() {
        #expect(AgentInvocation.parse("what's on my screen") == nil)
        #expect(AgentInvocation.parse("point at the save button") == nil)
        #expect(AgentInvocation.parse("make this louder") == nil)
        #expect(AgentInvocation.parse("agentic workflow for this repo") == nil)
    }

    @Test func emptyTranscriptIsNotATask() {
        #expect(AgentInvocation.parse("") == nil)
        #expect(AgentInvocation.parse("   ") == nil)
    }

    @Test func emptyRemainderAfterPrefixStillCounts() {
        #expect(AgentInvocation.parse("agent,") == "")
        #expect(AgentInvocation.parse("agent,   ") == "")
    }
}
