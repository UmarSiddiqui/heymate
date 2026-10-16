import Foundation
import Testing
@testable import HeyMate

struct ChatTaskPresentationTests {
    @Test func ownershipRequiresBothMateAndChatIdentity() {
        let mateID = UUID()
        var chat = ChatSession.empty()
        chat.mateID = mateID
        var run = AgentRun.queued(id: UUID(), title: "Task", prompt: "Internal context",
                                  workspaceURL: URL(fileURLWithPath: "/tmp/task"), executor: .codex,
                                  origin: .sandbox, chatOwner: AgentChatOwner(mateID: mateID, chatID: chat.id))
        #expect(ChatTaskPresentation.belongs(run, to: chat, defaultMateID: UUID()))
        run.chatOwner = AgentChatOwner(mateID: UUID(), chatID: chat.id)
        #expect(!ChatTaskPresentation.belongs(run, to: chat, defaultMateID: mateID))
        run.chatOwner = AgentChatOwner(mateID: mateID, chatID: UUID())
        #expect(!ChatTaskPresentation.belongs(run, to: chat, defaultMateID: mateID))
    }

    @Test func progressNeverIncludesInternalUserPromptOrAnswer() {
        var run = AgentRun.queued(id: UUID(), title: "Task", prompt: "Internal context",
                                  workspaceURL: URL(fileURLWithPath: "/tmp/task"), executor: .codex, origin: .sandbox)
        run.activity += [AgentActivityEntry(kind: .agent, text: "Answer"),
                         AgentActivityEntry(kind: .progress, text: "Read file")]
        #expect(ChatTaskPresentation.progress(run).map(\.text) == ["Queued", "Read file"])
    }

    @Test func artifactLinksRestrictSchemesAndResolveRelativeFiles() {
        let root = URL(fileURLWithPath: "/tmp/task", isDirectory: true)
        #expect(ChatTaskPresentation.artifactURL("javascript:alert(1)", workspace: root) == nil)
        #expect(ChatTaskPresentation.artifactURL("heymate://open/chat", workspace: root) == nil)
        #expect(ChatTaskPresentation.artifactURL("https://example.com/result", workspace: root)?.host == "example.com")
        #expect(ChatTaskPresentation.artifactURL("report.pdf", workspace: root)?.path == "/tmp/task/report.pdf")
    }

    @Test func oldHistoryDecodesWithoutTaskLinksAndKeepsText() throws {
        let message = ChatMessage(id: UUID(), role: .assistant, text: "Original result", createdAt: Date())
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        #expect(decoded.taskRunID == nil)
        #expect(decoded.taskResultKey == nil)
        #expect(decoded.text == "Original result")
    }
}
