//
//  ComputerUseTests.swift
//  leanring-buddyTests
//
//  The rules that decide whether HeyMate is allowed to touch the machine.
//  Every assertion here is a safety property, not a formatting detail.
//

import CoreGraphics
import Foundation
import Testing
@testable import HeyMate

@MainActor
struct ComputerUseActionTests {

    @Test func readingTheScreenIsReadOnly() {
        #expect(ComputerUseAction.screenshot(displayIndex: nil).risk == .readOnly)
        #expect(ComputerUseAction.readFocusedWindow.risk == .readOnly)
        #expect(ComputerUseAction.listActionableElements(matching: "send").risk == .readOnly)
    }

    @Test func clickingAndTypingAlwaysCountAsExternalSideEffects() {
        #expect(ComputerUseAction.clickElement(label: "Send").risk == .externalSideEffect)
        #expect(ComputerUseAction.typeText("hello").risk == .externalSideEffect)
        #expect(ComputerUseAction.drag(from: .zero, to: CGPoint(x: 10, y: 10)).risk == .externalSideEffect)
    }

    @Test(arguments: ["cmd+q", "Command+Q", "⌘Q", "cmd+shift+delete", "cmd+w"])
    func destructiveChordsAreClassifiedDestructive(combination: String) {
        #expect(ComputerUseAction.pressKeyCombination(combination).risk == .destructive)
    }

    @Test(arguments: ["cmd+s", "cmd+c", "tab", "cmd+shift+p"])
    func ordinaryChordsAreNotDestructive(combination: String) {
        #expect(ComputerUseAction.pressKeyCombination(combination).risk == .externalSideEffect)
    }

    @Test func keyCombinationNormalizationCollapsesEverySpelling() {
        let expected = "cmd+q"
        #expect(ComputerUseAction.normalizeKeyCombination("Command + Q") == expected)
        #expect(ComputerUseAction.normalizeKeyCombination("⌘Q") == expected)
        #expect(ComputerUseAction.normalizeKeyCombination("CMD+Q") == expected)
    }

    @Test(arguments: [
        "sk-ant-abc123",
        "my password is hunter2",
        "ghp_aaaabbbbcccc",
        "Bearer eyJhbGciOi",
        "API_KEY=xyz"
    ])
    func credentialShapedTextIsRefusedNotApproved(text: String) {
        #expect(ComputerUseAction.typeText(text).isCredentialShaped)
    }

    @Test func ordinaryTextIsNotMistakenForACredential() {
        #expect(!ComputerUseAction.typeText("Thanks, sending this over now.").isCredentialShaped)
    }

    @Test func approvalDescriptionsReadAsPlainSentences() {
        #expect(ComputerUseAction.clickElement(label: "Send").approvalDescription == "Click “Send”")
        #expect(ComputerUseAction.openApplication(name: "Safari").approvalDescription == "Open Safari")
        #expect(ComputerUseAction.scroll(deltaX: 0, deltaY: -120).approvalDescription == "Scroll down")
    }

    @Test func longTypedTextIsTruncatedInTheApprovalSentence() {
        let longText = String(repeating: "a", count: 200)
        let description = ComputerUseAction.typeText(longText).approvalDescription
        #expect(description.contains("…"))
        #expect(description.count < 80)
    }
}

@MainActor
struct ComputerUseTagParserTests {

    @Test func parsesEachSupportedVerb() {
        let text = """
        I'll do that now. [ACT:find:send button] [ACT:click:Send] [ACT:type:Hello there]
        [ACT:key:cmd+s] [ACT:open:Safari] [ACT:scroll:down]
        """
        let actions = ComputerUseTagParser.parseActions(in: text).map(\.action)
        #expect(actions == [
            .listActionableElements(matching: "send button"),
            .clickElement(label: "Send"),
            .typeText("Hello there"),
            .pressKeyCombination("cmd+s"),
            .openApplication(name: "Safari"),
            .scroll(deltaX: 0, deltaY: -ComputerUseTagParser.scrollStepInPixels)
        ])
    }

    @Test func onlyTheFirstColonSeparatesVerbFromArgument() {
        let actions = ComputerUseTagParser.parseActions(in: "[ACT:type:https://example.com/a:b]")
        #expect(actions.first?.action == .typeText("https://example.com/a:b"))
    }

    @Test func unknownVerbsAreLeftAloneRatherThanGuessed() {
        let text = "[ACT:launchNukes:now]"
        #expect(ComputerUseTagParser.parseActions(in: text).isEmpty)
        // Left in the text on purpose: a malformed directive should look
        // wrong rather than silently vanish.
        #expect(ComputerUseTagParser.strippingActionTags(from: text) == text)
    }

    @Test func strippingLeavesOnlyTheProse() {
        let text = "Clicking send for you. [ACT:click:Send]"
        #expect(ComputerUseTagParser.strippingActionTags(from: text) == "Clicking send for you.")
    }

    @Test func unterminatedTagsDoNotHangTheParser() {
        #expect(ComputerUseTagParser.parseActions(in: "half a tag [ACT:click:Send").isEmpty)
    }

    @Test func argumentlessVerbsStillParse() {
        #expect(ComputerUseTagParser.parseActions(in: "[ACT:screenshot]").first?.action
                == .screenshot(displayIndex: nil))
        #expect(ComputerUseTagParser.parseActions(in: "[ACT:read]").first?.action
                == .readFocusedWindow)
    }

    @Test func emptyArgumentsAreRejected() {
        #expect(ComputerUseTagParser.parseActions(in: "[ACT:click:]").isEmpty)
    }
}

@MainActor
struct AccessibilityMatchScoreTests {

    @Test func exactMatchOutranksPrefixOutranksContains() {
        let exact = AccessibilityElementFinder.matchScore(label: "Send", normalizedSearch: "send")
        let prefix = AccessibilityElementFinder.matchScore(label: "Send Later", normalizedSearch: "send")
        let contains = AccessibilityElementFinder.matchScore(label: "Resend Message", normalizedSearch: "send")
        #expect((exact ?? 0) > (prefix ?? 0))
        #expect((prefix ?? 0) > (contains ?? 0))
    }

    @Test func unrelatedLabelsScoreNilSoTheyAreDroppedEntirely() {
        #expect(AccessibilityElementFinder.matchScore(label: "Cancel", normalizedSearch: "send") == nil)
    }

    @Test func sharedWordsStillMatchWhenNeitherStringContainsTheOther() {
        let score = AccessibilityElementFinder.matchScore(
            label: "Reply to message",
            normalizedSearch: "message reply"
        )
        #expect(score != nil)
    }

    @Test func matchingIgnoresCaseAndAccents() {
        #expect(AccessibilityElementFinder.normalize("Envoyér") == AccessibilityElementFinder.normalize("envoyer"))
    }
}
