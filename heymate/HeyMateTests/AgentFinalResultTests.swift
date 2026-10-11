import Foundation
import Testing
@testable import HeyMate

struct AgentFinalResultTests {
    @Test func privateFinalAnswerStillDrivesLocalPreview() {
        var run = AgentRun.queued(id: UUID(), title: "Fixture", prompt: "Fixture",
                                  workspaceURL: URL(fileURLWithPath: "/tmp/nonexistent-heymate-preview-fixture"), executor: .codex, origin: .sandbox)
        run.summary = AgentFinalResult.availableSummary
        run.privateFinalResult = "Preview the result at http://localhost:4173/demo."
        #expect(AgentWorkspacePreviewTarget.resolve(for: run)?.url.absoluteString == "http://localhost:4173/demo")
    }

    @Test func codexFinalAnswerSurvivesWithoutNewMarker() {
        let lines = [
            #"{"type":"item.completed","item":{"type":"agent_message","text":"I will count the sample workspace."}}"#,
            #"{"type":"item.completed","item":{"type":"command_execution","command":"count-sample","aggregated_output":"PRIVATE RAW TOOL OUTPUT","exit_code":0,"status":"completed"}}"#,
            #"{"type":"item.completed","item":{"type":"agent_message","text":"2 files and 1 folder directly inside the sample workspace."}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}"#
        ]
        var result = AgentFinalResult()
        lines.flatMap(CodexJSONLParser.events(fromStdoutLine:)).forEach { result.consume($0) }
        #expect(result.outcome == .reported("2 files and 1 folder directly inside the sample workspace."))
    }

    @Test func claudeResultOverridesCommentaryAndEmptyResultKeepsFinalAnswer() {
        var result = AgentFinalResult()
        for line in [
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Let me check."}]}}"#,
            #"{"type":"result","is_error":false,"result":"2 files and 1 folder."}"#
        ] {
            ClaudeStreamJSONParser.events(fromStdoutLine: line).forEach { result.consume($0) }
        }
        #expect(result.outcome == .reported("2 files and 1 folder."))
        result.consume(.finished(summary: ""))
        #expect(result.outcome == .reported("2 files and 1 folder."))
    }

    @Test func laterToolsInvalidateEarlierAnswersAndProviderErrorsWin() {
        var result = AgentFinalResult()
        result.consume(.text("HEYMATE_RESULT: A preliminary answer."))
        result.consume(.tool(summary: "Another check"))
        #expect(result.outcome == .missing)
        result.consume(.text("HEYMATE_RESULT: 2 files and 1 folder."))
        ClaudeStreamJSONParser.events(fromStdoutLine: #"{"type":"result","is_error":true,"result":"Synthetic error"}"#)
            .forEach { result.consume($0) }
        #expect(result.outcome == .failed)
        result.consume(.text("HEYMATE_RESULT: A stale success"))
        #expect(result.outcome == .failed)
    }

    @Test(arguments: ["", "Done", "Work completed.", "HEYMATE_RESULT: Done"])
    func genericCompletionIsNotAnAnswer(text: String) {
        var result = AgentFinalResult()
        result.consume(.text(text))
        #expect(result.outcome == .missing)
        let report = MateRunReport.finished(summary: text.replacingOccurrences(of: AgentFinalResult.marker, with: ""), changedFileCount: 0)
        #expect(report == AgentFinalResult.missingMessage)
    }

    @Test func resultAndFailureDeliveryRedactSyntheticSensitiveValues() {
        let token = "ghp_" + String(repeating: "x", count: 30)
        let privateText = "2 files and 1 folder. /Users/fixture/private person@example.test https://example.test/private \(token)"
        var result = AgentFinalResult()
        result.consume(.text("HEYMATE_RESULT: \(privateText)"))
        guard case .reported(let answer) = result.outcome else { Issue.record("Expected final answer"); return }
        for text in [answer, MateRunReport.finished(summary: privateText, changedFileCount: 0)] {
            #expect(text.contains("2 files and 1 folder"))
            #expect(!text.contains("/Users/fixture"))
            #expect(text.contains("person@example.test"))
            #expect(text.contains("https://example.test/private"))
            #expect(!text.contains(token))
        }
        for text in [MateRunReport.failed(message: privateText), MateRunReport.planReady(plan: privateText)] {
            #expect(!text.contains(token))
            #expect(!text.contains("/Users/fixture"))
        }
        let ordinaryLongAnswer = String(repeating: "Useful result. ", count: 300) + "Source: https://example.test/research"
        result.consume(.text("HEYMATE_RESULT: " + ordinaryLongAnswer))
        #expect(result.outcome == .reported(ordinaryLongAnswer))
        result.consume(.text("HEYMATE_RESULT: " + String(repeating: "😀", count: 20_000)))
        guard case .reported(let bounded) = result.outcome else { Issue.record("Expected bounded answer"); return }
        #expect(bounded.utf8.count <= AgentFinalResult.maximumAnswerBytes)
        #expect(bounded.contains("Result truncated at 32 KiB"))
        #expect(!bounded.contains("�"))
    }
}

struct AgentPrivateResultStoreTests {
    @Test func artifactIsBoundedPrivateAndScopedToAttempt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heymate-private-result-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = UUID()
        let attemptID = UUID()
        let url = AgentPrivateResultStore.fileURL(root: root, runID: runID, attemptID: attemptID)
        try DetachedAgentSecureFiles.ensureDirectory(root)
        try DetachedAgentSecureFiles.ensureDirectory(url.deletingLastPathComponent().deletingLastPathComponent())
        try DetachedAgentSecureFiles.ensureDirectory(url.deletingLastPathComponent())
        let source = "Sources/Report.swift https://example.test/research person@example.test\n" + String(repeating: "Finding. ", count: 700) + "End."
        try AgentPrivateResultStore.save(source, root: root, runID: runID, attemptID: attemptID)
        #expect(try AgentPrivateResultStore.load(root: root, runID: runID, attemptID: attemptID) == source)
        #expect(try AgentPrivateResultStore.load(root: root, runID: runID, attemptID: UUID()) == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try AgentPrivateResultStore.save(String(repeating: "😀", count: 20_000), root: root, runID: runID, attemptID: attemptID)
        let data = try Data(contentsOf: url)
        #expect(data.count <= AgentFinalResult.maximumAnswerBytes)
        #expect(String(data: data, encoding: .utf8)?.contains("Result truncated at 32 KiB") == true)

        // A replaced artifact must not turn into an arbitrary local-file read.
        let outside = root.appendingPathComponent("outside.txt")
        try Data("unrelated private content".utf8).write(to: outside)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        #expect(throws: (any Error).self) {
            try AgentPrivateResultStore.load(root: root, runID: runID, attemptID: attemptID)
        }
    }
}

@MainActor
@Suite(.serialized)
struct AgentChatDeliveryTests {
    @Test func launchFailureAlreadyHasOwnerBeforeSynchronousCallback() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let owner = manager.prepareAgentChatOwner(prompt: "Count the sample workspace")
        manager.agentLauncher.readinessForExecutor = { _ in
            HeadlessExecutorReadiness(state: .notSignedIn, detail: "Signed out", remedy: "Sign in to the test executor.")
        }
        manager.agentLauncher.onEvent = { runID, event in
            manager.postMateRunUpdate(runID: runID, event: event)
        }
        let runID = manager.agentLauncher.startAttached(
            prompt: "Count the sample workspace", executor: .codex, workspaceURL: fixture.root,
            screenContext: AgentScreenContext(activeAppName: "Fixture", windowTitle: "Sample"), chatOwner: owner)
        let run = try #require(manager.agentRunStore.run(id: runID))
        #expect(run.chatOwner == owner)
        #expect(run.status == .failed)
        #expect(manager.currentChat.messages.last?.text.contains("Sign in to the test executor") == true)
        #expect(run.chatResultDeliveryKey == run.resultDeliveryKey)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("TASK.md").path))
    }

    @Test(arguments: [false, true])
    func resultStaysInOriginalChatAfterNavigation(otherMate: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let owner = manager.prepareAgentChatOwner(prompt: "Count the sample workspace")
        let run = fixture.addRun(owner: owner)
        if otherMate {
            let mate = try #require(manager.createMate(name: "Other", job: "Other work", opensChat: false))
            manager.openMate(id: mate.id)
        } else { manager.startNewChat() }
        let visible = manager.currentChat
        manager.postMateRunUpdate(runID: run.id, event: .finished(summary: run.summary))
        #expect(manager.currentChat == visible)
        let origin = try #require(manager.chatHistoryStore.loadAll().first { $0.id == owner.chatID })
        #expect(origin.messages.last?.text.contains("2 files and 1 folder") == true)
        #expect(manager.mateDirectory.mates.first { $0.id == owner.mateID }?.unreadCount == 1)
        #expect(!origin.messages.last!.text.contains("schedule"))
    }

    @Test func recoveryDeliversOnceAndFollowUpKeepsItsOwner() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let owner = manager.prepareAgentChatOwner(prompt: "Count the sample workspace")
        var run = fixture.addRun(owner: owner)
        let decoded = try JSONDecoder().decode(AgentRun.self, from: JSONEncoder().encode(run))
        #expect(decoded.chatOwner == owner)
        manager.startNewChat()
        manager.deliverPendingAgentResults()
        manager.deliverPendingAgentResults()
        manager.postMateRunUpdate(runID: run.id, event: .finished(summary: run.summary))
        var origin = try #require(manager.chatHistoryStore.loadAll().first { $0.id == owner.chatID })
        #expect(origin.messages.filter { $0.role == .assistant }.count == 1)
        run = try #require(manager.agentRunStore.run(id: run.id))
        #expect(run.chatResultDeliveryKey == run.resultDeliveryKey)
        run.finishedAt = run.finishedAt?.addingTimeInterval(1)
        run.privateFinalResult = "Follow-up: still 2 files and 1 folder."
        manager.agentRunStore.upsert(run)
        manager.deliverPendingAgentResults()
        origin = try #require(manager.chatHistoryStore.loadAll().first { $0.id == owner.chatID })
        #expect(origin.messages.filter { $0.role == .assistant }.count == 2)
        #expect(manager.currentChat.messages.isEmpty)
    }

    @Test(arguments: ["delete", "clear", "deleteMate", "historyOff"])
    func completionCannotRecreateDeletedOrUnsavedHistory(action: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let mate = try #require(manager.createMate(name: "Counter", job: "Count samples"))
        let owner = manager.prepareAgentChatOwner(prompt: "Count the sample workspace")
        let run = fixture.addRun(owner: owner)
        switch action {
        case "delete": manager.deleteChat(id: owner.chatID)
        case "clear": manager.clearAllChats()
        case "deleteMate": manager.deleteMate(id: mate.id)
        default:
            manager.rememberConversationsEnabled = false
            manager.startNewChat()
        }
        let existing = manager.chatHistoryStore.loadAll()
        let visible = manager.currentChat
        manager.postMateRunUpdate(runID: run.id, event: .finished(summary: run.summary))
        #expect(manager.chatHistoryStore.loadAll() == existing)
        #expect(manager.currentChat == visible)
    }

    @Test func backgroundRoutineBufferAndStorageBothReceiveResult() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let mate = try #require(manager.createMate(name: "Counter", job: "Count samples", opensChat: false))
        var background = ChatSession.empty()
        background.mateID = mate.id
        manager.backgroundRoutineSession = background
        let owner = manager.prepareAgentChatOwner(prompt: "Count the sample workspace")
        let run = fixture.addRun(owner: owner)
        let foreground = manager.currentChat
        manager.postMateRunUpdate(runID: run.id, event: .finished(summary: run.summary))
        #expect(manager.currentChat == foreground)
        #expect(manager.backgroundRoutineSession?.messages.last?.text.contains("2 files and 1 folder") == true)
        #expect(manager.chatHistoryStore.loadAll().first { $0.id == owner.chatID } == manager.backgroundRoutineSession)
    }

    @Test(arguments: [AgentRunStatus.cancelled, .failed, .succeeded])
    func terminalStatesCannotInventSuccess(status: AgentRunStatus) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let owner = manager.prepareAgentChatOwner(prompt: "Count the sample workspace")
        var run = fixture.addRun(owner: owner)
        run.status = status
        run.summary = status == .succeeded ? AgentFinalResult.missingMessage : "Cancelled"
        run.privateFinalResult = nil
        run.error = "Could not count the sample workspace."
        manager.agentRunStore.upsert(run)
        manager.deliverPendingAgentResults()
        let text = try #require(manager.currentChat.messages.last?.text)
        #expect(!text.contains("Job result"))
        #expect(!text.contains("done."))
        switch status {
        case .cancelled: #expect(text.contains("cancelled"))
        case .failed: #expect(text.contains("Could not count"))
        default: #expect(text == AgentFinalResult.missingMessage)
        }
    }

    @Test func legacyRunWithoutOwnerIsNotAssignedToCurrentChat() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let run = fixture.addRun(owner: nil)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        json.removeValue(forKey: "chatOwner")
        json.removeValue(forKey: "chatResultDeliveryKey")
        json.removeValue(forKey: "privateFinalResult")
        json["summary"] = "Legacy: 2 files and 1 folder."
        let decoded = try JSONDecoder().decode(AgentRun.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.chatOwner == nil)
        #expect(decoded.finalAnswer == "Legacy: 2 files and 1 folder.")
        fixture.manager.deliverPendingAgentResults()
        #expect(fixture.manager.currentChat.messages.isEmpty)
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let manager: CompanionManager
        private let preferences: [String: Any]
        private let keys = ["selectedAgentBrain", "defaultHeadlessExecutor", "chatConnectorExclusions", "rememberConversations",
                            "selectedVoiceSpeakProvider", "selectedVoiceListenProvider"]

        init() throws {
            preferences = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
                UserDefaults.standard.object(forKey: key).map { (key, $0) }
            })
            // These routing/storage tests must not warm installed ML speech models.
            UserDefaults.standard.set(VoiceSpeakProvider.macOS.rawValue, forKey: "selectedVoiceSpeakProvider")
            UserDefaults.standard.set(VoiceListenProvider.apple.rawValue, forKey: "selectedVoiceListenProvider")
            root = FileManager.default.temporaryDirectory.appendingPathComponent("heymate-job-delivery-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            manager = CompanionManager(
                memoryRepository: FileMemoryRepository(fileURL: root.appendingPathComponent("memory.json")),
                chatHistoryStore: FileChatHistoryStore(fileURL: root.appendingPathComponent("chats.json")),
                agentRunStore: FileAgentRunStore(fileURL: root.appendingPathComponent("runs.json")),
                standingOrderRepository: FileStandingOrderRepository(directoryURL: root.appendingPathComponent("orders")),
                agentUndoLedger: FileAgentUndoLedger(rootDirectoryURL: root.appendingPathComponent("undo"), recoverPreparedEntriesOnInit: false),
                mateStore: FileMateStore(fileURL: root.appendingPathComponent("mates.json")),
                routineStore: FileMateRoutineStore(fileURL: root.appendingPathComponent("routines.json")))
            manager.rememberConversationsEnabled = true
        }

        func addRun(owner: AgentChatOwner?) -> AgentRun {
            var run = AgentRun.queued(id: UUID(), title: "Sample count", prompt: "Count sample children",
                                      workspaceURL: root, executor: .codex, origin: .attached, chatOwner: owner)
            run.status = .succeeded
            run.finishedAt = Date()
            run.summary = AgentFinalResult.availableSummary
            run.privateFinalResult = "2 files and 1 folder."
            manager.agentRunStore.upsert(run)
            manager.agentRuns = manager.agentRunStore.loadAll()
            return run
        }

        func cleanUp() {
            manager.cancelInFlightChatTurn()
            for key in keys {
                if let value = preferences[key] { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
