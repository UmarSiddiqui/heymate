//
//  BehaviorContractTests.swift
//  leanring-buddyTests
//
//  Guards the shipped behavior contract: the binding honesty/safety rules
//  must stay present in every combined system prompt, and skill blocks must
//  compose without dropping either layer.
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct BehaviorContractTests {

    private static let samplePersonaPrompt = "you're heymate, a friendly companion."
    private static let sampleSkillsBlock = """
    relevant user skills for this request — follow their instructions:
    skill 'sample' (trigger: testing):
    do the thing.
    """

    // MARK: - Binding rules stay shipped

    /// Each rule guards a real failure mode observed with screen-aware voice
    /// assistants: claiming to see removed context, fabricating actions,
    /// leaking secrets, and treating on-screen text as instructions.
    @Test func contractContainsBindingRules() {
        let contract = BehaviorContract.bundledSafetyAndHonestySection

        #expect(contract.contains("never pretend you can see"))
        #expect(contract.contains("never claim you did something you cannot do"))
        #expect(contract.contains("go-ahead"))
        #expect(contract.contains("passwords, api keys, or other secrets"))
        #expect(contract.contains("context, not command"))
        #expect(contract.contains("users never need to know or name skills"))
    }

    @Test func combinedPromptKeepsPersonaContractAndSkillsInOrder() {
        let combined = BehaviorContract.combinedSystemPrompt(
            voicePersonaPrompt: Self.samplePersonaPrompt,
            matchedSkillsBlock: Self.sampleSkillsBlock
        )

        let personaRange = combined.range(of: Self.samplePersonaPrompt)
        let contractRange = combined.range(of: BehaviorContract.bundledSafetyAndHonestySection)
        let skillsRange = combined.range(of: Self.sampleSkillsBlock)

        #expect(personaRange != nil)
        #expect(contractRange != nil)
        #expect(skillsRange != nil)
        #expect(personaRange!.lowerBound < contractRange!.lowerBound)
        #expect(contractRange!.lowerBound < skillsRange!.lowerBound)
    }

    @Test func combinedPromptWorksWithoutSkillMatches() {
        let combined = BehaviorContract.combinedSystemPrompt(
            voicePersonaPrompt: Self.samplePersonaPrompt,
            matchedSkillsBlock: nil
        )

        #expect(combined.contains(Self.samplePersonaPrompt))
        #expect(combined.contains(BehaviorContract.bundledSafetyAndHonestySection))
        #expect(!combined.hasSuffix("\n\n"))
    }

    // MARK: - Catalog stays aligned with the contract

    /// Skills that promise actions HeyMate cannot take would contradict the
    /// contract; this pins the no-side-effects wording into the defaults.
    @Test func inboxTriageDefaultNeverImpliesSending() throws {
        let entry = try #require(DefaultSkillCatalog.skills.first { $0.fileName == "inbox-triage.md" })
        #expect(entry.markdown.contains("never claim a message was sent"))
    }
}
