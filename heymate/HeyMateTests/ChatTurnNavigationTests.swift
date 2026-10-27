import Foundation
import Testing
@testable import HeyMate

@MainActor
@Suite(.serialized)
struct ChatTurnNavigationTests {
    @Test func nativeSubscriptionToolScopeRejectsOtherChatsAndExpiresOnNavigation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let owner = AgentChatOwner(mateID: manager.currentChat.mateID ?? manager.mateDirectory.defaultMateID,
                                   chatID: manager.currentChat.id)
        var job = AgentRun.queued(id: UUID(), title: "Owned page", prompt: "Page", workspaceURL: fixture.root,
                                  executor: .codex, origin: .sandbox, sessionIdentifier: "persisted", chatOwner: owner)
        job.status = .succeeded
        job.privateFinalResult = "Only this chat may read the research."
        var other = job
        other = AgentRun.queued(id: UUID(), title: "Private other chat", prompt: "Secret", workspaceURL: fixture.root,
                                executor: .claudeCode, origin: .sandbox,
                                chatOwner: AgentChatOwner(mateID: owner.mateID, chatID: UUID()))
        other.privateFinalResult = "Private unrelated findings."
        manager.agentRunStore.upsert(job)
        manager.agentRunStore.upsert(other)
        manager.agentRuns = manager.agentRunStore.loadAll()
        manager.sendTranscriptToClaudeWithScreenshot(transcript: "Recall my findings", shouldCaptureScreen: false)
        let task = try #require(manager.currentResponseTask)
        try await fixture.client.waitForRequest()
        let completion = try #require(manager.currentResponseCompletion)
        let token = manager.registerTalkToolScope(owner: owner, completion: completion)
        let names = manager.scopedTalkToolDescriptions(token: token).compactMap { $0["name"] as? String }
        #expect(names.contains("inspect_work"))
        #expect(names.contains("continue_work"))
        let result = manager.executeScopedTalkTool(token: token, name: "inspect_work", arguments: [:])
        #expect(result.text.contains("Only this chat"))
        #expect(!result.text.contains("Private unrelated"))
        #expect(manager.scopedTalkToolDescriptions(token: UUID().uuidString).isEmpty)
        manager.startNewChat()
        #expect(manager.scopedTalkToolDescriptions(token: token).isEmpty)
        #expect(manager.executeScopedTalkTool(token: token, name: "open_artifact", arguments: [:]).isError)
        manager.revokeTalkToolScope(token)
        fixture.client.finish(text: "Late answer")
        await task.value
    }

    @Test(arguments: ["new", "open", "mate", "delete", "clear", "clearMate"],
          ["approval", "running", "listening", "finalizing"])
    func navigationPreservesUnrelatedStateAfterACompletedReply(action: String, interaction: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let other = fixture.addMate(name: "Pixel", brain: .onDevice)
        let otherChat = fixture.addChat(mateID: other.id)

        // Production keeps the completed task referenced. Navigation must
        // not mistake that old handle for ownership of the new interaction.
        manager.sendTranscriptToClaudeWithScreenshot(transcript: "Earlier question", shouldCaptureScreen: false)
        let oldTask = try #require(manager.currentResponseTask)
        try await fixture.client.waitForRequest()
        fixture.client.finish(text: "")
        await oldTask.value
        #expect(manager.currentResponseTask != nil)
        #expect(!manager.isResponseInFlight)

        let runID = UUID()
        switch interaction {
        case "approval":
            manager.dispatch(.agentStarted(runID))
            manager.dispatch(.approvalRequested(runID))
        case "running": manager.dispatch(.agentStarted(runID))
        case "listening": manager.dispatch(.startListening(.talk))
        default:
            manager.dispatch(.startListening(.talk))
            manager.dispatch(.finishListening)
        }
        manager.isSubscriptionVoiceChatActive = true
        let expectedState = manager.state
        let expectedBusyReason = manager.typedMessageBusyReason
        let expectedForegroundAgent = manager.isForegroundAgentActive
        switch action {
        case "new": manager.startNewChat()
        case "open": manager.openChat(id: otherChat.id)
        case "mate": manager.openMate(id: other.id)
        case "delete": manager.deleteChat(id: manager.currentChat.id)
        case "clear": manager.clearAllChats()
        default: manager.clearChats(forMateID: try #require(manager.currentChat.mateID))
        }
        await Task.yield()
        #expect(manager.state == expectedState)
        #expect(manager.typedMessageBusyReason == expectedBusyReason)
        #expect(manager.isForegroundAgentActive == expectedForegroundAgent)
        #expect(manager.isSubscriptionVoiceChatActive)
    }

    @Test func navigationDuringNewVoiceInputInvalidatesOldReplyWithoutIdlingInput() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.sendTranscriptToClaudeWithScreenshot(transcript: "Earlier question", shouldCaptureScreen: false)
        let oldTask = try #require(manager.currentResponseTask)
        try await fixture.client.waitForRequest()
        // The Talk shortcut cancels the previous task before starting the
        // microphone. This provider deliberately has not finished unwinding.
        oldTask.cancel()
        manager.dispatch(.startListening(.talk))
        manager.isSubscriptionVoiceChatActive = true
        manager.startNewChat()
        try await fixture.client.emitChunk("Stale reply")
        fixture.client.finish(text: "Stale answer")
        await oldTask.value
        #expect(manager.currentResponseTask == nil)
        #expect(manager.currentChat.messages.isEmpty)
        #expect(manager.streamingAssistantText.isEmpty)
        #expect(manager.state == .listening(.talk))
        #expect(manager.isSubscriptionVoiceChatActive)
    }

    @Test func navigationClearsLingeringGuidanceWithoutResettingAgentApproval() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let runID = UUID()
        manager.dispatch(.agentStarted(runID))
        manager.dispatch(.approvalRequested(runID))
        manager.cursorCaptionText = "Earlier lesson step"
        manager.isGuidancePointerHeld = true
        manager.startNewChat()
        #expect(manager.cursorCaptionText.isEmpty)
        #expect(!manager.isGuidancePointerHeld)
        #expect(manager.state == .waitingForApproval(runID))
        #expect(manager.isForegroundAgentActive)
    }

    @Test func navigationBeforeTaskStartsCannotAppendOldQuestion() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.sendTranscriptToClaudeWithScreenshot(transcript: "Old question", shouldCaptureScreen: false)
        let oldTask = try #require(manager.currentResponseTask)
        manager.isGuidancePointerHeld = true
        manager.cursorCaptionText = "Old step"
        manager.startNewChat()
        await oldTask.value
        #expect(manager.currentChat.messages.isEmpty)
        #expect(fixture.client.requests.isEmpty)
        #expect(manager.state == .idle)
        #expect(!manager.isGuidancePointerHeld)
        #expect(manager.cursorCaptionText.isEmpty)
    }

    @Test(arguments: ["new", "open", "mate", "delete", "clear", "clearMate"])
    func navigationRejectsLateChunksToolsAndErrors(action: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let other = fixture.addMate(name: "Pixel", brain: .onDevice)
        let otherChat = fixture.addChat(mateID: other.id)
        manager.sendTranscriptToClaudeWithScreenshot(transcript: "First question", shouldCaptureScreen: false)
        let task = try #require(manager.currentResponseTask)
        try await fixture.client.waitForRequest()
        switch action {
        case "new": manager.startNewChat()
        case "open": manager.openChat(id: otherChat.id)
        case "mate": manager.openMate(id: other.id)
        case "delete": manager.deleteChat(id: manager.currentChat.id)
        case "clear": manager.clearAllChats()
        default: manager.clearChats(forMateID: try #require(manager.currentChat.mateID))
        }
        let expectedChat = manager.currentChat
        try await fixture.client.emitChunk("Late answer from previous mate")
        let toolResult = try await fixture.client.requestTool(AssistantToolCall(
            toolUseIdentifier: "late-tool",
            toolName: "unavailable-test-tool",
            inputArgumentsJSON: "{}"
        ))
        #expect(toolResult.isError == true)
        fixture.client.finish(throwing: NSError(domain: "NavigationTest", code: 401))
        await task.value
        #expect(manager.currentChat == expectedChat)
        #expect(manager.streamingAssistantText.isEmpty)
        #expect(manager.state == .idle)
    }

    @Test func lateSuccessfulReplyCannotCreateWorkOrHandoffs() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.sendTranscriptToClaudeWithScreenshot(transcript: "First question", shouldCaptureScreen: false)
        let task = try #require(manager.currentResponseTask)
        try await fixture.client.waitForRequest()
        manager.startNewChat()
        fixture.client.finish(text: "Old answer [WORK: write a file]")
        await task.value
        #expect(manager.currentChat.messages.isEmpty)
        #expect(manager.agentRuns.isEmpty)
        #expect(manager.pendingHandoffs.isEmpty)
    }

    @Test func navigationDismissesTheCancelledTurnsApproval() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let request = ConnectorToolApprovalRequest(
            connectorDisplayName: "Test connector", toolName: "test_action",
            argumentsSummary: "No action will run", risk: .externalSideEffect
        )
        fixture.client.approvalRequest = (manager.connectorToolCoordinator, request)
        manager.sendTranscriptToClaudeWithScreenshot(transcript: "Test approval", shouldCaptureScreen: false)
        let task = try #require(manager.currentResponseTask)
        for _ in 0..<100 {
            if manager.connectorToolCoordinator.pendingRequest != nil { break }
            await Task.yield()
        }
        #expect(manager.connectorToolCoordinator.pendingRequest?.id == request.id)
        manager.startNewChat()
        await task.value
        #expect(fixture.client.approvalDecision == false)
        #expect(manager.connectorToolCoordinator.pendingRequest == nil)
    }

    @Test func cancellingAnOlderApprovalDoesNotDismissItsReplacement() async throws {
        let coordinator = ConnectorToolCoordinator()
        let first = ConnectorToolApprovalRequest(
            connectorDisplayName: "First", toolName: "first", argumentsSummary: "None", risk: .externalSideEffect
        )
        let second = ConnectorToolApprovalRequest(
            connectorDisplayName: "Second", toolName: "second", argumentsSummary: "None", risk: .externalSideEffect
        )
        let firstTask = Task { await coordinator.requestApproval(for: first) }
        for _ in 0..<100 {
            if coordinator.pendingRequest?.id == first.id { break }
            await Task.yield()
        }
        let secondTask = Task { await coordinator.requestApproval(for: second) }
        for _ in 0..<100 {
            if coordinator.pendingRequest?.id == second.id { break }
            await Task.yield()
        }
        firstTask.cancel()
        #expect(await firstTask.value == false)
        await Task.yield()
        #expect(coordinator.pendingRequest?.id == second.id)
        coordinator.approvePendingRequest()
        #expect(await secondTask.value == true)
    }

    @Test func builderDraftsWithTheAIThenCreatesTheAgent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let drafting = Task { await manager.draftAgent(description: "reply to customer email") }
        try await fixture.client.waitForRequest()
        #expect(fixture.client.requests[0].systemPrompt == AgentDrafter.systemPrompt)
        fixture.client.finish(text: """
        {"name":"Inbox Ivy","role":"Draft replies to customer email","personality":"Warm and brief.",
         "how_it_works":["Lead with the draft"],"asks_first":["Sending email"],
         "first_task":"Draft replies to today's customer emails","integrations":[]}
        """)
        let result = await drafting.value
        #expect(result.usedModel)
        let face = MiloLook.defaultLook(for: .nova).assetName
        let mate = try #require(manager.createAgent(from: result.draft, faceAssetName: face))
        #expect(mate.name == "Inbox Ivy")
        #expect(mate.soul == "Warm and brief.")
        #expect(mate.faceAssetName == face)
        #expect(manager.agentHabits(for: mate).asksFirst == ["Sending email"])
        #expect(manager.currentChat.firstMoment?.starter?.prompt == "Draft replies to today's customer emails")
        #expect(fixture.client.requests.count == 1)
    }

    @Test func openingSavedChatAppliesItsMatesPreferences() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let mate = fixture.addMate(name: "Pixel", brain: .onDevice, exclusions: ["example-connector"])
        let chat = fixture.addChat(mateID: mate.id)
        let globalExclusions = fixture.manager.chatConnectorExclusions
        fixture.manager.openChat(id: chat.id)
        #expect(fixture.manager.activeMateID == mate.id)
        #expect(fixture.manager.selectedBrain == .onDevice)
        // Integrations are global, so an agent's old saved choices are ignored.
        #expect(fixture.manager.chatConnectorExclusions == globalExclusions)
        #expect(!fixture.manager.chatConnectorExclusions.contains("example-connector"))
    }

    @Test func talkAnswersAsHeyMateEvenWithAMateChatOpen() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        var mate = fixture.addMate(name: "Pixel", brain: .onDevice)
        mate.memoryNote = "Use concise design feedback."
        _ = manager.mateDirectory.upsertMate(mate)
        manager.memoryRepository.updateSessionSummary(mateID: mate.id, text: "Pixel project is a blue logo.")
        manager.memoryRepository.updateSessionSummary(
            mateID: MemoryContext.heyMateTalkOwnerID, text: "Talk remembers the red bike."
        )
        manager.memoryItems = manager.memoryRepository.loadAll()
        manager.openMate(id: mate.id)
        let openChatMessages = manager.currentChat.messages

        manager.isHeyMateTalkTurn = true
        manager.sendTranscriptToClaudeWithScreenshot(transcript: "Explain the next step", shouldCaptureScreen: false)
        let task = try #require(manager.currentResponseTask)
        try await fixture.client.waitForRequest()
        let request = try #require(fixture.client.requests.first)
        #expect(request.systemPrompt.contains(CompanionPrompts.heyMateTalkPersona))
        #expect(!request.systemPrompt.contains(mate.memoryNote))
        #expect(!request.systemPrompt.contains(Mate.firstMateSoul))
        #expect(request.userPrompt.contains("Talk remembers the red bike."))
        #expect(!request.userPrompt.contains("Pixel project"))

        fixture.client.finish(text: "Oh, you missed the big button? Cute. Top right.")
        await task.value
        #expect(manager.activeMateID == mate.id)
        #expect(manager.currentChat.messages == openChatMessages)
        #expect(manager.heyMateTalkSession.messages.map(\.role) == [.user, .assistant])
        let talkSummary = manager.memoryItems.first {
            $0.kind == .sessionSummary && $0.mateID == MemoryContext.heyMateTalkOwnerID
        }
        #expect(talkSummary?.text.contains("Top right.") == true)
        let pixelSummary = manager.memoryItems.first { $0.kind == .sessionSummary && $0.mateID == mate.id }
        #expect(pixelSummary?.text == "Pixel project is a blue logo.")
    }

    @Test func speechFailureAfterAShownReplyDoesNotReportTheTurnAsFailed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.voiceSynthesisClient = FailingSpeech()
        manager.isHeyMateTalkTurn = true
        manager.sendTranscriptToClaudeWithScreenshot(transcript: "Explain the next step", shouldCaptureScreen: false)
        let task = try #require(manager.currentResponseTask)
        try await fixture.client.waitForRequest()
        fixture.client.finish(text: "Top right.")
        await task.value
        #expect(manager.heyMateTalkSession.messages.map(\.text) == ["Explain the next step", "Top right."])
        #expect(manager.state == .idle)
    }

    @Test func sayingAMateNameDuringTalkDoesNotSwitchMates() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let mate = fixture.addMate(name: "Pixel", brain: .onDevice)
        let openBefore = manager.activeMateID
        manager.handleTalkTranscript("Pixel, what is on my screen right now?")
        #expect(manager.isHeyMateTalkTurn)
        #expect(manager.activeMateID == openBefore)
        #expect(manager.activeMateID != mate.id)
    }

    @Test func specialistRequestIncludesOwnNoteAndOnlyItsScopedSummary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        var mate = fixture.addMate(name: "Pixel", brain: .onDevice)
        mate.memoryNote = "Use concise design feedback."
        _ = manager.mateDirectory.upsertMate(mate)
        manager.memoryRepository.updateSessionSummary(mateID: mate.id, text: "Own project is a blue logo.")
        manager.memoryRepository.updateSessionSummary(mateID: UUID(), text: "Private unrelated project is a red boat.")
        manager.memoryItems = manager.memoryRepository.loadAll()
        manager.openMate(id: mate.id)
        manager.sendTranscriptToClaudeWithScreenshot(transcript: "Explain the next step", shouldCaptureScreen: false)
        let task = try #require(manager.currentResponseTask)
        try await fixture.client.waitForRequest()
        let request = try #require(fixture.client.requests.first)
        #expect(request.systemPrompt.contains(mate.memoryNote))
        #expect(request.userPrompt.contains("Own project is a blue logo."))
        #expect(!request.userPrompt.contains("Private unrelated project"))
        manager.startNewChat()
        fixture.client.finish(text: "Stale answer")
        await task.value
    }

    @Test(arguments: [false, true])
    func navigationKeepsBackgroundRoutineInItsOriginalChat(beforeTaskStarts: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let worker = fixture.addMate(name: "Scout", brain: .onDevice)
        let workerChat = fixture.addChat(mateID: worker.id)
        let other = fixture.addMate(name: "Pixel", brain: .customAPI)
        manager.backgroundRoutineSession = workerChat
        manager.activeRoutineTurn = ActiveRoutineTurn(
            routineID: UUID(), mateID: worker.id, task: "Routine question", writesIntoOpenChat: false
        )
        manager.sendTranscriptToClaudeWithScreenshot(transcript: "Routine question", shouldCaptureScreen: false)
        let task = try #require(manager.currentResponseTask)
        if beforeTaskStarts { manager.openMate(id: other.id) }
        try await fixture.client.waitForRequest()
        if !beforeTaskStarts { manager.openMate(id: other.id) }
        #expect(task.isCancelled == false)
        try await fixture.client.emitChunk("Background result")
        #expect(manager.streamingAssistantText.isEmpty)
        fixture.client.finish(text: "Background result")
        await task.value
        #expect(manager.currentChat.mateID == other.id)
        #expect(manager.currentChat.messages.isEmpty)
        let saved = try #require(manager.chatHistoryStore.session(id: workerChat.id))
        #expect(saved.messages.last?.text.contains("Background result") == true)
        #expect(fixture.client.requests[0].systemPrompt.contains("Scout"))
        #expect(manager.memoryRepository.loadAll().contains { $0.mateID == worker.id && $0.text.contains("Scout:") })
    }

    @Test(arguments: ["delete", "clearMate", "clearAll"])
    func deletingBackgroundHistoryCannotResurrectIt(action: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let worker = fixture.addMate(name: "Scout", brain: .onDevice)
        let chat = fixture.addChat(mateID: worker.id)
        manager.backgroundRoutineSession = chat
        manager.activeRoutineTurn = ActiveRoutineTurn(
            routineID: UUID(), mateID: worker.id, task: "Routine question", writesIntoOpenChat: false
        )
        manager.sendTranscriptToClaudeWithScreenshot(transcript: "Routine question", shouldCaptureScreen: false)
        let task = try #require(manager.currentResponseTask)
        try await fixture.client.waitForRequest()
        switch action {
        case "delete": manager.deleteChat(id: chat.id)
        case "clearMate": manager.clearChats(forMateID: worker.id)
        default: manager.clearAllChats()
        }
        fixture.client.finish(text: "Late routine answer")
        await task.value
        #expect(task.isCancelled)
        #expect(manager.backgroundRoutineSession == nil)
        #expect(manager.chatHistoryStore.session(id: chat.id) == nil)
        #expect(manager.currentChat.messages.isEmpty)
    }

    @Test(arguments: [false, true])
    func backgroundDeliveryDoesNotPersistChatWhenHistoryIsOff(isHandoff: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.rememberConversationsEnabled = false
        let worker = fixture.addMate(name: "Scout", brain: .onDevice)
        if isHandoff {
            manager.beginHandoff(MateHandoff(mateID: worker.id, mateName: worker.name,
                                             instruction: "Explain account terminology."))
        } else {
            #expect(manager.kickoffRoutine(fixture.addRoutine(mateID: worker.id)) == .started)
        }
        let task = try #require(manager.currentResponseTask)
        try await fixture.client.waitForRequest()
        #expect(manager.backgroundRoutineSession?.messages.isEmpty == false)
        #expect(manager.chatHistoryStore.loadAll().isEmpty)
        fixture.client.finish(text: "Temporary conversation answer.")
        await task.value
        #expect(manager.backgroundRoutineSession == nil)
        #expect(manager.activeRoutineTurn == nil)
        #expect(manager.activeHandoffMateID == nil)
        #expect(manager.chatHistoryStore.loadAll().isEmpty)
        #expect(manager.savedChats.isEmpty)
        #expect(manager.memoryRepository.loadAll().isEmpty)
    }

    @Test func delegatedReportReturnsToOriginalChatWithoutSwitchingVisibleMate() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let requester = manager.currentChat
        let worker = fixture.addMate(name: "Scout", brain: .onDevice)
        let handoff = MateHandoff(mateID: worker.id, mateName: worker.name, instruction: "Explain account terminology.",
                                  requestContext: "Explain account terminology without changing anything.",
                                  requester: AgentChatOwner(mateID: requester.mateID ?? manager.mateDirectory.defaultMateID, chatID: requester.id))
        manager.beginHandoff(handoff)
        let task = try #require(manager.currentResponseTask)
        try await fixture.client.waitForRequest()
        #expect(fixture.client.requests.last?.userPrompt.contains("without changing anything") == true)
        #expect(manager.currentChat.id == requester.id)
        fixture.client.finish(text: "A workspace groups account projects. No changes made.")
        await task.value
        #expect(manager.activeHandoff == nil)
        #expect(manager.currentChat.id == requester.id)
        let report = try #require(manager.currentChat.messages.last)
        #expect(report.text.contains("Scout reported on delegated task"))
        #expect(report.text.contains("No changes made"))
        #expect(manager.chatHistoryStore.loadAll().contains { $0.mateID == worker.id && $0.messages.last?.text.contains("No changes made") == true })
    }

    @Test func failedHandoffReportsFailureAndKeepsUnrelatedPendingWork() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let worker = fixture.addMate(name: "Scout", brain: .onDevice)
        let requester = AgentChatOwner(mateID: manager.currentChat.mateID ?? manager.mateDirectory.defaultMateID, chatID: manager.currentChat.id)
        let handoff = MateHandoff(mateID: worker.id, mateName: worker.name, instruction: "Explain account terminology.", requester: requester)
        manager.activeHandoff = handoff
        manager.activeHandoffMateID = worker.id
        manager.backgroundRoutineSession = ChatSession.empty()
        manager.pendingHandoffs = [handoff]
        manager.completeActiveHandoff(succeeded: false)
        #expect(manager.pendingHandoffs == [handoff])
        #expect(manager.currentChat.messages.last?.text.contains("Scout could not finish") == true)
        #expect(manager.currentChat.messages.last?.text.contains("No result was returned") == true)
        manager.cancelInFlightChatTurn()
        #expect(manager.pendingHandoffs.isEmpty)
    }

    @Test func delegatedRunReturnsTerminalResultOnceToRequesterAndSpecialist() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let requester = manager.currentChat
        let worker = fixture.addMate(name: "Scout", brain: .onDevice)
        let workerChat = fixture.addChat(mateID: worker.id)
        var run = AgentRun.queued(id: UUID(), title: "Check evidence", prompt: "Check evidence", workspaceURL: fixture.root,
                                 executor: .codex, origin: .sandbox, createdAt: Date())
        run.chatOwner = AgentChatOwner(mateID: worker.id, chatID: workerChat.id,
                                      requestingMateID: requester.mateID ?? manager.mateDirectory.defaultMateID, requestingChatID: requester.id)
        run.status = .succeeded
        run.privateFinalResult = "Evidence checked: 3 records. No sends."
        manager.agentRunStore.upsert(run)
        manager.postMateRunUpdate(runID: run.id, event: .finished(summary: "Done"))
        let count = manager.currentChat.messages.count
        #expect(manager.currentChat.messages.last?.text.contains("Evidence checked: 3 records") == true)
        #expect(manager.currentChat.messages.last?.text.contains("review evidence") == true)
        #expect(manager.chatHistoryStore.session(id: workerChat.id)?.messages.last?.text.contains("Evidence checked") == true)
        manager.postMateRunUpdate(runID: run.id, event: .finished(summary: "Done"))
        #expect(manager.currentChat.messages.count == count)
    }

    @Test func removedRequesterChatIsNotResurrectedByHandoffReport() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let worker = fixture.addMate(name: "Scout", brain: .onDevice)
        let removed = fixture.addChat(mateID: manager.mateDirectory.defaultMateID)
        manager.chatHistoryStore.delete(id: removed.id)
        manager.activeHandoff = MateHandoff(mateID: worker.id, mateName: worker.name, instruction: "Check", requester: AgentChatOwner(mateID: manager.mateDirectory.defaultMateID, chatID: removed.id))
        manager.activeHandoffMateID = worker.id
        manager.backgroundRoutineSession = ChatSession.empty()
        manager.completeActiveHandoff(succeeded: true)
        #expect(manager.chatHistoryStore.session(id: removed.id) == nil)
        #expect(manager.currentChat.messages.isEmpty)
    }

    @Test(arguments: [false, true])
    func harnessWorkOwnsSpecialistChatAndReturnsResultsToInitiator(background: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let worker = fixture.addMate(name: "Scout", brain: .codex)
        let workerChat = fixture.addChat(mateID: worker.id)
        let visible = manager.currentChat
        let source = background ? fixture.addChat(mateID: manager.mateDirectory.defaultMateID) : visible
        if background { manager.backgroundRoutineSession = source }
        let owner = manager.prepareMateWorkChatOwner(task: "Check three records", mateID: worker.id, recordUserMessage: true)
        #expect(owner.mateID == worker.id)
        #expect(owner.chatID == workerChat.id)
        #expect(owner.requester?.chatID == source.id)
        #expect(owner.requester?.mateID == source.mateID)
        #expect(manager.currentChat.id == visible.id)
        let initiating = background ? manager.backgroundRoutineSession : manager.currentChat
        #expect(initiating?.messages.filter { $0.text == "Check three records" }.count == 1)
        #expect(manager.chatHistoryStore.session(id: workerChat.id)?.messages.last?.text == "Check three records")

        var run = AgentRun.queued(id: UUID(), title: "Check records", prompt: "Check three records",
                                 workspaceURL: fixture.root, executor: .codex, origin: .sandbox, createdAt: Date())
        run.chatOwner = owner
        run.status = .succeeded
        run.privateFinalResult = "Three records checked. No changes needed."
        manager.agentRunStore.upsert(run)
        manager.postMateRunUpdate(runID: run.id, event: .finished(summary: "Done"))
        #expect(manager.chatHistoryStore.session(id: workerChat.id)?.messages.last?.text.contains("Three records checked") == true)
        let delivered = background ? manager.backgroundRoutineSession : manager.currentChat
        #expect(delivered?.messages.last?.text.contains("Three records checked") == true)
    }

    @Test func harnessToolWorkPreservesActualUserMessageWithoutAppendingGeneratedTask() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let worker = fixture.addMate(name: "Scout", brain: .codex)
        manager.appendUserMessage("Ask Scout to check three records, then report back.")
        let count = manager.currentChat.messages.count
        let owner = manager.prepareMateWorkChatOwner(task: "Check three records", mateID: worker.id, recordUserMessage: false)
        #expect(manager.currentChat.messages.count == count)
        #expect(manager.currentChat.messages.last?.text == "Ask Scout to check three records, then report back.")
        #expect(manager.chatHistoryStore.session(id: owner.chatID)?.mateID == worker.id)
        #expect(owner.requester?.chatID == manager.currentChat.id)
    }

    @Test func harnessWorkKeepsSameMateChatAndDoesNotPersistHiddenHistory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let source = manager.currentChat
        let sameOwner = manager.prepareMateWorkChatOwner(task: "Check locally", mateID: source.mateID, recordUserMessage: true)
        #expect(sameOwner.chatID == source.id)
        #expect(sameOwner.requester == nil)
        let worker = fixture.addMate(name: "Scout", brain: .codex)
        manager.rememberConversationsEnabled = false
        let owner = manager.prepareMateWorkChatOwner(task: "Private task", mateID: worker.id, recordUserMessage: false)
        #expect(owner.mateID == worker.id)
        #expect(owner.requester?.chatID == source.id)
        #expect(manager.chatHistoryStore.session(id: owner.chatID) == nil)
    }

    @Test func harnessFollowUpSelectsNewestOwnedLiveRunBeforeFinishedSessions() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let owner = AgentChatOwner(mateID: manager.mateDirectory.defaultMateID, chatID: manager.currentChat.id)
        func run(at seconds: TimeInterval, status: AgentRunStatus, mateID: UUID? = nil) -> AgentRun {
            var run = AgentRun.queued(id: UUID(), title: "Run", prompt: "Task", workspaceURL: fixture.root,
                                     executor: .codex, origin: .sandbox, createdAt: Date(timeIntervalSince1970: seconds))
            run.chatOwner = mateID.map { AgentChatOwner(mateID: $0, chatID: UUID()) } ?? owner
            run.status = status
            run.sessionIdentifier = "session-\(seconds)"
            return run
        }
        let old = run(at: 1, status: .running)
        let latest = run(at: 3, status: .planning)
        let finished = run(at: 4, status: .succeeded)
        let unrelated = run(at: 5, status: .running, mateID: UUID())
        manager.agentRuns = [old, finished, unrelated, latest]
        #expect(manager.latestContinuableRun(for: owner.mateID)?.id == latest.id)
        manager.agentRuns = [old, latest, finished].map { value in
            var value = value
            value.status = .succeeded
            return value
        }
        #expect(manager.latestContinuableRun(for: owner.mateID)?.id == finished.id)
        manager.agentRuns = [unrelated]
        #expect(manager.latestContinuableRun(for: owner.mateID) == nil)
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let client = SuspendedConversationClient()
        let manager: CompanionManager
        private let preferences: [String: Any]
        private let preferenceKeys = ["selectedAgentBrain", "defaultHeadlessExecutor", "chatConnectorExclusions", "rememberConversations",
                                      "selectedOpenCodeProviderID", "selectedOpenCodeModelID", "openCodeTrainingAcknowledgedModelKeys",
                                      "selectedVoiceSpeakProvider", "selectedVoiceListenProvider"]

        init() throws {
            preferences = Dictionary(uniqueKeysWithValues: preferenceKeys.compactMap { key in
                UserDefaults.standard.object(forKey: key).map { (key, $0) }
            })
            UserDefaults.standard.set(VoiceSpeakProvider.macOS.rawValue, forKey: "selectedVoiceSpeakProvider")
            UserDefaults.standard.set(VoiceListenProvider.apple.rawValue, forKey: "selectedVoiceListenProvider")
            root = FileManager.default.temporaryDirectory.appendingPathComponent("heymate-chat-navigation-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            manager = CompanionManager(
                memoryRepository: FileMemoryRepository(fileURL: root.appendingPathComponent("memory.json")),
                chatHistoryStore: FileChatHistoryStore(fileURL: root.appendingPathComponent("chats.json")),
                agentRunStore: FileAgentRunStore(fileURL: root.appendingPathComponent("runs.json")),
                standingOrderRepository: FileStandingOrderRepository(directoryURL: root.appendingPathComponent("orders")),
                agentUndoLedger: FileAgentUndoLedger(rootDirectoryURL: root.appendingPathComponent("undo"), recoverPreparedEntriesOnInit: false),
                mateStore: FileMateStore(fileURL: root.appendingPathComponent("mates.json")),
                routineStore: FileMateRoutineStore(fileURL: root.appendingPathComponent("routines.json")),
                conversationClient: client
            )
            manager.rememberConversationsEnabled = true
            manager.selectedBrain = .onDevice
            // Routing tests must not read the real user's Mail/Calendar when
            // a synthetic request mentions replies or account terminology.
            manager.setChatConnectorEnabled(false, selectionID: CompanionManager.chatConnectorSelectionID(forConnectorID: "apple-mail"))
            manager.setChatConnectorEnabled(false, selectionID: CompanionManager.chatConnectorSelectionID(forConnectorID: "apple-calendar"))
        }

        func addMate(name: String, brain: AgentBrain, exclusions: [String] = []) -> Mate {
            let mate = Mate(id: UUID(), name: name, job: "Answer test questions", pinned: false, archived: false,
                            unreadCount: 0, createdAt: Date(), updatedAt: Date(), memoryNote: "", folderPath: nil,
                            brainRawValue: brain.rawValue, connectorExclusionIDs: exclusions)
            _ = manager.mateDirectory.upsertMate(mate)
            manager.syncMatePublications()
            return mate
        }

        /// Mate work runs in the mate's own folder, which outlives a failed
        /// job; only sandbox runs are cleaned up.
        func runUsesMateFolder(_ run: AgentRun, mateID: UUID) -> Bool {
            guard let folder = manager.mates.first(where: { $0.id == mateID })?.folderPath else { return false }
            return run.workspaceURL.standardizedFileURL.path == URL(fileURLWithPath: folder).standardizedFileURL.path
        }

        func addChat(mateID: UUID) -> ChatSession {
            var chat = ChatSession.empty()
            chat.mateID = mateID
            chat.messages = [ChatMessage(id: UUID(), role: .user, text: "Earlier question", createdAt: Date())]
            manager.chatHistoryStore.upsert(chat)
            return chat
        }

        func addRoutine(mateID: UUID, task: String = "Explain account terminology.") -> MateRoutine {
            let routine = MateRoutine(id: UUID(), mateID: mateID, task: task,
                                      enabled: true, schedule: .everyHours(1), nextRunAt: Date(),
                                      lastRunAt: nil, lastStatusMessage: nil, consecutiveFailures: 0, pausedReason: nil)
            manager.mateDirectory.addRoutine(routine)
            manager.syncMatePublications()
            return routine
        }

        func cleanUp() {
            manager.cancelInFlightChatTurn()
            client.finish(throwing: CancellationError())
            for key in preferenceKeys {
                if let value = preferences[key] { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class FailingSpeech: TTSClient {
    var isPlaying: Bool { false }
    func speakText(_ text: String) async throws { throw NSError(domain: "NoVoice", code: 1) }
    func stopPlayback() {}
}

@MainActor
private final class SuspendedConversationClient: ToolCallingConversationClient {
    var model = "navigation-test"
    struct Request { let systemPrompt: String; let userPrompt: String; let imageLabels: [String] }
    var requests: [Request] = []
    var approvalRequest: (ConnectorToolCoordinator, ConnectorToolApprovalRequest)?
    var approvalDecision: Bool?
    private enum Command {
        case chunk(String), tool(AssistantToolCall), finish(String), fail(Error)
    }
    private var continuation: CheckedContinuation<Command, Never>?
    private var lastToolResult: (text: String, isError: Bool)?

    func analyzeImageStreaming(images: [(data: Data, label: String)], systemPrompt: String,
                               conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
                               userPrompt: String, onTextChunk: @MainActor @Sendable (String) -> Void) async throws -> (text: String, duration: TimeInterval) {
        try await analyzeImageStreaming(images: images, systemPrompt: systemPrompt, conversationHistory: conversationHistory,
                                        userPrompt: userPrompt, availableTools: [], onTextChunk: onTextChunk,
                                        onToolCallRequested: { _ in ("No tool handler", true) })
    }

    func analyzeImageStreaming(images: [(data: Data, label: String)], systemPrompt: String,
                               conversationHistory: [(userPlaceholder: String, assistantResponse: String)], userPrompt: String,
                               availableTools: [AssistantToolDefinition], onTextChunk: @MainActor @Sendable (String) -> Void,
                               onToolCallRequested: @MainActor @Sendable (AssistantToolCall) async -> (text: String, isError: Bool)) async throws -> (text: String, duration: TimeInterval) {
        requests.append(Request(systemPrompt: systemPrompt, userPrompt: userPrompt, imageLabels: images.map(\.label)))
        if let (coordinator, request) = approvalRequest {
            approvalDecision = await coordinator.requestApproval(for: request)
            return ("Approval test completed", 0)
        }
        // Deliberately ignores task cancellation to model a provider that
        // still emits queued callbacks and terminal events after Stop.
        while true {
            let command = await withCheckedContinuation { continuation = $0 }
            switch command {
            case .chunk(let text): onTextChunk(text)
            case .tool(let call): lastToolResult = await onToolCallRequested(call)
            case .finish(let text): return (text, 0)
            case .fail(let error): throw error
            }
        }
    }

    func waitForRequest() async throws {
        // Talk may await account context before reaching the client. A fixed
        // number of yields can expire before that asynchronous work finishes.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if continuation != nil { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw NSError(domain: "ChatTurnNavigationTests.requestDidNotStart", code: 1)
    }

    func emitChunk(_ text: String) async throws {
        send(.chunk(text))
        try await waitForRequest()
    }

    func requestTool(_ call: AssistantToolCall) async throws -> (text: String, isError: Bool) {
        lastToolResult = nil
        send(.tool(call))
        try await waitForRequest()
        return try #require(lastToolResult)
    }

    func finish(text: String) { send(.finish(text)) }
    func finish(throwing error: Error) { send(.fail(error)) }

    private func send(_ command: Command) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: command)
    }
}
