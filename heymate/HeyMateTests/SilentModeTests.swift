//
//  SilentModeTests.swift
//  HeyMateTests
//
//  Silent mode must keep every spoken line quiet while it is on, pass speech
//  through untouched while it is off, and be reachable by a typed command.
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct SilentModeTests {

    private final class RecordingTTSClient: TTSClient {
        var spokenTexts: [String] = []
        var stopPlaybackCallCount = 0
        var isPlaying: Bool { false }

        func speakText(_ text: String) async throws {
            spokenTexts.append(text)
        }

        func stopPlayback() {
            stopPlaybackCallCount += 1
        }
    }

    @Test func speechIsSwallowedWhileSilentModeIsOn() async throws {
        let recordingClient = RecordingTTSClient()
        let silentClient = SilentModeAwareTTSClient(wrapping: recordingClient, isSilentModeEnabled: { true })

        try await silentClient.speakText("hello")

        #expect(recordingClient.spokenTexts.isEmpty)
    }

    @Test func speechPassesThroughWhileSilentModeIsOff() async throws {
        let recordingClient = RecordingTTSClient()
        let silentClient = SilentModeAwareTTSClient(wrapping: recordingClient, isSilentModeEnabled: { false })

        try await silentClient.speakText("hello")

        #expect(recordingClient.spokenTexts == ["hello"])
    }

    @Test func togglingTakesEffectWithoutRebuildingTheClient() async throws {
        let recordingClient = RecordingTTSClient()
        var isSilent = false
        let silentClient = SilentModeAwareTTSClient(wrapping: recordingClient, isSilentModeEnabled: { isSilent })

        try await silentClient.speakText("first")
        isSilent = true
        try await silentClient.speakText("second")

        #expect(recordingClient.spokenTexts == ["first"])
    }

    @Test func stopPlaybackAlwaysReachesTheWrappedClient() {
        let recordingClient = RecordingTTSClient()
        let silentClient = SilentModeAwareTTSClient(wrapping: recordingClient, isSilentModeEnabled: { true })

        silentClient.stopPlayback()

        #expect(recordingClient.stopPlaybackCallCount == 1)
    }

    @Test func preferenceDefaultsToOffAndPersists() {
        UserDefaults.standard.removeObject(forKey: SilentModePreferences.userDefaultsKey)
        #expect(SilentModePreferences.isEnabled == false)

        SilentModePreferences.isEnabled = true
        #expect(UserDefaults.standard.bool(forKey: SilentModePreferences.userDefaultsKey) == true)

        UserDefaults.standard.removeObject(forKey: SilentModePreferences.userDefaultsKey)
    }

    @Test func silentModeSwapsTheVoiceStyleForAReadingStyle() {
        let voicePrompt = CompanionManager.companionResponseSystemPrompt(isSilentModeEnabled: false)
        let readingPrompt = CompanionManager.companionResponseSystemPrompt(isSilentModeEnabled: true)

        #expect(voicePrompt.contains("spoken aloud via text-to-speech"))
        #expect(!readingPrompt.contains("spoken aloud via text-to-speech"))
        #expect(readingPrompt.contains("fenced code block"))
        // Pointing and drawing must survive in both styles.
        #expect(voicePrompt.contains("[POINT:x,y:label]"))
        #expect(readingPrompt.contains("[POINT:x,y:label]"))
        #expect(voicePrompt.contains(#""op":"target""#))
        #expect(readingPrompt.contains(#""op":"target""#))
    }

    @Test func aLiveTalkTurnCarriesTheStyleUnlessNobodyIsListening() {
        #expect(CompanionPrompts.talkStyle(isSilentModeEnabled: false, isUnattended: false) == CompanionPrompts.voiceStyle)
        #expect(CompanionPrompts.talkStyle(isSilentModeEnabled: true, isUnattended: false) == CompanionPrompts.readingStyle)
        #expect(CompanionPrompts.talkStyle(isSilentModeEnabled: false, isUnattended: true) == nil)
    }

    /// Every drawing the prompts show the model must be one the compiler accepts.
    @Test func everyDrawingExampleInThePromptsCompiles() throws {
        let prompt = CompanionPrompts.response(isSilentModeEnabled: false)
        let blocks = prompt.components(separatedBy: ExplanationProgram.fence).dropFirst()
        #expect(blocks.count >= 4)
        for block in blocks {
            let compiled = try #require(ExplanationProgram.compile(ExplanationProgram.fence + block))
            #expect(compiled.error == nil)
            #expect(compiled.closed)
            #expect(!compiled.lines.isEmpty)
        }
    }

    @Test func aModelWrittenScriptIsSpokenButNeverRun() {
        let js = "sure.\n```js\nstep(1); say('hello there.')\nfetch('https://example.com')\n```"
        let untrusted = GuidedReplyParser.parse(js)
        #expect(untrusted.explainerProgram == nil)
        #expect(untrusted.steps.contains { $0.text.contains("hello there") })
        #expect(GuidedReplyParser.parse(js, trustedProgram: true).explainerProgram != nil)
        let data = ExplanationProgram.fence + #"{"id":"a","say":"Look here.","ops":[{"op":"point","args":[10,10,"spot"]}]}"# + "\n```"
        #expect(GuidedReplyParser.parse(data).explainerProgram != nil)
    }

    @Test func aFlowArrowIsAPartTheCompilerAccepts() throws {
        let reply = ExplanationProgram.fence + #"""
        {"id":"a","say":"Air moves through.","ops":[{"op":"figure","id":"f","args":[10,10,400,300,{"spin":0.3}]},{"op":"part","figure":"f","id":"air","kind":"arrow","options":{"points":[[-1,0,0],[1,0,0]],"r":0.03,"mat":"glow:orange"}}]}
        """# + "\n```"
        let compiled = try #require(ExplanationProgram.compile(reply))
        #expect(compiled.error == nil)
        #expect(compiled.source.contains(".arrow("))
    }

    @Test func speakersOfferOnlyWhenEveryConditionHolds() {
        #expect(SilentModePreferences.shouldOfferSilentMode(
            isSilentModeEnabled: false, isSuggestionDismissed: false,
            hasOfferedThisSession: false, isPlayingThroughBuiltInSpeakers: true
        ))
        #expect(!SilentModePreferences.shouldOfferSilentMode(
            isSilentModeEnabled: false, isSuggestionDismissed: false,
            hasOfferedThisSession: false, isPlayingThroughBuiltInSpeakers: false
        ))
        #expect(!SilentModePreferences.shouldOfferSilentMode(
            isSilentModeEnabled: true, isSuggestionDismissed: false,
            hasOfferedThisSession: false, isPlayingThroughBuiltInSpeakers: true
        ))
        #expect(!SilentModePreferences.shouldOfferSilentMode(
            isSilentModeEnabled: false, isSuggestionDismissed: true,
            hasOfferedThisSession: false, isPlayingThroughBuiltInSpeakers: true
        ))
        #expect(!SilentModePreferences.shouldOfferSilentMode(
            isSilentModeEnabled: false, isSuggestionDismissed: false,
            hasOfferedThisSession: true, isPlayingThroughBuiltInSpeakers: true
        ))
    }

    @Test func slashSilentAndQuietResolveToTheToggle() {
        #expect(CommandBarParser.parse("/silent") == .slashCommand(.silent, argument: ""))
        #expect(CommandBarParser.parse("/quiet") == .slashCommand(.silent, argument: ""))
    }
}
