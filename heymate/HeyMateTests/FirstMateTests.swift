//
//  FirstMateTests.swift
//  HeyMateTests
//
//  First Mate sees the other mates, free OpenCode models say when they
//  train, and meeting notes keep words rather than audio.
//

import Foundation
import Testing
@testable import HeyMate

struct FirstMateTests {

    @Test func oldAgentOwnerDecodesWithoutReturnAddress() throws {
        let mateID = UUID(), chatID = UUID()
        let data = Data("{\"mateID\":\"\(mateID)\",\"chatID\":\"\(chatID)\"}".utf8)
        let owner = try JSONDecoder().decode(AgentChatOwner.self, from: data)
        #expect(owner.mateID == mateID)
        #expect(owner.requester == nil)
        var delegated = owner
        delegated.requestingMateID = UUID()
        delegated.requestingChatID = UUID()
        #expect(try JSONDecoder().decode(AgentChatOwner.self, from: JSONEncoder().encode(delegated)) == delegated)
    }

    @Test func handoffContextKeepsRecentWordsAndDropsOldScreenReferences() {
        var session = ChatSession.empty()
        session.messages = (0..<10).map { index in
            ChatMessage(id: UUID(), role: .user, text: "Constraint \(index)", createdAt: Date())
        }
        session.messages.append(ChatMessage(id: UUID(), role: .assistant, text: "Screenshot /tmp/heymate-talk-private.jpg\nKeep replies concise", createdAt: Date()))
        let context = MateHandoffContext.request("Draft reply, do not send", session: session)
        #expect(context.contains("Constraint 9"))
        #expect(!context.contains("Constraint 0"))
        #expect(!context.contains("private.jpg"))
        #expect(context.contains("Keep replies concise"))
        #expect(context.contains("Draft reply, do not send"))
    }

    @Test func handoffContextBoundsOversizedInputsAndReportDoesNotClaimVerification() {
        var session = ChatSession.empty()
        session.messages = [ChatMessage(id: UUID(), role: .user, text: String(repeating: "x", count: 50_000), createdAt: Date())]
        let context = MateHandoffContext.request(String(repeating: "y", count: 50_000), session: session)
        #expect(context.count < 20_200)
        let handoff = MateHandoff(mateID: UUID(), mateName: "Scout", instruction: "Find evidence", requestContext: context)
        #expect(handoff.deliveredInstruction.contains("not new authorization"))
        #expect(handoff.returningReport("", succeeded: true).contains("No result was returned"))
        #expect(!handoff.returningReport("Result", succeeded: true).contains("completed"))
    }

    private func mate(name: String, conducts: Bool = false) -> Mate {
        let now = Date()
        return Mate(
            id: UUID(),
            name: name,
            job: "Does \(name)",
            pinned: false,
            archived: false,
            unreadCount: 0,
            createdAt: now,
            updatedAt: now,
            memoryNote: "",
            folderPath: nil,
            conductsOthers: conducts
        )
    }

    @Test func handoffMarkupIsRemovedAndRouted() {
        let nova = mate(name: "Nova")
        let result = MateHandoffParser.extract(
            from: "I'll ask her.\n[ASK:Nova: check the inbox]",
            mates: [mate(name: "First Mate", conducts: true), nova]
        )
        #expect(result.handoffs.count == 1)
        #expect(result.handoffs[0].mateID == nova.id)
        #expect(result.handoffs[0].instruction == "check the inbox")
        #expect(!result.spokenText.contains("[ASK:"))
        #expect(result.spokenText.contains("I'll ask her."))
    }

    @Test func unknownMateStaysVisible() {
        let result = MateHandoffParser.extract(
            from: "[ASK:Nobody: do the thing]",
            mates: [mate(name: "Nova")]
        )
        #expect(result.handoffs.isEmpty)
        #expect(result.spokenText.contains("Nobody"))
    }

    @Test func specialistCanMessageAnotherMateAndFirstMate() {
        let first = mate(name: "First Mate", conducts: true)
        let nova = mate(name: "Nova")
        let scout = mate(name: "Scout")
        let mates = [first, nova, scout]
        let toScout = MateHandoffParser.extract(from: "[ASK:Scout: pull the file]", mates: mates, sender: nova)
        #expect(toScout.handoffs.count == 1)
        #expect(toScout.handoffs[0].mateID == scout.id)
        #expect(toScout.handoffs[0].deliveredInstruction == "Nova asks: pull the file")
        let toFirst = MateHandoffParser.extract(from: "[ASK:First Mate: done]", mates: mates, sender: nova)
        #expect(toFirst.handoffs.first?.mateID == first.id)
    }

    @Test func mateCannotMessageItself() {
        let nova = mate(name: "Nova")
        let result = MateHandoffParser.extract(from: "[ASK:Nova: hi]", mates: [nova], sender: nova)
        #expect(result.handoffs.isEmpty)
    }

    @Test func firstMateHandoffFromUserStaysUnattributed() {
        let first = mate(name: "First Mate", conducts: true)
        let nova = mate(name: "Nova")
        let result = MateHandoffParser.extract(from: "[ASK:Nova: check]", mates: [first, nova], sender: first)
        #expect(result.handoffs[0].deliveredInstruction == "check")
    }

    @Test func pingPongStopsAtHopLimit() {
        let nova = mate(name: "Nova")
        let scout = mate(name: "Scout")
        let result = MateHandoffParser.extract(
            from: "[ASK:Nova: again]",
            mates: [nova, scout],
            sender: scout,
            senderHops: MateMessagingBrief.maxHops
        )
        #expect(result.handoffs.isEmpty)
        #expect(result.spokenText.contains("Nova"))
    }

    @Test func specialistPromptListsTeammates() {
        let nova = mate(name: "Nova")
        let scout = mate(name: "Scout")
        let block = MateMessagingBrief.promptBlock(sender: nova, mates: [nova, scout])
        #expect(block?.contains("send_to_mate") == true)
        #expect(block?.contains("[ASK:") == false)
        #expect(block?.contains("Scout") == true)
        #expect(block?.contains("- Nova") == false)
        #expect(MateMessagingBrief.promptBlock(sender: nova, mates: [nova]) == nil)
    }

    @Test func conductorPromptNamesTheOthers() {
        let first = mate(name: "First Mate", conducts: true)
        let block = FirstMateBrief.promptBlock(
            mate: first,
            others: [first, mate(name: "Nova")],
            memoryExcerpts: [],
            meetingNotesAreOn: false
        )
        #expect(block.contains("Nova"))
        #expect(block.contains("send_to_mate"))
        #expect(block.contains("get_mate_status"))
        #expect(block.contains("answer_request"))
        #expect(!block.contains("[ASK:"))
        #expect(!block.contains("- Nova —") == false || block.contains("Nova"))
    }

    @Test func firstMateKeepsItsOwnNoteWithoutReadingSpecialistNotes() {
        var first = mate(name: "First Mate", conducts: true)
        first.memoryNote = "Give me a short morning briefing."
        var specialist = mate(name: "Nova")
        specialist.memoryNote = "Private note for Nova."
        let block = FirstMateBrief.promptBlock(
            mate: first, others: [first, specialist], memoryExcerpts: [], meetingNotesAreOn: false
        )
        #expect(block.contains(first.memoryNote))
        #expect(!block.contains(specialist.memoryNote))
        #expect(block.contains("Nova — Does Nova"))
    }

    @Test func memoryIndexReadsMarkdownOnly() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryIndex-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent(".claude")
        try? FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let note = claude.appendingPathComponent("CLAUDE.md")
        try? "Prefer short answers.".write(to: note, atomically: true, encoding: .utf8)
        let excerpts = SubscriptionMemoryIndex.excerpts(root: root)
        #expect(excerpts.count == 1)
        #expect(excerpts[0].sourceName == "Claude")
        #expect(excerpts[0].text.contains("short answers"))
    }
}

struct OpenCodeTrainingPolicyTests {

    @Test func bigPickleWarns() {
        let use = OpenCodeTrainingPolicy.dataUse(
            providerID: "opencode",
            modelID: "big-pickle",
            modelName: "Big Pickle"
        )
        guard case .mayTrain(let detail) = use else {
            Issue.record("expected a training warning")
            return
        }
        #expect(detail.contains("improve the model"))
    }

    @Test func spaceBunnyDoesNotWarn() {
        let use = OpenCodeTrainingPolicy.dataUse(
            providerID: "opencode",
            modelID: "space-bunny-free",
            modelName: "Space Bunny Free"
        )
        #expect(use == .notFlagged)
    }

    @Test func paidModelDoesNotWarn() {
        let use = OpenCodeTrainingPolicy.dataUse(
            providerID: "anthropic",
            modelID: "claude-sonnet-4-6",
            modelName: "Claude Sonnet"
        )
        #expect(use == .notFlagged)
    }

    @Test func acknowledgementIsPerModel() {
        let defaults = UserDefaults(suiteName: "OpenCodeTrainingPolicyTests-\(UUID().uuidString)")!
        let key = OpenCodeTrainingPolicy.modelKey(providerID: "opencode", modelID: "big-pickle")
        #expect(OpenCodeTrainingConsent.isAcknowledged(key, defaults: defaults) == false)
        OpenCodeTrainingConsent.acknowledge(key, defaults: defaults)
        #expect(OpenCodeTrainingConsent.isAcknowledged(key, defaults: defaults))
    }
}

@MainActor
struct MeetingCommandTests {

    @Test func startAndStopKeepWords() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingNotes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = MeetingNotes(fileURL: directory.appendingPathComponent("meetings.json"))
        #expect(MeetingCommand.parse("record this meeting") == .start)
        #expect(MeetingCommand.parse("stop meeting notes") == .stop)
        notes.start(title: "Standup")
        notes.append(speaker: "You", text: "Ship the notch.")
        let stopped = notes.stop()
        #expect(stopped?.lines.count == 1)
        #expect(stopped?.lines.first?.contains("Ship the notch.") == true)
        #expect(notes.isRecording == false)
    }

    @Test func imagePlaygroundPhraseIsExplicit() {
        #expect(ImagePlaygroundRequest.concept(in: "image playground a crescent over the dock") == "a crescent over the dock")
        #expect(ImagePlaygroundRequest.concept(in: "draw a circle") == nil)
    }
}

struct MateWorkParserTests {
    @Test func extractsTaskAndStripsMarkup() {
        let result = MateWorkParser.extract(from: "Starting now. [WORK: write three blog pages in /website]")
        #expect(result.tasks == ["write three blog pages in /website"])
        #expect(result.spokenText == "Starting now.")
    }

    @Test func plainReplyHasNoTasks() {
        let result = MateWorkParser.extract(from: "hello there")
        #expect(result.tasks.isEmpty)
        #expect(result.spokenText == "hello there")
    }

    @Test func markupOnlyReplyGetsAConfirmation() {
        let result = MateWorkParser.extract(from: "[WORK: fix the sitemap]")
        #expect(result.tasks == ["fix the sitemap"])
        #expect(!result.spokenText.isEmpty)
    }
}

struct MateRunReportTests {
    @Test func planReadySaysNothingChanged() {
        let text = MateRunReport.planReady(plan: "Add three pages.")
        #expect(text.contains("Nothing has changed"))
        #expect(text.contains("Add three pages."))
    }

    @Test func finishedAnswersBeforeSupplementaryFileCounts() {
        let text = MateRunReport.finished(summary: "Blogs added.", changedFileCount: 1)
        #expect(text.contains("1 file changed"))
        #expect(text.hasPrefix("Result\n\nBlogs added."))
        #expect(!text.contains("schedule"))
    }

    @Test func finishedUsesSummaryAndCountsArtifacts() {
        let summary = """
        The long write-up stays out of the lead.
        <SUMMARY>Blogs added.</SUMMARY>
        <ARTIFACTS>
        output/a.md
        tmp/notes.txt
        https://example.test/post
        </ARTIFACTS>
        """
        let text = MateRunReport.finished(summary: summary, changedFileCount: 2)
        #expect(text.hasPrefix("Result\n\nBlogs added."))
        #expect(text.contains("2 artifacts."))
        #expect(text.contains("2 files changed"))
        #expect(!text.contains("The long write-up"))
        #expect(!text.contains("tmp/notes"))
        #expect(!text.contains("<SUMMARY>"))
    }

    @Test func finishedIgnoresAGenericSummaryWhenTheAnswerIsReal() {
        let text = MateRunReport.finished(
            summary: "Blogs added.\n<SUMMARY>Done</SUMMARY>",
            changedFileCount: 0
        )
        #expect(text == "Result\n\nBlogs added.")
    }

    @Test func failureExplainsAndOffersRetry() {
        #expect(MateRunReport.failed(message: "boom").contains("boom"))
    }

    @Test func cancellationAndTerminalHandoffDoNotClaimCompletion() {
        #expect(MateRunReport.cancelled(summary: "Cancelled").contains("cancelled"))
        #expect(MateRunReport.cancelled(summary: "Handed off to Terminal — you are driving this session now").contains("handed off to Terminal"))
    }
}

struct MateAgentBriefTests {
    @Test func teachingStaysInChatForSpecialistsAndFirstMate() {
        for conductsOthers in [false, true] {
            let mate = Mate(
                id: UUID(), name: "Photo Coach", job: "Teach photo editing", pinned: false, archived: false,
                unreadCount: 0, createdAt: Date(), updatedAt: Date(), memoryNote: "", folderPath: nil,
                conductsOthers: conductsOthers
            )
            for runsCanOperateApps in [false, true] {
                let prompt = MateAgentBrief.promptBlock(mate: mate, runsCanOperateApps: runsCanOperateApps)
                #expect(prompt.contains("teach directly in this chat"))
                #expect(prompt.contains("[PLAN: ...] and [STEP:n]"))
                #expect(prompt.contains("guide only the current step, then wait for their progress"))
                #expect(!prompt.contains("do not write a plan, a list of steps"))
                #expect(!prompt.contains("or take several steps is an agent run"))
                #expect(prompt.contains("before it changes anything"))
                #expect(prompt.contains("[WORK: the complete task"))
            }
        }
    }

    @Test func briefTellsAMateToStartRunsInsteadOfAsking() {
        var mate = Mate(
            id: UUID(), name: "Web Smith", job: "website", pinned: false, archived: false,
            unreadCount: 0, createdAt: Date(), updatedAt: Date(), memoryNote: "",
            folderPath: "/tmp/site"
        )
        mate.soul = ""
        let block = MateAgentBrief.promptBlock(mate: mate)
        #expect(block.contains("[WORK:"))
        #expect(block.contains("/tmp/site"))
        #expect(block.contains("do not ask for a path"))
        #expect(block.contains("ask once"))
        #expect(!block.contains("operate other mac apps"))
    }

    @Test func briefSendsAppTasksToARunWhenRunsCanOperateApps() {
        let mate = Mate(
            id: UUID(), name: "Web Smith", job: "website", pinned: false, archived: false,
            unreadCount: 0, createdAt: Date(), updatedAt: Date(), memoryNote: "",
            folderPath: "/tmp/site"
        )
        let block = MateAgentBrief.promptBlock(mate: mate, runsCanOperateApps: true)
        #expect(block.contains("operate other mac apps"))
        #expect(block.contains("never say app control is unavailable"))
    }

    @Test func briefAsksOnceAndNamesTheResultBlocks() {
        let mate = Mate(
            id: UUID(), name: "Web Smith", job: "website", pinned: false, archived: false,
            unreadCount: 0, createdAt: Date(), updatedAt: Date(), memoryNote: "",
            folderPath: "/tmp/site", conductsOthers: true
        )
        let block = MateAgentBrief.promptBlock(mate: mate, runsCanOperateApps: true)
        #expect(block.contains("this chat cannot write files"))
        #expect(block.contains("ask once"))
        #expect(block.contains("never invent the user's facts"))
        #expect(block.contains("confirm only before"))
        #expect(block.contains("email is a draft"))
        #expect(block.contains("output/"))
        #expect(block.contains("tmp/"))
        #expect(block.contains("<SUMMARY>"))
        #expect(block.contains("<NEXT_ACTIONS>"))
        #expect(block.contains("<ARTIFACTS>"))
        #expect(block.contains("<ROUTINE>"))
        #expect(block.contains("<COMPUTER_USE_REQUEST>"))
        #expect(block.contains("send_to_mate"))
        #expect(AgentPlanBrief.planningContract.contains("do not attempt the work"))
        #expect(AgentPlanBrief.planningContract.contains("Never invent the user's facts"))
        #expect(AgentPlanBrief.replanContract.contains(AgentPlanBrief.planningContract))
        #expect(AgentPlanBrief.followUpContract.contains(AgentPlanBrief.planningContract))
        #expect(AgentPlanBrief.contract(for: .execute) == nil)
        #expect(headlessAgentExecuteInstruction.contains(AgentFinalResult.marker))
        #expect(headlessAgentExecuteInstruction.contains(headlessAgentBlockedMarker))
        for tag in ["<SUMMARY>", "<NEXT_ACTIONS>", "<ARTIFACTS>", "<DONE_TITLE>", "<ROUTINE>", "<COMPUTER_USE_REQUEST>"] {
            #expect(headlessAgentExecuteInstruction.contains(tag))
        }
        let contracts = [
            AgentPlanBrief.planningContract,
            AgentPlanBrief.replanContract,
            AgentPlanBrief.followUpContract
        ].joined(separator: "\n")
        let combined = block.utf8.count + contracts.utf8.count
        #expect(combined < 5 * 1_024)
    }
}

/// Pi turns reach delegation only through the scoped bridge. These names
/// must stay real local tools, and a mate must not spawn native runs for
/// itself from a Pi turn.
struct PiDelegationToolTests {
    @Test func delegationToolsAreRealLocalToolsWithoutStartMateWork() {
        let local = Set(TalkToolCatalog.localTools.map(\.toolDefinition.name))
        #expect(TalkToolCatalog.piDelegationToolNames == ["send_to_mate", "get_mate_status", "answer_request", "create_mate"])
        #expect(TalkToolCatalog.piDelegationToolNames.isSubset(of: local))
        #expect(!TalkToolCatalog.piDelegationToolNames.contains(TalkToolCatalog.startMateWorkToolName))
    }

    @Test func piInstructionsNameTheToolsAndForbidTextDirectives() {
        let prompt = MateAgentConversationClient.interfaceInstructions(mateIdentity: "")
        #expect(prompt.contains("send_to_mate"))
        #expect(prompt.contains("get_mate_status"))
        #expect(prompt.contains("answer_request"))
        #expect(prompt.contains("create_mate"))
        #expect(prompt.contains("tool calls as text"))
    }
}
