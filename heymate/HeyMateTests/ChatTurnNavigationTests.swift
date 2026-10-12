import Foundation
import Testing
@testable import HeyMate

@MainActor
@Suite(.serialized)
struct ChatTurnNavigationTests {
    @Test(arguments: ["new", "open", "mate", "delete", "clear", "clearMate", "stop"],
          ["talk", "agent", "fallback"])
    func navigationRejectsLateIntentClassification(action: String, route: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let gate = SuspendedIntentRequest()
        manager.voiceIntentClassifier.performRequest = { try await gate.request($0) }
        let other = fixture.addMate(name: "Pixel", brain: .onDevice)
        let otherChat = fixture.addChat(mateID: other.id)
        let input = "draft the reply to Sam"
        #expect(VoiceRouter.decide(input) == .needsClassification)
        #expect(manager.sendTypedMessage(input))
        let classification = try #require(manager.currentResponseTask)
        try await gate.waitForRequest()
        #expect(manager.isComposerStopVisible)
        switch action {
        case "new": manager.startNewChat()
        case "open": manager.openChat(id: otherChat.id)
        case "mate": manager.openMate(id: other.id)
        case "delete": manager.deleteChat(id: manager.currentChat.id)
        case "clear": manager.clearAllChats()
        case "clearMate": manager.clearChats(forMateID: try #require(manager.currentChat.mateID))
        default: manager.cancelInFlightChatTurn()
        }
        let expectedChat = manager.currentChat
        gate.finish(route: route)
        await classification.value
        #expect(manager.currentChat == expectedChat)
        #expect(fixture.client.requests.isEmpty)
        #expect(manager.agentRuns.isEmpty)
        #expect(manager.state == .idle)
        #expect(!manager.isComposerStopVisible)
    }

    @Test func oldClassificationCannotReplaceANewerReply() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let gate = SuspendedIntentRequest()
        manager.voiceIntentClassifier.performRequest = { try await gate.request($0) }
        #expect(manager.sendTypedMessage("draft the reply to Sam"))
        let classification = try #require(manager.currentResponseTask)
        try await gate.waitForRequest()
        manager.sendTranscriptToClaudeWithScreenshot(transcript: "New question", shouldCaptureScreen: false)
        let reply = try #require(manager.currentResponseTask)
        try await fixture.client.waitForRequest()
        gate.finish(route: "agent")
        await classification.value
        #expect(manager.isResponseInFlight)
        #expect(manager.agentRuns.isEmpty)
        fixture.client.finish(text: "New answer")
        await reply.value
        #expect(manager.currentChat.messages.map(\.text) == ["New question", "New answer"])
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
        #expect(toolResult.text == "This reply was cancelled. No action was taken.")
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
        let mate = try #require(manager.createAgent(from: result.draft, faceAssetName: "MateFaceSignalPointer"))
        #expect(mate.name == "Inbox Ivy")
        #expect(mate.soul == "Warm and brief.")
        #expect(mate.faceAssetName == "MateFaceSignalPointer")
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
        #expect(manager.selectedBrain == .customAPI)
        #expect(manager.conversationBrainForTurn == .onDevice)
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
    func openCodeConsentResumesInReceivingMatesChat(isHandoff: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let key = fixture.selectUnapprovedOpenCodeModel()
        let worker = fixture.addMate(name: "Scout", brain: .openCode)
        let workerChat = fixture.addChat(mateID: worker.id)
        let other = fixture.addMate(name: "Pixel", brain: .onDevice)
        manager.openMate(id: other.id)
        if isHandoff {
            manager.beginHandoff(MateHandoff(mateID: worker.id, mateName: worker.name,
                                             instruction: "Explain account terminology."))
        } else {
            #expect(manager.kickoffRoutine(fixture.addRoutine(mateID: worker.id)) == .busy)
        }
        #expect(manager.openCodeTrainingNotice?.modelKey == key)
        #expect(!OpenCodeTrainingConsent.isAcknowledged(key))
        #expect(fixture.client.requests.isEmpty)
        #expect(manager.backgroundRoutineSession == nil)
        // A new visible chat must not become the background request's destination.
        manager.startNewChat()
        let visibleChat = manager.currentChat
        manager.confirmOpenCodeTrainingSend()
        let task = try #require(manager.currentResponseTask)
        try await fixture.client.waitForRequest()
        #expect(OpenCodeTrainingConsent.isAcknowledged(key))
        #expect(manager.conversationBrainForTurn == .openCode)
        #expect(manager.selectedBrain == .onDevice)
        #expect(manager.backgroundRoutineSession?.id == workerChat.id)
        #expect(fixture.client.requests[0].systemPrompt.contains("Scout"))
        fixture.client.finish(text: "Account means a sign-in identity.")
        await task.value
        #expect(manager.currentChat == visibleChat)
        #expect(manager.chatHistoryStore.session(id: workerChat.id)?.messages.last?.text
            .contains("sign-in identity") == true)
    }

    @Test(arguments: [false, true])
    func receivingNonOpenCodeMateDoesNotUseVisibleMatesConsent(isHandoff: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let key = fixture.selectUnapprovedOpenCodeModel()
        let worker = fixture.addMate(name: "Scout", brain: .onDevice)
        let workerChat = fixture.addChat(mateID: worker.id)
        let visible = fixture.addMate(name: "Pixel", brain: .openCode)
        manager.openMate(id: visible.id)
        if isHandoff {
            manager.beginHandoff(MateHandoff(mateID: worker.id, mateName: worker.name,
                                             instruction: "Explain account terminology."))
        } else {
            #expect(manager.kickoffRoutine(fixture.addRoutine(mateID: worker.id)) == .started)
        }
        let task = try #require(manager.currentResponseTask)
        try await fixture.client.waitForRequest()
        #expect(manager.openCodeTrainingNotice == nil)
        #expect(!OpenCodeTrainingConsent.isAcknowledged(key))
        #expect(manager.conversationBrainForTurn == .onDevice)
        #expect(manager.backgroundRoutineSession?.id == workerChat.id)
        fixture.client.finish(text: "A test answer.")
        await task.value
    }

    @Test(arguments: ["delete", "clearMate", "clearAll", "deleteMate", "changeModel", "changeBrain", "deleteRoutine", "pauseRoutine"])
    func changedOrDeletedConsentTargetCannotResume(action: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let key = fixture.selectUnapprovedOpenCodeModel()
        var worker = fixture.addMate(name: "Scout", brain: .openCode)
        let chat = fixture.addChat(mateID: worker.id)
        let routine = fixture.addRoutine(mateID: worker.id)
        #expect(manager.kickoffRoutine(routine) == .busy)
        #expect(manager.openCodeTrainingNotice != nil)
        switch action {
        case "delete": manager.deleteChat(id: chat.id)
        case "clearMate": manager.clearChats(forMateID: worker.id)
        case "clearAll": manager.clearAllChats()
        case "deleteMate": _ = manager.deleteMate(id: worker.id)
        case "changeModel": manager.openCodeModelID = "another-free-model"
        case "changeBrain":
            worker.brainRawValue = AgentBrain.onDevice.rawValue
            _ = manager.mateDirectory.upsertMate(worker)
        case "deleteRoutine": manager.deleteRoutine(id: routine.id)
        default: manager.pauseRoutine(id: routine.id)
        }
        manager.confirmOpenCodeTrainingSend()
        #expect(manager.openCodeTrainingNotice == nil)
        #expect(!OpenCodeTrainingConsent.isAcknowledged(key))
        #expect(fixture.client.requests.isEmpty)
        #expect(manager.currentResponseTask == nil)
        #expect(manager.backgroundRoutineSession == nil)
    }

    @Test func addressedMateChecksItsOwnProviderBeforeSending() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let key = fixture.selectUnapprovedOpenCodeModel()
        let worker = fixture.addMate(name: "Scout", brain: .openCode)
        #expect(!manager.sendTypedMessage("Ask Scout to explain account terminology."))
        #expect(manager.currentChat.mateID == worker.id)
        #expect(manager.openCodeTrainingNotice?.modelKey == key)
        #expect(fixture.client.requests.isEmpty)
        #expect(manager.currentResponseTask == nil)
        manager.startNewChat()
        manager.confirmOpenCodeTrainingSend()
        #expect(manager.openCodeTrainingNotice == nil)
        #expect(!OpenCodeTrainingConsent.isAcknowledged(key))
        #expect(manager.currentResponseTask == nil)
    }

    @Test func finalTalkBoundaryAlsoRequiresOpenCodeConsent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let key = fixture.selectUnapprovedOpenCodeModel()
        let worker = fixture.addMate(name: "Scout", brain: .openCode)
        manager.openMate(id: worker.id)
        manager.sendTranscriptToClaudeWithScreenshot(transcript: "Private test words", shouldCaptureScreen: false)
        #expect(manager.openCodeTrainingNotice?.modelKey == key)
        #expect(fixture.client.requests.isEmpty)
        #expect(manager.currentResponseTask == nil)
        #expect(manager.currentChat.messages.isEmpty)
    }

    @Test func consentWaitsForNewerReplyWithoutInterruptingIt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let key = fixture.selectUnapprovedOpenCodeModel()
        let worker = fixture.addMate(name: "Scout", brain: .openCode)
        _ = fixture.addChat(mateID: worker.id)
        #expect(manager.kickoffRoutine(fixture.addRoutine(mateID: worker.id)) == .busy)
        manager.sendTranscriptToClaudeWithScreenshot(transcript: "New foreground question", shouldCaptureScreen: false)
        let foregroundTask = try #require(manager.currentResponseTask)
        try await fixture.client.waitForRequest()
        manager.confirmOpenCodeTrainingSend()
        #expect(manager.openCodeTrainingNotice?.modelKey == key)
        #expect(!OpenCodeTrainingConsent.isAcknowledged(key))
        #expect(!foregroundTask.isCancelled)
        #expect(manager.backgroundRoutineSession == nil)
        fixture.client.finish(text: "Foreground answer.")
        await foregroundTask.value
        // A completed task handle must not keep an approved routine busy forever.
        manager.confirmOpenCodeTrainingSend()
        let backgroundTask = try #require(manager.currentResponseTask)
        try await fixture.client.waitForRequest()
        #expect(OpenCodeTrainingConsent.isAcknowledged(key))
        #expect(manager.backgroundRoutineSession?.mateID == worker.id)
        fixture.client.finish(text: "Background answer.")
        await backgroundTask.value
    }

    @Test(arguments: ["talk", "agent"])
    func changingProviderDiscardsLateIntentClassification(route: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let gate = SuspendedIntentRequest()
        manager.voiceIntentClassifier.performRequest = { try await gate.request($0) }
        #expect(manager.sendTypedMessage("draft the reply to Sam"))
        let classification = try #require(manager.currentResponseTask)
        try await gate.waitForRequest()
        _ = fixture.selectUnapprovedOpenCodeModel()
        manager.selectedBrain = .openCode
        gate.finish(route: route)
        await classification.value
        #expect(fixture.client.requests.isEmpty)
        #expect(manager.agentRuns.isEmpty)
        #expect(manager.currentChat.messages.isEmpty)
        #expect(manager.state == .idle)
    }

    @Test(arguments: ["brain", "model"], ["none", "listening", "finalizing"])
    func invalidatedVoiceClassificationReleasesOnlyItsOwnInput(change: String, newerInput: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let gate = SuspendedIntentRequest()
        manager.voiceIntentClassifier.performRequest = { try await gate.request($0) }
        if change == "model" {
            manager.selectedBrain = .openCode
            OpenCodeTrainingConsent.acknowledge(fixture.selectUnapprovedOpenCodeModel())
        }
        manager.dispatch(.startListening(.talk))
        manager.dispatch(.finishListening)
        manager.handleTalkTranscript("draft the reply to Sam")
        let classification = try #require(manager.currentResponseTask)
        try await gate.waitForRequest()
        #expect(manager.state == .finalizingTranscript)

        if newerInput != "none" {
            // The Talk shortcut cancels the old response before starting
            // another recording. Its late classifier must not finish this one.
            classification.cancel()
            manager.dispatch(.startListening(.talk))
            if newerInput == "finalizing" { manager.dispatch(.finishListening) }
        }
        let expectedState: CompanionState = newerInput == "none" ? .idle : manager.state
        if change == "model" { manager.openCodeModelID = "changed-model" }
        else { manager.selectedBrain = .codex }
        gate.finish(route: "agent")
        await classification.value

        #expect(manager.state == expectedState)
        #expect((manager.typedMessageBusyReason == nil) == (newerInput == "none"))
        #expect(!manager.isComposerStopVisible)
        #expect(fixture.client.requests.isEmpty)
        #expect(manager.agentRuns.isEmpty)
        #expect(manager.currentChat.messages.isEmpty)
    }

    @Test(arguments: [false, true], ["agent", "fallbackAgent", "brainChanged", "modelChanged", "localToTalk", "replacement"])
    func backgroundClassificationFinishesOnlyItsOwnDelivery(isHandoff: Bool, route: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let gate = SuspendedIntentRequest()
        manager.voiceIntentClassifier.performRequest = { try await gate.request($0) }
        // Exercise dispatch and its synchronous failure without starting a CLI
        // or creating a sandbox outside the test directory.
        manager.agentLauncher.readinessForExecutor = { _ in
            HeadlessExecutorReadiness(state: .notSignedIn, detail: "Test executor signed out", remedy: "Sign in to test executor.")
        }
        manager.agentLauncher.resolveExecutable = { _ in nil }
        var worker = fixture.addMate(name: "Scout", brain: route == "modelChanged" ? .openCode : .codex)
        if route == "modelChanged" {
            OpenCodeTrainingConsent.acknowledge(fixture.selectUnapprovedOpenCodeModel())
        }
        let workerChat = fixture.addChat(mateID: worker.id)
        let input = route == "fallbackAgent" ? "build a test website" : "draft the reply to Sam"
        #expect(VoiceRouter.decide(input) == .needsClassification)
        if isHandoff {
            manager.beginHandoff(MateHandoff(mateID: worker.id, mateName: worker.name, instruction: input))
        } else {
            #expect(manager.kickoffRoutine(fixture.addRoutine(mateID: worker.id, task: input)) == .started)
        }
        let classification = try #require(manager.currentResponseTask)
        try await gate.waitForRequest()
        let other = fixture.addMate(name: "Pixel", brain: .onDevice)
        manager.openMate(id: other.id)
        let visibleChat = manager.currentChat
        if route == "brainChanged" {
            worker.brainRawValue = AgentBrain.onDevice.rawValue
            _ = manager.mateDirectory.upsertMate(worker)
        } else if route == "modelChanged" {
            manager.openCodeModelID = "new-free-model"
        } else if route == "replacement" {
            manager.sendTranscriptToClaudeWithScreenshot(transcript: "Newer background question", shouldCaptureScreen: false)
        }
        gate.finish(route: route == "fallbackAgent" ? "fallback" : route == "localToTalk" ? "local" : "agent")
        await classification.value
        if route == "localToTalk" || route == "replacement" {
            // Talk owns the delivery now. The old classifier cannot clear it.
            #expect(manager.backgroundRoutineSession?.id == workerChat.id)
            #expect(manager.activeRoutineTurn != nil || manager.activeHandoffMateID != nil)
            let reply = try #require(manager.currentResponseTask)
            try await fixture.client.waitForRequest()
            fixture.client.finish(text: "New background answer.")
            await reply.value
        }
        #expect(manager.activeRoutineTurn == nil)
        #expect(manager.activeHandoffMateID == nil)
        #expect(manager.backgroundRoutineSession == nil)
        #expect(!manager.isChatTurnBusy)
        #expect(manager.currentChat == visibleChat)
        if route == "agent" || route == "fallbackAgent" {
            let run = try #require(manager.agentRunStore.loadAll().first)
            #expect(run.executor == .codex)
            #expect(run.chatOwner == AgentChatOwner(mateID: worker.id, chatID: workerChat.id))
            #expect(run.status == .failed)
            #expect(fixture.runUsesMateFolder(run, mateID: worker.id))
        } else {
            #expect(manager.agentRunStore.loadAll().isEmpty)
        }
    }

    @Test func heldVoiceConsentFinishesTranscriptBeforeConfirmation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let key = fixture.selectUnapprovedOpenCodeModel()
        let mate = fixture.addMate(name: "Scout", brain: .openCode)
        manager.openMate(id: mate.id)
        manager.dispatch(.startListening(.talk))
        manager.dispatch(.finishListening)
        #expect(manager.state == .finalizingTranscript)
        #expect(manager.holdForOpenCodeTrainingConsent("Explain account terminology.", imageAttachments: []))
        #expect(manager.state == .idle)
        #expect(fixture.client.requests.isEmpty)
        manager.confirmOpenCodeTrainingSend()
        let task = try #require(manager.currentResponseTask)
        try await fixture.client.waitForRequest()
        #expect(OpenCodeTrainingConsent.isAcknowledged(key))
        #expect(manager.openCodeTrainingNotice == nil)
        fixture.client.finish(throwing: CancellationError())
        await task.value
    }

    @Test(arguments: [false, true])
    func heldConsentDoesNotClearUnrelatedAgentState(waitingForApproval: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let key = fixture.selectUnapprovedOpenCodeModel()
        let mate = fixture.addMate(name: "Scout", brain: .openCode)
        manager.openMate(id: mate.id)
        let runID = UUID()
        manager.dispatch(.agentStarted(runID))
        if waitingForApproval { manager.dispatch(.approvalRequested(runID)) }
        let agentState = manager.state
        #expect(manager.holdForOpenCodeTrainingConsent("Explain account terminology.", imageAttachments: []))
        manager.confirmOpenCodeTrainingSend()
        #expect(manager.state == agentState)
        #expect(manager.openCodeTrainingNotice?.modelKey == key)
        #expect(!OpenCodeTrainingConsent.isAcknowledged(key))
        #expect(fixture.client.requests.isEmpty)
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

    @Test(arguments: [false, true], [AgentBrain.codex, .openCode])
    func explicitBackgroundAgentUsesReceivingBrainAndConsent(isHandoff: Bool, receivingBrain: AgentBrain) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let key = fixture.selectUnapprovedOpenCodeModel()
        manager.agentLauncher.readinessForExecutor = { _ in
            HeadlessExecutorReadiness(state: .notSignedIn, detail: "Test executor signed out", remedy: "Sign in to test executor.")
        }
        manager.agentLauncher.resolveExecutable = { _ in nil }
        let worker = fixture.addMate(name: "Scout", brain: receivingBrain)
        let workerChat = fixture.addChat(mateID: worker.id)
        let visible = fixture.addMate(name: "Pixel", brain: receivingBrain == .codex ? .openCode : .codex)
        manager.openMate(id: visible.id)
        let visibleChat = manager.currentChat
        let input = "agent, count the sample workspace"
        #expect(VoiceRouter.decide(input) == .agent)
        if isHandoff {
            manager.beginHandoff(MateHandoff(mateID: worker.id, mateName: worker.name, instruction: input))
        } else {
            let result = manager.kickoffRoutine(fixture.addRoutine(mateID: worker.id, task: input))
            #expect(result == (receivingBrain == .openCode ? .busy : .started))
        }
        if receivingBrain == .openCode {
            #expect(manager.agentRunStore.loadAll().isEmpty)
            #expect(manager.openCodeTrainingNotice?.modelKey == key)
            #expect(!OpenCodeTrainingConsent.isAcknowledged(key))
            manager.confirmOpenCodeTrainingSend()
            #expect(OpenCodeTrainingConsent.isAcknowledged(key))
        } else {
            #expect(manager.openCodeTrainingNotice == nil)
            #expect(!OpenCodeTrainingConsent.isAcknowledged(key))
        }
        let run = try #require(manager.agentRunStore.loadAll().first)
        #expect(run.executor == receivingBrain.executor)
        #expect(run.chatOwner == AgentChatOwner(mateID: worker.id, chatID: workerChat.id))
        #expect(run.status == .failed)
        #expect(fixture.runUsesMateFolder(run, mateID: worker.id))
        #expect(manager.currentChat == visibleChat)
        #expect(manager.backgroundRoutineSession == nil)
        #expect(manager.activeRoutineTurn == nil)
        #expect(manager.activeHandoffMateID == nil)
    }

    @Test(arguments: ["foreground", "routine", "handoff"])
    func explicitOpenCodeOverrideRequiresConsentAndResumesSameOwner(delivery: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let key = fixture.selectUnapprovedOpenCodeModel()
        fixture.blockAgentLaunches()
        let worker = fixture.addMate(name: "Scout", brain: .codex)
        let workerChat = fixture.addChat(mateID: worker.id)
        if delivery == "foreground" { manager.openChat(id: workerChat.id) }
        let visibleChat = manager.currentChat
        let input = "agent, use OpenCode to count the sample workspace"
        switch delivery {
        case "routine": #expect(manager.kickoffRoutine(fixture.addRoutine(mateID: worker.id, task: input)) == .busy)
        case "handoff": manager.beginHandoff(MateHandoff(mateID: worker.id, mateName: worker.name, instruction: input))
        default: #expect(!manager.sendTypedMessage(input))
        }
        #expect(manager.openCodeTrainingNotice?.modelKey == key)
        #expect(manager.agentRunStore.loadAll().isEmpty)
        #expect(fixture.client.requests.isEmpty)
        manager.confirmOpenCodeTrainingSend()
        #expect(OpenCodeTrainingConsent.isAcknowledged(key))
        let run = try #require(manager.agentRunStore.loadAll().first)
        #expect(run.executor == .openCode)
        #expect(run.chatOwner == AgentChatOwner(mateID: worker.id, chatID: workerChat.id))
        #expect(fixture.runUsesMateFolder(run, mateID: worker.id))
        if delivery != "foreground" { #expect(manager.currentChat == visibleChat) }
    }

    @Test func explicitCodexOverrideDoesNotAskForUnusedOpenCodeModel() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let key = fixture.selectUnapprovedOpenCodeModel()
        fixture.blockAgentLaunches()
        let mate = fixture.addMate(name: "Scout", brain: .openCode)
        manager.openMate(id: mate.id)
        #expect(manager.sendTypedMessage("agent, use Codex to count the sample workspace"))
        #expect(manager.openCodeTrainingNotice == nil)
        #expect(!OpenCodeTrainingConsent.isAcknowledged(key))
        #expect(manager.agentRunStore.loadAll().first?.executor == .codex)
    }

    @Test func classifiedRewritePreservesApprovedExplicitExecutor() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let key = fixture.selectUnapprovedOpenCodeModel()
        fixture.blockAgentLaunches()
        let mate = fixture.addMate(name: "Scout", brain: .codex)
        manager.openMate(id: mate.id)
        let ownerChatID = manager.currentChat.id
        let gate = SuspendedIntentRequest()
        manager.voiceIntentClassifier.performRequest = { try await gate.request($0) }
        let input = "use OpenCode to draft the reply to Sam"
        #expect(VoiceRouter.decide(input) == .needsClassification)
        #expect(!manager.sendTypedMessage(input))
        #expect(manager.currentResponseTask == nil)
        manager.confirmOpenCodeTrainingSend()
        let classification = try #require(manager.currentResponseTask)
        try await gate.waitForRequest()
        // The mock task omits the provider; the original explicit choice wins.
        gate.finish(route: "agent")
        await classification.value
        #expect(OpenCodeTrainingConsent.isAcknowledged(key))
        let run = try #require(manager.agentRunStore.loadAll().first)
        #expect(run.executor == .openCode)
        #expect(run.chatOwner == AgentChatOwner(mateID: mate.id, chatID: ownerChatID))
    }

    @Test(arguments: [false, true])
    func lateOpenCodeJobOverrideFailsClosed(attached: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let key = fixture.selectUnapprovedOpenCodeModel()
        fixture.blockAgentLaunches()
        manager.selectedBrain = .codex
        let runID = attached
            ? manager.startAttachedAgent(prompt: "Use OpenCode to count samples", workspaceURL: fixture.root)
            : manager.startSandboxAgent(prompt: "Use OpenCode to count samples")
        #expect(runID == nil)
        #expect(manager.agentRunStore.loadAll().isEmpty)
        #expect(!OpenCodeTrainingConsent.isAcknowledged(key))
        #expect(manager.commandBarFeedback?.contains("resend the task") == true)
        #expect(manager.openCodeTrainingNotice == nil)
    }

    @Test func talkBoundaryDoesNotMistakeExecutorWordsForItsActualProvider() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        let key = fixture.selectUnapprovedOpenCodeModel()
        manager.selectedBrain = .openCode
        manager.sendTranscriptToClaudeWithScreenshot(transcript: "Explain how to work with Codex", shouldCaptureScreen: false)
        #expect(manager.openCodeTrainingNotice?.modelKey == key)
        #expect(manager.currentResponseTask == nil)
        #expect(fixture.client.requests.isEmpty)
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

        func blockAgentLaunches() {
            manager.agentLauncher.readinessForExecutor = { _ in
                HeadlessExecutorReadiness(state: .notSignedIn, detail: "Test executor signed out", remedy: "Sign in to test executor.")
            }
            manager.agentLauncher.resolveExecutable = { _ in nil }
        }

        func selectUnapprovedOpenCodeModel() -> String {
            manager.openCodeProviderID = "consent-test-\(UUID())"
            manager.openCodeModelID = "big-pickle"
            return OpenCodeTrainingPolicy.modelKey(providerID: manager.openCodeProviderID, modelID: manager.openCodeModelID)
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

@MainActor
private final class SuspendedIntentRequest {
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var url: URL?

    func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
        url = request.url
        // Ignore cancellation to reproduce providers returning after navigation.
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func waitForRequest() async throws {
        for _ in 0..<100 {
            if continuation != nil { return }
            await Task.yield()
        }
        throw NSError(domain: "IntentRequestDidNotStart", code: 1)
    }

    func finish(route: String) {
        guard let continuation, let url else { return }
        self.continuation = nil
        if route == "fallback" {
            continuation.resume(throwing: CancellationError())
            return
        }
        let reply = "\"route\":\"\(route)\",\"task\":\"Write an old test file\"}"
        let data = try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": reply]]])
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        continuation.resume(returning: (data, response))
    }
}

@MainActor
private final class SuspendedConversationClient: ToolCallingConversationClient {
    var model = "navigation-test"
    struct Request { let systemPrompt: String; let userPrompt: String }
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
        requests.append(Request(systemPrompt: systemPrompt, userPrompt: userPrompt))
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
        for _ in 0..<100 {
            if continuation != nil { return }
            await Task.yield()
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
