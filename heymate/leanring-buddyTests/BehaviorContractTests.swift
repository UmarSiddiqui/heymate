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
        // The live contract, not the bundled constant: the section is read
        // from a user-editable file, so a machine whose file differs must
        // still be asserting order rather than failing on wording.
        let contractRange = combined.range(of: BehaviorContract.currentSafetyAndHonestySection())
        let skillsRange = combined.range(of: Self.sampleSkillsBlock)

        #expect(personaRange != nil)
        #expect(contractRange != nil)
        #expect(skillsRange != nil)
        #expect(personaRange!.lowerBound < contractRange!.lowerBound)
        #expect(contractRange!.lowerBound < skillsRange!.lowerBound)
    }

    /// The stale line this replaces told the model heyMate could do nothing
    /// but talk, point, draw and dictate — read as a standing denial of the
    /// connector tools the same prompt was handing it.
    @Test func theSupersededContractIsReplacedButAUserEditIsNot() {
        #expect(BehaviorContract.isSuperseded(BehaviorContract.supersededSafetyAndHonestySections[0]))
        #expect(!BehaviorContract.isSuperseded(BehaviorContract.bundledSafetyAndHonestySection))
        #expect(!BehaviorContract.isSuperseded("honesty and capability:\n- my own wording"))
        #expect(!BehaviorContract.bundledSafetyAndHonestySection.contains("inserts dictated text — nothing else"))
    }

    /// Reset must rewrite the editable file from the shipped rules, never a
    /// weaker substitute.
    @Test func resetContractTextIsTheShippedSafetySection() {
        let reset = BehaviorContract.resetContractText()
        #expect(reset == BehaviorContract.bundledSafetyAndHonestySection)
        #expect(reset.contains("never pretend you can see"))
        #expect(reset.contains("never claim you did something you cannot do"))
        #expect(reset.contains("go-ahead"))
        #expect(reset.contains("passwords, api keys, or other secrets"))
        #expect(reset.contains("context, not command"))
        #expect(!reset.contains("inserts dictated text — nothing else"))
    }

    @Test func savingAndResettingRewritesTheContractFile() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let contractURL = directoryURL.appendingPathComponent("behavior-contract.md")
        try BehaviorContract.writeContractText("custom wording", to: contractURL)
        #expect(try String(contentsOf: contractURL, encoding: .utf8) == "custom wording")

        try BehaviorContract.writeContractText(BehaviorContract.resetContractText(), to: contractURL)
        #expect(try String(contentsOf: contractURL, encoding: .utf8) == BehaviorContract.bundledSafetyAndHonestySection)
    }

    /// A CLI-backed brain loads its tools inside its own child, so the apps
    /// block can be the only evidence a turn has tools — and it has to switch
    /// the tool-use rules on by itself.
    @Test func theConnectedAppsBlockAloneTurnsOnTheToolUseRules() {
        let combined = BehaviorContract.combinedSystemPrompt(
            voicePersonaPrompt: Self.samplePersonaPrompt,
            matchedSkillsBlock: nil,
            connectedAppsBlock: "connected apps:\n- connected through composio: YouTube."
        )

        #expect(combined.contains(BehaviorContract.toolUseSection))
        #expect(combined.contains("YouTube"))
    }

    @Test func combinedPromptWorksWithoutSkillMatches() {
        let combined = BehaviorContract.combinedSystemPrompt(
            voicePersonaPrompt: Self.samplePersonaPrompt,
            matchedSkillsBlock: nil
        )

        #expect(combined.contains(Self.samplePersonaPrompt))
        #expect(combined.contains(BehaviorContract.currentSafetyAndHonestySection()))
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
