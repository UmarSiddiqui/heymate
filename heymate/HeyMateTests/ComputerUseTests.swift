//
//  ComputerUseTests.swift
//  HeyMateTests
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

@MainActor
@Suite(.serialized)
struct ComputerUseConsentTests {

    @Test func readOnlyActionSkipsApproval() async throws {
        let harness = try ConsentHarness()
        defer { harness.cleanUp() }

        let result = await harness.coordinator.perform(
            .screenshot(displayIndex: nil),
            statedReason: "look"
        )

        #expect(result == ConsentHarness.executedSummary)
        #expect(harness.coordinator.pendingRequest == nil)
        #expect(harness.executor.executionCount == 1)
    }

    @Test func onceGrantDoesNotPersistToTheNextAction() async throws {
        let harness = try ConsentHarness()
        defer { harness.cleanUp() }
        let click = ComputerUseAction.clickElement(label: "Send")

        let first = harness.begin(click, reason: "send it")
        #expect(await harness.waitUntilPending())
        harness.coordinator.approvePendingRequest()
        #expect(await first.value == ConsentHarness.executedSummary)
        #expect(harness.defaults.bool(forKey: ComputerUseCoordinator.alwaysAllowPreferenceKey) == false)

        let second = harness.begin(click, reason: "send it again")
        #expect(await harness.waitUntilPending())
        harness.coordinator.denyPendingRequest()
        #expect(await second.value == ComputerUseCoordinator.inputRefusalMessage)
    }

    @Test func conversationGrantPersistsForTheSameConversation() async throws {
        let harness = try ConsentHarness()
        defer { harness.cleanUp() }
        let chat = UUID()
        harness.coordinator.conversationID = chat
        let click = ComputerUseAction.clickElement(label: "Send")

        let first = harness.begin(click, reason: "send it")
        #expect(await harness.waitUntilPending())
        harness.coordinator.approvePendingRequest(scope: .conversation)
        #expect(await first.value == ConsentHarness.executedSummary)

        let sameChat = harness.begin(.typeText("hello"), reason: "type the greeting")
        #expect(await sameChat.value == ConsentHarness.executedSummary)
        #expect(harness.coordinator.pendingRequest == nil)
        #expect(harness.executor.executionCount == 2)

        harness.coordinator.conversationID = UUID()
        let otherChat = harness.begin(click, reason: "send it elsewhere")
        #expect(await harness.waitUntilPending())
        harness.coordinator.denyPendingRequest()
        _ = await otherChat.value

        harness.coordinator.conversationID = nil
        let noChat = harness.begin(.openApplication(name: "Safari"), reason: "open it")
        #expect(await harness.waitUntilPending())
        harness.coordinator.approvePendingRequest(scope: .conversation)
        #expect(await noChat.value == ConsentHarness.executedSummary)

        let stillAsks = harness.begin(click, reason: "no chat to remember")
        #expect(await harness.waitUntilPending())
        harness.coordinator.denyPendingRequest()
        _ = await stillAsks.value
    }

    @Test func alwaysPreferenceSkipsTheCardWhileEnabled() async throws {
        let harness = try ConsentHarness()
        defer { harness.cleanUp() }
        let click = ComputerUseAction.clickElement(label: "Send")

        let first = harness.begin(click, reason: "send it")
        #expect(await harness.waitUntilPending())
        harness.coordinator.approvePendingRequest(scope: .always)
        #expect(await first.value == ConsentHarness.executedSummary)
        #expect(harness.defaults.bool(forKey: ComputerUseCoordinator.alwaysAllowPreferenceKey))

        let second = harness.begin(.pressKeyCombination("cmd+s"), reason: "save")
        #expect(await second.value == ConsentHarness.executedSummary)
        #expect(harness.coordinator.pendingRequest == nil)
        #expect(harness.executor.executionCount == 2)
    }

    @Test func deniedInputReturnsComputerUseRequest() async throws {
        let harness = try ConsentHarness()
        defer { harness.cleanUp() }

        let task = harness.begin(.typeText("hello"), reason: "say hello")
        #expect(await harness.waitUntilPending())
        harness.coordinator.denyPendingRequest()

        let result = await task.value
        #expect(result == HeyMateMCPServer.computerUseInputRefusal)
        #expect(result.contains("<COMPUTER_USE_REQUEST>"))
        #expect(result.contains("</COMPUTER_USE_REQUEST>"))
        #expect(harness.executor.executionCount == 0)
        #expect(harness.coordinator.pendingRequest == nil)
    }

    @Test func disabledMasterSwitchStillBlocks() async throws {
        let harness = try ConsentHarness()
        defer { harness.cleanUp() }
        harness.defaults.set(true, forKey: ComputerUseCoordinator.alwaysAllowPreferenceKey)
        harness.coordinator.conversationID = UUID()
        harness.coordinator.isEnabled = false

        let result = await harness.coordinator.perform(
            .clickElement(label: "Send"),
            statedReason: "send it"
        )

        #expect(result == "Computer control is switched off. Turn it on in Settings if you want me to click things.")
        #expect(harness.coordinator.pendingRequest == nil)
        #expect(harness.executor.executionCount == 0)
    }
}

@MainActor
private final class RecordingComputerUseExecutor: ComputerUseExecuting {
    var onWillSynthesizeInput: ((CGPoint) -> Void)?
    private(set) var executionCount = 0

    func execute(
        _ request: ComputerUseRequest,
        approval: ComputerUseApprovalToken?
    ) async throws -> ComputerUseOutcome {
        executionCount += 1
        if request.action.risk > .readOnly {
            guard let approval, approval.requestID == request.id else {
                throw ComputerUseError.approvalRequired
            }
        }
        return ComputerUseOutcome(summary: ConsentHarness.executedSummary, payload: nil)
    }
}

@MainActor
private struct ConsentHarness {
    static let executedSummary = "executed"

    let suiteName: String
    let defaults: UserDefaults
    let executor: RecordingComputerUseExecutor
    let coordinator: ComputerUseCoordinator

    init() throws {
        suiteName = "heymate.computerUseConsent.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let executor = RecordingComputerUseExecutor()
        let coordinator = ComputerUseCoordinator(userDefaults: defaults, executor: executor)
        coordinator.isEnabled = true
        coordinator.accessibilityTrustCheck = { true }
        self.defaults = defaults
        self.executor = executor
        self.coordinator = coordinator
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func begin(_ action: ComputerUseAction, reason: String) -> Task<String, Never> {
        let coordinator = coordinator
        return Task { @MainActor in
            await coordinator.perform(action, statedReason: reason)
        }
    }

    func waitUntilPending() async -> Bool {
        for _ in 0..<100 {
            if coordinator.pendingRequest != nil { return true }
            await Task.yield()
        }
        return coordinator.pendingRequest != nil
    }
}
