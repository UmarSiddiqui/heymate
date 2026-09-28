//
//  OnDevicePromptFitTests.swift
//  leanring-buddyTests
//
//  The on-device model quits the app if it is handed Apple's private-cloud
//  model, and it throws if a Talk prompt is larger than its context window.
//  These tests lock the clip that keeps the latest user words.
//

import Testing
@testable import HeyMate

struct OnDevicePromptFitTests {

    @Test func keepsTheLatestUserWordsWhenTheContractIsHuge() {
        let system = String(repeating: "rule about honesty. ", count: 2_000)
        let user = "User: what is 2 + 2?"
        let fitted = OnDevicePromptFit.clip(
            systemPrompt: system,
            userPrompt: user,
            characterBudget: 500
        )
        #expect(fitted.prompt.hasSuffix("what is 2 + 2?"))
        #expect(fitted.prompt.count <= 500)
        #expect(fitted.instructions.contains("HeyMate"))
        #expect(!fitted.instructions.contains("rule about honesty"))
    }

    @Test func dropsOlderInstructionsWhenTheUserTurnFillsTheBudget() {
        let user = String(repeating: "a", count: 500)
        let fitted = OnDevicePromptFit.clip(
            systemPrompt: "secret contract text",
            userPrompt: user,
            characterBudget: 500
        )
        #expect(fitted.prompt == user)
        #expect(!fitted.prompt.contains("secret contract"))
    }
}
