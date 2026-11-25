import Foundation
import Testing
@testable import HeyMate

@MainActor
struct MateInboxWorkTests {
    private func makeInbox() -> (MateInboxStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (MateInboxStore(fileURL: folder.appendingPathComponent("inbox.json")), folder)
    }

    @Test func queuedApprovalKeepsItsPromptAndQueuePositionAcrossRestart() throws {
        let (store, folder) = makeInbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date(), mateID = UUID(), chatID = UUID()
        func proposal(_ title: String) -> MateInboxItem {
            let proposal = MateHeartbeatProposal(id: UUID(), title: title, whyNow: "New report", prompt: "Check \(title).",
                needsApproval: "Ask before changing data.", createdAt: now, expiresAt: now.addingTimeInterval(60))
            return store.record(MateInboxItem(id: proposal.id, mateID: mateID, mateName: "Research", chatID: chatID,
                createdAt: now, resolvedAt: nil, resolutionSummary: nil, kind: .proposal(proposal), resumeTaskContext: nil))
        }
        let first = proposal("Orders")
        let second = proposal("Inventory")
        #expect(store.queueProposal(id: first.id, now: now))
        #expect(!store.queueProposal(id: first.id, now: now))
        #expect(store.queueProposal(id: second.id, now: now.addingTimeInterval(1)))
        #expect(store.pendingCount == 0)

        let url = folder.appendingPathComponent("inbox.json")
        let reopened = MateInboxStore(fileURL: url)
        #expect(reopened.queuedProposals.map(\.id) == [first.id, second.id])
        #expect(reopened.queuedProposals.first?.proposal == first.proposal)
        #expect(reopened.pendingCount == 0)

        _ = reopened.resolve(id: first.id, summary: "Cancelled")
        #expect(MateInboxStore(fileURL: url).queuedProposals.map(\.id) == [second.id])
    }

    @Test func recordedWorkKeepsTheFailedStepAndExactResultWithoutRawToolData() throws {
        let (store, folder) = makeInbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let owner = AgentChatOwner(mateID: UUID(), chatID: UUID())
        let id = UUID()
        store.beginWork(id: id, owner: owner, mateName: "Research", title: "Compare suppliers", background: false, remember: true)
        store.recordWorkEvent(id, type: "agent.opener", payload: .object(["text": .string("Check prices and delivery.")]))
        let fields: [String: JSONValue] = [
            "name": .string("read"), "tool_call_id": .string("read-1"),
            "file_name": .string("/private-fixture/review-input.txt"),
            "arguments": .string("PRIVATE ARGUMENT"), "output": .string("PRIVATE OUTPUT")
        ]
        store.recordWorkEvent(id, type: "tool.start", payload: .object(fields))
        #expect(store.work.first?.currentStep?.displayTitle == "Read a local file · review-input.txt")
        store.recordWorkEvent(id, type: "tool.end", payload: .object([
            "name": .string("read"), "tool_call_id": .string("read-1"),
            "is_error": .bool(true), "failure_code": .string("missing_file")
        ]))
        store.finishWork(id, state: .failed, result: "Pricing sheet could not be opened.", resultKey: "result-1")

        let reopened = MateInboxStore(fileURL: folder.appendingPathComponent("inbox.json"))
        let entry = try #require(reopened.work.first)
        #expect(entry.chatID == owner.chatID)
        #expect(entry.plan == "Check prices and delivery.")
        #expect(entry.state == .failed)
        #expect(entry.steps.count == 1)
        #expect(entry.lastFailedStep?.displayTitle == "Read a local file · review-input.txt")
        #expect(entry.lastFailedStep?.failure == .missingFile)
        #expect(entry.resultKey == "result-1")
        let data = try String(contentsOf: folder.appendingPathComponent("inbox.work.json"), encoding: .utf8)
        #expect(!data.contains("PRIVATE ARGUMENT"))
        #expect(!data.contains("PRIVATE OUTPUT"))
        #expect(!data.contains("private-fixture"))
    }

    @Test func questionsStayAttachedToTheirWorkAndDisabledHistoryStaysInMemory() throws {
        let (store, folder) = makeInbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mate = UUID()
        func blockedWork(remember: Bool) -> MateInboxItem {
            let owner = AgentChatOwner(mateID: mate, chatID: UUID())
            let id = UUID()
            store.beginWork(id: id, owner: owner, mateName: "Research", title: "Compare suppliers", background: true, remember: remember)
            let question = MateInboxItem(id: UUID(), mateID: mate, mateName: "Research", chatID: owner.chatID,
                createdAt: Date(), resolvedAt: nil, resolutionSummary: nil,
                kind: .question(prompt: "Which region?", defaultAnswer: nil, choices: []),
                resumeTaskContext: nil, workID: id)
            store.record(question)
            store.finishWork(id, state: .resultReady, result: "Checked two suppliers.")
            return question
        }
        let saved = blockedWork(remember: true)
        let temporary = blockedWork(remember: false)
        #expect(store.pendingCount == 2)
        #expect(store.work.allSatisfy { $0.state == .needsInput })
        let reopened = MateInboxStore(fileURL: folder.appendingPathComponent("inbox.json"))
        #expect(reopened.pendingItems.map(\.id) == [saved.id])
        #expect(reopened.work.first?.state == .needsInput)
        _ = store.resolve(id: temporary.id, summary: "Answered", resumed: true)
        #expect(store.work.first(where: { $0.id == temporary.workID })?.state == .resumed)
        #expect(store.pendingItems.map(\.id) == [saved.id])
        store.removeItems(forChat: saved.chatID)
        #expect(store.pendingItems.isEmpty)
        #expect(store.work.allSatisfy { $0.chatID != saved.chatID })
    }

    @Test func continuationKeepsTaskIdentityAndFailedStepAfterReopening() throws {
        let (store, folder) = makeInbox()
        defer { try? FileManager.default.removeItem(at: folder) }
        let owner = AgentChatOwner(mateID: UUID(), chatID: UUID())
        let original = UUID(), retry = UUID()
        store.beginWork(id: original, owner: owner, mateName: "Research", title: "Review orders", background: true, remember: true)
        store.recordWorkStep(original, stepID: "first", title: "Write report", state: .finished)
        store.recordWorkStep(original, stepID: "second", title: "Read review input", state: .failed)
        store.finishWork(original, state: .resultReady, result: "Report written. Review input missing.")
        let firstAttempt = try #require(store.work.first)
        #expect(firstAttempt.displayState == .failed)
        #expect(firstAttempt.actions == [.resume, .retry, .followUp])
        let prompt = firstAttempt.checkpointPrompt(instruction: "Read the review input again.")
        #expect(prompt.contains("Write report: Returned"))
        #expect(prompt.contains("Read review input: Failed"))
        #expect(prompt.contains("Report written. Review input missing."))
        store.markResumed(original)
        store.beginWork(id: retry, owner: owner, mateName: "Research", title: firstAttempt.title,
            background: true, remember: true, originalWorkID: firstAttempt.taskID)
        store.finishWork(retry, state: .resultReady, result: "Review completed.")
        let reopened = MateInboxStore(fileURL: folder.appendingPathComponent("inbox.json"))
        let finalAttempt = try #require(reopened.work.first)
        #expect(finalAttempt.id == retry)
        #expect(finalAttempt.taskID == original)
        #expect(finalAttempt.chatID == owner.chatID)
        #expect(finalAttempt.actions == [.followUp])
        #expect(reopened.work.last?.state == .resumed)
        #expect(reopened.work.last?.actions == [])
        let grouped = MateInboxTaskActivity.group(reopened.work)
        #expect(grouped.map(\.id) == [original])
        #expect(grouped.first?.current.id == retry)
        #expect(grouped.first?.earlier.map(\.id) == [original])
    }
}
