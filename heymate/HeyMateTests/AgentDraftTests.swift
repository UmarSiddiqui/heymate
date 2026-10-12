//
//  AgentDraftTests.swift
//  HeyMateTests
//

import Foundation
import Testing
@testable import HeyMate

struct AgentDraftTests {

    @Test func readsAFencedReplyAndCleansIt() throws {
        let reply = """
        Here you go:
        ```json
        {"name":"Inbox Ivy","role":"Draft replies to customer email","personality":"Warm and brief.",
         "how_it_works":["- Lead with the draft","Lead with the draft","Save drafts in output/","a","b","c","d"],
         "asks_first":["Sending email"],"first_task":"Draft replies to today's customer emails",
         "integrations":["Gmail"]}
        ```
        """
        let draft = try #require(AgentDrafter.parse(reply, existingNames: []))
        #expect(draft.name == "Inbox Ivy")
        #expect(draft.howItWorks.first == "Lead with the draft")
        #expect(draft.howItWorks.count == AgentDrafter.maxHowItWorks)
        #expect(Set(draft.howItWorks).count == draft.howItWorks.count)
        #expect(draft.asksFirst == ["Sending email"])
        #expect(draft.integrations == ["Gmail"])
    }

    @Test func rejectsARepliesWithoutNameOrRole() {
        #expect(AgentDrafter.parse("no json here", existingNames: []) == nil)
        #expect(AgentDrafter.parse(#"{"name":"Ivy"}"#, existingNames: []) == nil)
    }

    @Test func takenNamesGetANumber() throws {
        let draft = try #require(AgentDrafter.parse(#"{"name":"Scout","role":"Find leads"}"#, existingNames: ["scout", "Scout 2"]))
        #expect(draft.name == "Scout 3")
    }

    @Test func localDraftKeepsThePersonsWordsAndSafeHabits() {
        let draft = AgentDrafter.localDraft(description: "watch my inbox for invoices", existingNames: [])
        #expect(draft.role == "Watch my inbox for invoices")
        #expect(!draft.name.isEmpty)
        #expect(!draft.howItWorks.isEmpty)
        #expect(!draft.asksFirst.isEmpty)
    }

    @Test func habitsRoundTripThroughStandingLines() {
        let draft = AgentDraft(
            name: "Ivy", role: "Reply", personality: "", howItWorks: ["Lead with the draft"],
            asksFirst: ["Sending email"], firstTask: "", integrations: []
        )
        let lines = AgentDrafter.standingLines(for: draft)
        #expect(lines == ["Lead with the draft", "Ask me before: Sending email"])
        let split = AgentDrafter.split(standing: lines)
        #expect(split.howItWorks == ["Lead with the draft"])
        #expect(split.asksFirst == ["Sending email"])
    }

    @Test func agentsFileKeepsNotesWhenHabitsChange() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agent-draft-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var mate = Mate(
            id: UUID(), name: "Ivy", job: "Reply to customers", pinned: false, archived: false,
            unreadCount: 0, createdAt: Date(), updatedAt: Date(), memoryNote: "2026-10-12: Prefers short replies"
        )
        mate.folderPath = folder.path
        MateWorkspaceMemory.sync(mate: mate, folder: folder)
        #expect(MateWorkspaceMemory.standingLines(in: folder).isEmpty)
        MateWorkspaceMemory.replaceStanding(["Lead with the draft", "Ask me before: Sending email"], for: mate, in: folder)
        #expect(MateWorkspaceMemory.standingLines(in: folder) == ["Lead with the draft", "Ask me before: Sending email"])
        #expect(MateWorkspaceMemory.notesBody(in: folder)?.contains("Prefers short replies") == true)
    }

    @Test func talkSeesTheHabits() throws {
        let block = try #require(MateSoul.promptBlock(
            name: "Ivy", job: "Reply to customers", soul: "Warm.", standing: ["Lead with the draft"]
        ))
        #expect(block.contains("how you work, on every task"))
        #expect(block.contains("Lead with the draft"))
    }
}
