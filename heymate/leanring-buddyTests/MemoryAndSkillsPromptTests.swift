//
//  MemoryAndSkillsPromptTests.swift
//  leanring-buddyTests
//
//  Tests for prompt-block composition (memory + skills) and the backend
//  request builder's URL/auth surface. File-backed memory itself is covered
//  in MemoryRepositoryTests; nothing here touches disk or network.
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct MemoryAndSkillsPromptTests {

    // MARK: - Memory prompt block

    @Test func emptyMemoryProducesNoBlock() {
        #expect(CompanionManager.memoryPromptBlock(items: []) == nil)
    }

    @Test func memoryBlockListsNewestFirstWithKindTags() {
        let items = [
            MemoryItem(
                id: UUID(), kind: .sessionSummary,
                text: "older exchange", createdAt: Date(timeIntervalSinceNow: -100)
            ),
            MemoryItem(
                id: UUID(), kind: .projectFact,
                text: "project X lives in ~/Projects/x", createdAt: Date()
            ),
        ]

        let block = CompanionManager.memoryPromptBlock(items: items)
        #expect(block != nil)
        #expect(block!.contains("[projectFact] project X"))
        // Newest first: projectFact line appears before the summary line.
        let factRange = block!.range(of: "[projectFact]")!
        let summaryRange = block!.range(of: "[sessionSummary]")!
        #expect(factRange.lowerBound < summaryRange.lowerBound)
    }

    @Test func memoryBlockCollapsesNewlinesSoItemsStayOneLine() {
        let item = MemoryItem(
            id: UUID(), kind: .preference,
            text: "line one\nline two", createdAt: Date()
        )
        let block = CompanionManager.memoryPromptBlock(items: [item])!
        #expect(!block.contains("line one\nline two"))
        #expect(block.contains("line one line two"))
    }

    @Test func memoryBlockRespectsLimit() {
        let many = (0..<12).map { index in
            MemoryItem(
                id: UUID(), kind: .projectFact,
                text: "fact\(index)", createdAt: Date(timeIntervalSinceNow: TimeInterval(index))
            )
        }
        let block = CompanionManager.memoryPromptBlock(items: many, limit: 8)!
        for index in 4..<12 {
            #expect(block.contains("fact\(index)"))
        }
        #expect(!block.contains("fact3"))
    }

    // MARK: - Topic anchor prompt fragment

    @Test func noPriorExchangeProducesNoAnchor() {
        #expect(CompanionManager.topicAnchorPromptFragment(mostRecentExchange: nil) == nil)
    }

    @Test func anchorQuotesMostRecentAssistantReply() {
        let fragment = CompanionManager.topicAnchorPromptFragment(
            mostRecentExchange: (
                userPlaceholder: "how do I create a rule to disable products without an image?",
                assistantResponse: "click add condition, target the product image field, set it to is empty."
            )
        )!
        #expect(fragment.contains("click add condition, target the product image field, set it to is empty."))
        #expect(fragment.contains("do not jump back to an earlier, unrelated exchange"))
    }

    @Test func anchorTruncatesAnOverlyLongPriorReply() {
        let longReply = String(repeating: "a", count: 500)
        let fragment = CompanionManager.topicAnchorPromptFragment(
            mostRecentExchange: (userPlaceholder: "q", assistantResponse: longReply)
        )!
        #expect(fragment.contains(String(repeating: "a", count: 160)))
        #expect(!fragment.contains(String(repeating: "a", count: 161)))
    }

    // MARK: - Skills prompt block

    private static let emailSkill = SkillFile(
        name: "reply-to-client",
        trigger: "writing an email reply to a client",
        tools: ["gmail.read"],
        instructions: "Match my concise tone."
    )

    @Test func noSkillsProducesNoBlock() {
        #expect(CompanionManager.skillsPromptBlock(skills: []) == nil)
    }

    @Test func skillsBlockEmbedsInstructionsAndTrigger() {
        let block = CompanionManager.skillsPromptBlock(skills: [Self.emailSkill])!
        #expect(block.contains("reply-to-client"))
        #expect(block.contains("writing an email reply to a client"))
        #expect(block.contains("Match my concise tone."))
    }

    // MARK: - Backend request building

    @Test func backendRequestsTargetV1PathsWithConfiguredMethod() throws {
        let get = try #require(BackendClient.makeRequest(endpoint: .usage))
        #expect(get.url!.path.hasSuffix("/v1/usage"))
        #expect(get.httpMethod == "GET")

        let post = try #require(BackendClient.makeRequest(endpoint: .chatStream))
        #expect(post.url!.path.hasSuffix("/v1/chat/stream"))
        #expect(post.httpMethod == "POST")
    }

    @Test func bearerHeaderAttachedOnlyWhenTokenPresent() throws {
        let request = try #require(BackendClient.makeRequest(endpoint: .me))
        // Test bundle has no HeyMateClientToken configured → header absent.
        // (Presence-path is trivial string formatting covered by inspection.)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }
}
