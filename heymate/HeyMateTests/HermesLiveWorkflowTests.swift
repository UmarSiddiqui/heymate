import Foundation
import Testing
@testable import HeyMate

/// Opt-in local integration: actual manager/transcript path, model tools, file
/// artifact, backend restart, reopened chat and revision. No real screen/audio
/// is captured. Hardware microphone/TTS still require manual app verification.
@MainActor
@Suite(.serialized)
struct HermesLiveWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEYMATE_HERMES_WORKFLOW_LIVE_EXECUTABLE"] != nil
                   && ProcessInfo.processInfo.environment["HEYMATE_HERMES_WORKFLOW_LIVE_PROFILE"] != nil))
    func createsPageThroughNativeManagerThenReopensAndRevisesSameArtifact() async throws {
        try #require(HeyMateDataDirectory.isHostingTests, "Live fixture requires scratch-data protection")
        let env = ProcessInfo.processInfo.environment
        let executable = try #require(env["HEYMATE_HERMES_WORKFLOW_LIVE_EXECUTABLE"])
        let profile = try #require(env["HEYMATE_HERMES_WORKFLOW_LIVE_PROFILE"])
        let keys = [MateEngine.preferenceKey, HermesEngineConfiguration.executablePathKey,
                    HermesEngineConfiguration.profilePathKey, HermesEngineConfiguration.runtimePathKey,
                    "rememberConversations", SilentModePreferences.userDefaultsKey,
                    "selectedVoiceSpeakProvider", "selectedVoiceListenProvider", "selectedAgentBrain",
                    "defaultHeadlessExecutor", "chatConnectorExclusions"]
        let preferences = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            UserDefaults.standard.object(forKey: key).map { (key, $0) }
        })
        defer {
            HermesServeBackend.shared.stop()
            for key in keys {
                if let value = preferences[key] { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        UserDefaults.standard.set(MateEngine.hermes.rawValue, forKey: MateEngine.preferenceKey)
        UserDefaults.standard.set(executable, forKey: HermesEngineConfiguration.executablePathKey)
        UserDefaults.standard.set(profile, forKey: HermesEngineConfiguration.profilePathKey)
        UserDefaults.standard.set(env["HEYMATE_HERMES_WORKFLOW_LIVE_RUNTIME"] ?? "", forKey: HermesEngineConfiguration.runtimePathKey)
        UserDefaults.standard.set(true, forKey: "rememberConversations")
        UserDefaults.standard.set(true, forKey: SilentModePreferences.userDefaultsKey)
        UserDefaults.standard.set("macos", forKey: "selectedVoiceSpeakProvider")
        UserDefaults.standard.set("apple", forKey: "selectedVoiceListenProvider")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heymate-manager-live-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Keep successful fixture artifacts for review; no user files are touched.
        let chats = FileChatHistoryStore(fileURL: root.appendingPathComponent("chats.json"))
        func manager() -> CompanionManager {
            CompanionManager(
                memoryRepository: FileMemoryRepository(fileURL: root.appendingPathComponent("memory.json")),
                chatHistoryStore: chats,
                agentRunStore: FileAgentRunStore(fileURL: root.appendingPathComponent("runs.json")),
                standingOrderRepository: FileStandingOrderRepository(directoryURL: root.appendingPathComponent("orders")),
                agentUndoLedger: FileAgentUndoLedger(rootDirectoryURL: root.appendingPathComponent("undo"), recoverPreparedEntriesOnInit: false),
                mateStore: FileMateStore(fileURL: root.appendingPathComponent("mates.json")),
                routineStore: FileMateRoutineStore(fileURL: root.appendingPathComponent("routines.json"))
            )
        }
        let first = manager()
        first.rememberConversationsEnabled = true
        let chatID = first.currentChat.id
        let marker = "Cedar workshop \(Int.random(in: 100_000...999_999))"
        first.sendTranscriptToClaudeWithScreenshot(transcript:
            "Use your file tools to create a tiny complete self-contained HTML page named landing.html in your current workspace. Its h1 must say \(marker). Keep all work in this workspace. Do not use network, screenshots, install dependencies, or access other files. Return its absolute file path when done.",
            shouldCaptureScreen: false)
        let firstTask = try #require(first.currentResponseTask)
        await firstTask.value
        let workspace = try HermesChatSessionStore(root: HeyMateDataDirectory.url.appendingPathComponent("hermes-serve"))
            .workspace(chatID: chatID)
        let artifact = workspace.appendingPathComponent("landing.html")
        #expect(try String(contentsOf: artifact, encoding: .utf8).contains(marker))
        #expect(first.hermesActivity.contains { $0.text.contains("tool") })
        #expect(first.currentChat.messages.last?.role == .assistant)
        #expect(first.currentChat.messages.last?.taskResultKey?.hasPrefix("hermes-serve:") == true)
        #expect(first.agentRuns.isEmpty)
        let originalSession = try HermesChatSessionStore(root: HeyMateDataDirectory.url.appendingPathComponent("hermes-serve"))
            .sessionID(chatID: chatID, profile: URL(fileURLWithPath: profile))
        #expect(originalSession != nil)
        #expect(await HermesServeBackend.shared.shutdown())
        first.stop()
        let reopened = manager()
        reopened.rememberConversationsEnabled = true
        reopened.openChat(id: chatID)
        #expect(reopened.currentChat.id == chatID)
        #expect(reopened.currentChat.messages.contains { $0.role == .assistant })
        reopened.sendTranscriptToClaudeWithScreenshot(transcript:
            "Revise the same HTML page you created in our last turn. Keep the filename and location unchanged. Change its h1 to \(marker) revised. Keep all work in this workspace; no network or installs. Return the absolute path after checking the file.",
            shouldCaptureScreen: false)
        let secondTask = try #require(reopened.currentResponseTask)
        await secondTask.value
        #expect(try String(contentsOf: artifact, encoding: .utf8).contains(marker + " revised"))
        let resumedSession = try HermesChatSessionStore(root: HeyMateDataDirectory.url.appendingPathComponent("hermes-serve"))
            .sessionID(chatID: chatID, profile: URL(fileURLWithPath: profile))
        #expect(resumedSession == originalSession)
        #expect(reopened.currentChat.messages.filter { $0.role == .assistant }.count == 2)
        #expect(reopened.agentRuns.isEmpty)
        #expect(!reopened.isHermesTurnInFlight)
        reopened.stop()
        #expect(await HermesServeBackend.shared.shutdown())
        print("Hermes native workflow fixture: \(root.path)")
        print("Hermes native workflow artifact: \(artifact.path)")
    }
}
