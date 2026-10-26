import Foundation
import Testing
@testable import HeyMate

@MainActor
@Suite(.serialized)
struct MateAgentManagerRoutingTests {
    enum RetiredPreference: String { case pi, native }
    /// Finalized dictation text only: no mic, screen, AX or pasteboard access.
    @Test func mateAgentSmartPreferenceUsesLiteralSyntheticInsertionWithoutNativeClient() async throws {
        let fixture = try Fixture(engine: .pi)
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.dictationUsesSmartMode = true
        var inserted: [String] = []
        manager.dictationInsertionOverride = { text in inserted.append(text); return .insertedViaAccessibility }
        let original = "Rewrite this: delete all files? No, keep that exact sentence."
        manager.processDictationTranscript(original)
        let task = try #require(manager.currentResponseTask)
        await task.value
        #expect(inserted == [original])
        #expect(fixture.client.requests.isEmpty)
        #expect(manager.dictationUsesSmartMode)
        #expect(!manager.effectiveDictationUsesSmartMode)
        #expect(manager.commandBarFeedback?.contains("Literal dictation") == true)
        #expect(manager.agentRuns.isEmpty)
    }
    /// Exercises a finalized transcript only: no microphone, STT or playback.
    @Test func syntheticTalkTranscriptBypassesUnrelatedNativeOpenCodeConsent() async throws {
        let fixture = try Fixture(engine: .pi)
        defer { fixture.cleanUp() }
        let manager = fixture.manager
        manager.openCodeProviderID = "mateAgent-voice-consent-\(UUID())"
        manager.openCodeModelID = "big-pickle"
        let transcript = "agent, use OpenCode to explain gravity"
        #expect(!TalkContextPolicy.shouldCaptureScreen(for: transcript, hasSpatialSelection: false))
        // Establish that the retained native model really would require consent.
        #expect(manager.holdForOpenCodeTrainingConsent(transcript, imageAttachments: [], explicitExecutor: .openCode))
        manager.cancelOpenCodeTrainingSend()
        manager.handleTalkTranscript(transcript)
        let task = try #require(manager.currentResponseTask)
        await task.value
        #expect(manager.openCodeTrainingNotice == nil)
        #expect(fixture.client.requests.count == 1)
        #expect(fixture.client.requests.first?.systemPrompt.contains("using its custom Pi harness") == true)
        #expect(fixture.client.requests.first?.userPrompt.contains(transcript) == true)
        #expect(manager.heyMateTalkSession.messages.last?.text == fixture.client.answer)
        #expect(manager.agentRuns.isEmpty)
    }
    @Test(arguments: [RetiredPreference.pi, .native])
    func onboardingAIReadinessIgnoresRetiredEnginePreference(engine: RetiredPreference) throws {
        let fixture = try Fixture(engine: engine)
        defer { fixture.cleanUp() }
        let savedStep = UserDefaults.standard.object(forKey: OnboardingTour.progressKey)
        defer {
            if let savedStep { UserDefaults.standard.set(savedStep, forKey: OnboardingTour.progressKey) }
            else { UserDefaults.standard.removeObject(forKey: OnboardingTour.progressKey) }
        }
        UserDefaults.standard.set(OnboardingStep.ai.rawValue, forKey: OnboardingTour.progressKey)
        let tour = OnboardingTour(companionManager: fixture.manager, restart: false)
        #expect(tour.step == .ai)
        tour.mateAgentReadinessChanged(true)
        #expect(tour.isStepDone)
        tour.mateAgentReadinessChanged(false)
        #expect(!tour.isStepDone)
        #expect(fixture.client.requests.isEmpty)
        #expect(fixture.manager.agentRuns.isEmpty)
    }

    @Test func hostedScreenPermissionRequestNeverStartsCapture() throws {
        let fixture = try Fixture(engine: .pi)
        defer { fixture.cleanUp() }
        #expect(HeyMateDataDirectory.isUnitTestHost)
        fixture.manager.requestScreenContentPermission()
        #expect(!fixture.manager.isRequestingScreenContent)
    }

    @Test(arguments: [
        "agent, build a website",
        "Build a landing page",
        "draft the reply to Sam",
        #"start_mate_work {"task":"Build a landing page"}"#
    ])
    func mateAgentRequestsBypassNativeClassificationAndWorkLaunch(input: String) async throws {
        let fixture = try Fixture(engine: .pi)
        defer { fixture.cleanUp() }
        var classificationCalls = 0
        fixture.manager.voiceIntentClassifier.performRequest = { _ in
            classificationCalls += 1
            throw NSError(domain: "UnexpectedNativeClassification", code: 1)
        }
        #expect(fixture.manager.sendTypedMessage(input))
        let task = try #require(fixture.manager.currentResponseTask)
        await task.value
        #expect(classificationCalls == 0)
        #expect(fixture.client.requests.count == 1)
        #expect(fixture.client.requests.first?.systemPrompt.contains("using its custom Pi harness") == true)
        #expect(fixture.client.requests.first?.userPrompt.contains(input) == true)
        #expect(fixture.manager.agentRuns.isEmpty)
        #expect(fixture.manager.pendingHandoffs.isEmpty)
    }

    @Test(arguments: [
        "[WORK: Build a landing page]",
        #"start_mate_work {"task":"Build a landing page"}"#,
        #"{"tool":"start_mate_work","task":"Build a landing page"}"#,
        "[ASK:Unknown Specialist: Build a landing page]"
    ])
    func mateAgentAnswersNeverExecuteNativeDirectives(answer: String) async throws {
        let fixture = try Fixture(engine: .pi)
        defer { fixture.cleanUp() }
        fixture.client.answer = answer
        #expect(fixture.manager.sendTypedMessage("Explain how you handle a task"))
        let task = try #require(fixture.manager.currentResponseTask)
        await task.value
        #expect(fixture.manager.currentChat.messages.last?.text == answer)
        #expect(fixture.manager.agentRuns.isEmpty)
        #expect(fixture.manager.pendingHandoffs.isEmpty)
        #expect(!fixture.client.usedNativeToolLoop)
    }

    @Test func retiredNativePreferenceStillUsesHeyMateHarness() async throws {
        let fixture = try Fixture(engine: .native)
        defer { fixture.cleanUp() }
        #expect(MateEngine.selected() == .pi)
        fixture.manager.sendTranscriptToClaudeWithScreenshot(transcript: "Explain account terminology", shouldCaptureScreen: false)
        let task = try #require(fixture.manager.currentResponseTask)
        await task.value
        #expect(fixture.client.requests.count == 1)
        #expect(fixture.client.requests.first?.systemPrompt.contains("using its custom Pi harness") == true)
        #expect(fixture.manager.currentChat.messages.last?.text == fixture.client.answer)
        #expect(fixture.manager.agentRuns.isEmpty)
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let client = RoutingClient()
        let manager: CompanionManager
        private let preferences: [String: Any]
        private let preferenceKeys = [MateEngine.preferenceKey, "selectedAgentBrain", "defaultHeadlessExecutor",
            "chatConnectorExclusions", "rememberConversations", "selectedVoiceSpeakProvider", "selectedVoiceListenProvider",
            "selectedOpenCodeProviderID", "selectedOpenCodeModelID", "openCodeTrainingAcknowledgedModelKeys",
            "dictationUsesSmartMode",
            SilentModePreferences.userDefaultsKey]

        init(engine: RetiredPreference?) throws {
            preferences = Dictionary(uniqueKeysWithValues: preferenceKeys.compactMap { key in
                UserDefaults.standard.object(forKey: key).map { (key, $0) }
            })
            if let engine { UserDefaults.standard.set(engine.rawValue, forKey: MateEngine.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: MateEngine.preferenceKey) }
            UserDefaults.standard.set(VoiceSpeakProvider.macOS.rawValue, forKey: "selectedVoiceSpeakProvider")
            UserDefaults.standard.set(VoiceListenProvider.apple.rawValue, forKey: "selectedVoiceListenProvider")
            UserDefaults.standard.set(true, forKey: SilentModePreferences.userDefaultsKey)
            root = FileManager.default.temporaryDirectory.appendingPathComponent("mateAgent-routing-\(UUID())", isDirectory: true)
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
            manager.selectedBrain = .onDevice
            manager.rememberConversationsEnabled = true
            manager.setChatConnectorEnabled(false, selectionID: CompanionManager.chatConnectorSelectionID(forConnectorID: "apple-mail"))
            manager.setChatConnectorEnabled(false, selectionID: CompanionManager.chatConnectorSelectionID(forConnectorID: "apple-calendar"))
            manager.agentLauncher.readinessForExecutor = { _ in
                HeadlessExecutorReadiness(state: .notSignedIn, detail: "Test blocks native launches", remedy: "No launch permitted in routing test.")
            }
            manager.agentLauncher.resolveExecutable = { _ in nil }
        }

        func cleanUp() {
            manager.cancelInFlightChatTurn()
            for key in preferenceKeys {
                if let value = preferences[key] { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: root)
        }
    }
}

@MainActor
private final class RoutingClient: ToolCallingConversationClient {
    var model = "mateAgent-routing-test"
    var answer = "Task checked. No changes made."
    struct Request { let systemPrompt: String; let userPrompt: String }
    var requests: [Request] = []
    var usedNativeToolLoop = false

    func analyzeImageStreaming(images: [(data: Data, label: String)], systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)], userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void) async throws -> (text: String, duration: TimeInterval) {
        requests.append(Request(systemPrompt: systemPrompt, userPrompt: userPrompt))
        return (answer, 0)
    }

    func analyzeImageStreaming(images: [(data: Data, label: String)], systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)], userPrompt: String,
        availableTools: [AssistantToolDefinition], onTextChunk: @MainActor @Sendable (String) -> Void,
        onToolCallRequested: @MainActor @Sendable (AssistantToolCall) async -> (text: String, isError: Bool)) async throws -> (text: String, duration: TimeInterval) {
        usedNativeToolLoop = true
        return try await analyzeImageStreaming(images: images, systemPrompt: systemPrompt,
            conversationHistory: conversationHistory, userPrompt: userPrompt, onTextChunk: onTextChunk)
    }
}
