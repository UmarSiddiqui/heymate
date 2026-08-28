//
//  VoiceRouterTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct VoiceRouterTests {

    @Test func openSafariAndVolumeUpAreLocalFastPath() {
        #expect(VoiceRouter.decide("open Safari") == .local(.openApp(name: "safari")))
        #expect(VoiceRouter.decide("ok heymate, volume up") == .local(.volumeUp))
        #expect(VoiceRouter.decide("turn it down") == .local(.volumeDown))
        #expect(VoiceRouter.decide("set volume to 40") == .local(.setVolume(percent: 40)))
    }

    /// Pointing at what is visible with nothing durable named. No folder in
    /// it, so no agent, so no round trip.
    @Test func referentialOpenStaysTalkForFree() {
        #expect(VoiceRouter.decide("open this") == .talk)
        #expect(VoiceRouter.decide("read that out") == .talk)
    }

    /// The single most common thing said to this app. Sending it to a
    /// classifier would add half a second to almost every turn.
    @Test func screenQuestionsCostNothing() {
        #expect(VoiceRouter.decide("what's on my screen") == .talk)
        #expect(VoiceRouter.decide("what does this error mean") == .talk)
        #expect(VoiceRouter.decide("explain this to me") == .talk)
        #expect(VoiceRouter.decide("why is that window blank") == .talk)
    }

    /// Saying the word is the user having already decided.
    @Test func anExplicitPrefixSkipsTheClassifier() {
        #expect(VoiceRouter.decide("agent, inspect the repo") == .agent)
        #expect(VoiceRouter.decide("heymate agent, tidy my notes") == .agent)
    }

    /// The whole point of phase 3: these used to fall through to Talk, which
    /// has no filesystem, refused, and looked like the agent did not exist.
    @Test func theAmbiguousRemainderGoesToTheModel() {
        #expect(VoiceRouter.decide("clean up my Downloads folder") == .needsClassification)
        #expect(VoiceRouter.decide("draft the reply to Sam") == .needsClassification)
        #expect(VoiceRouter.decide("find thirty micro influencers and put them in a sheet") == .needsClassification)
        #expect(VoiceRouter.decide("build a landing page") == .needsClassification)
        #expect(VoiceRouter.decide("open a landing page") == .needsClassification)
    }

    /// When the classifier is unreachable the app must route exactly as well
    /// as it did before, never worse.
    @Test func theOfflineFloorIsTheOldBehaviour() {
        #expect(VoiceRouter.fallbackDecision("build a landing page") == .agent)
        #expect(VoiceRouter.fallbackDecision("agent, do a thing") == .agent)
        #expect(VoiceRouter.fallbackDecision("clean up my Downloads folder") == .talk)
    }

    @Test func destructiveRequestsAreNotSilentAgentLaunches() {
        #expect(VoiceRouter.decide("delete all files") == .confirmDestructive)
        #expect(VoiceRouter.decide("wipe the keychain") == .confirmDestructive)
        #expect(VoiceRouter.decide("agent, delete the leftover folder") == .agent)
    }

    /// Checked before the screen-question shortcut: this sentence satisfies
    /// both, and the background half is the part that would be lost.
    @Test func hybridIsObservedNotAutoLaunched() {
        let decision = VoiceRouter.decide("what is this error and also fix it in the background")
        #expect(decision == .hybrid)
    }

    @Test func agentWorkPredicatesStayIsolated() {
        #expect(VoiceRouter.containsAgentWorkAction("please inspect the logs"))
        #expect(VoiceRouter.containsDurableWorkTarget("the github repo"))
        #expect(VoiceRouter.looksLikeAgentWork("inspect the github repo"))
        #expect(VoiceRouter.isSensitiveOrDestructiveAgentTaskRequest("delete all files"))
        #expect(!VoiceRouter.isSensitiveOrDestructiveAgentTaskRequest("delete this extra blank line"))
    }
}
