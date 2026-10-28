//
//  ComputerUseTakeBackTests.swift
//  HeyMateTests
//
//  The user can always take the wheel back from a drive. These are safety
//  properties: HeyMate's own events never stop it, the person's always do,
//  and nothing runs after a take-back until the next turn.
//

import CoreGraphics
import Foundation
import Testing
@testable import HeyMate

struct ComputerUseTakeBackDecisionTests {

    @Test func synthesizedEventsNeverTakeBack() {
        var travel: CGFloat = 0
        for type in [CGEventType.mouseMoved, .leftMouseDown, .keyDown, .scrollWheel] {
            let input = ComputerUseTakeBack.Input(type: type, isSynthesized: true, delta: CGVector(dx: 400, dy: 0))
            #expect(ComputerUseTakeBack.reason(for: input, pointerTravel: &travel) == nil)
        }
        #expect(travel == 0)
    }

    @Test func escapeAndOtherKeysAreToldApart() {
        var travel: CGFloat = 0
        let escape = ComputerUseTakeBack.Input(type: .keyDown, isSynthesized: false, keyCode: 53)
        let letter = ComputerUseTakeBack.Input(type: .keyDown, isSynthesized: false, keyCode: 0)
        #expect(ComputerUseTakeBack.reason(for: escape, pointerTravel: &travel) == .escape)
        #expect(ComputerUseTakeBack.reason(for: letter, pointerTravel: &travel) == .keyboard)
    }

    @Test func clicksAndScrollsTakeBackAtOnce() {
        var travel: CGFloat = 0
        for type in [CGEventType.leftMouseDown, .rightMouseDown, .scrollWheel] {
            let input = ComputerUseTakeBack.Input(type: type, isSynthesized: false)
            #expect(ComputerUseTakeBack.reason(for: input, pointerTravel: &travel) == .pointer)
        }
    }

    @Test func aBumpIsNotAMoveButSlowTravelAddsUp() {
        var travel: CGFloat = 0
        let nudge = ComputerUseTakeBack.Input(type: .mouseMoved, isSynthesized: false, delta: CGVector(dx: 3, dy: 0))
        #expect(ComputerUseTakeBack.reason(for: nudge, pointerTravel: &travel) == nil)
        #expect(ComputerUseTakeBack.reason(for: nudge, pointerTravel: &travel) == nil)
        #expect(ComputerUseTakeBack.reason(for: nudge, pointerTravel: &travel) == .pointer)
    }
}

@MainActor
@Suite(.serialized)
struct ComputerUseTakeBackCoordinatorTests {

    @Test func takeBackCancelsTheActionInFlightAndRefusesTheRest() async throws {
        let harness = try TakeBackHarness()
        defer { harness.cleanUp() }
        harness.coordinator.beginDrive()
        #expect(harness.watcher.isWatching)

        let typing = Task { @MainActor in
            await harness.coordinator.perform(.typeText("a long sentence"), statedReason: "type it")
        }
        #expect(await harness.waitUntilExecuting())
        harness.watcher.fire(.pointer)

        #expect(await typing.value == ComputerUseTakeBackReason.pointer.modelMessage)
        #expect(harness.executor.finishedCount == 0)
        #expect(harness.coordinator.takeBackReason == .pointer)
        #expect(!harness.watcher.isWatching)

        let next = await harness.coordinator.perform(.clickElement(label: "Send"), statedReason: "send")
        #expect(next == ComputerUseTakeBackReason.pointer.modelMessage)
        #expect(harness.executor.startedCount == 1)
        harness.coordinator.endDrive()
    }

    @Test func nextTurnClearsTheTakeBack() async throws {
        let harness = try TakeBackHarness()
        defer { harness.cleanUp() }
        harness.coordinator.beginDrive()
        harness.coordinator.takeBack(.escape)
        harness.coordinator.endDrive()
        #expect(harness.coordinator.takeBackReason == .escape)

        harness.coordinator.beginTurn()
        harness.executor.blocks = false
        let result = await harness.coordinator.perform(.clickElement(label: "Send"), statedReason: "send")
        #expect(result == TakeBackHarness.executedSummary)
    }

    @Test func outsideADriveNothingIsWatchedOrTakenBack() throws {
        let harness = try TakeBackHarness()
        defer { harness.cleanUp() }
        #expect(!harness.watcher.isWatching)
        harness.coordinator.takeBack(.voice)
        #expect(harness.coordinator.takeBackReason == nil)
    }

    @Test func answeringTheApprovalCardIsNotTakingOver() async throws {
        let harness = try TakeBackHarness(alwaysAllow: false)
        defer { harness.cleanUp() }
        harness.coordinator.beginDrive()
        harness.executor.blocks = false

        let click = Task { @MainActor in
            await harness.coordinator.perform(.clickElement(label: "Send"), statedReason: "send")
        }
        for _ in 0..<100 where harness.coordinator.pendingRequest == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(harness.coordinator.pendingRequest != nil)
        #expect(!harness.watcher.isWatching)

        harness.coordinator.approvePendingRequest()
        #expect(await click.value == TakeBackHarness.executedSummary)
        #expect(harness.watcher.isWatching)
        harness.coordinator.endDrive()
        #expect(!harness.watcher.isWatching)
    }
}

@MainActor
private final class FakeTakeBackWatcher: ComputerUseTakeBackWatching {
    private var onTakeBack: (@MainActor (ComputerUseTakeBackReason) -> Void)?
    var isWatching: Bool { onTakeBack != nil }

    func start(onTakeBack: @escaping @MainActor (ComputerUseTakeBackReason) -> Void) {
        self.onTakeBack = onTakeBack
    }

    func stop() {
        onTakeBack = nil
    }

    func fire(_ reason: ComputerUseTakeBackReason) {
        let handler = onTakeBack
        stop()
        handler?(reason)
    }
}

/// Holds each action open until cancelled, like a long typed sentence.
@MainActor
private final class SlowComputerUseExecutor: ComputerUseExecuting {
    var onWillSynthesizeInput: ((CGPoint) -> Void)?
    var blocks = true
    private(set) var startedCount = 0
    private(set) var finishedCount = 0

    func execute(
        _ request: ComputerUseRequest,
        approval: ComputerUseApprovalToken?
    ) async throws -> ComputerUseOutcome {
        startedCount += 1
        if blocks {
            try await Task.sleep(for: .seconds(30))
        }
        finishedCount += 1
        return ComputerUseOutcome(summary: TakeBackHarness.executedSummary, payload: nil)
    }
}

@MainActor
private struct TakeBackHarness {
    static let executedSummary = "executed"

    let suiteName: String
    let defaults: UserDefaults
    let executor: SlowComputerUseExecutor
    let watcher: FakeTakeBackWatcher
    let coordinator: ComputerUseCoordinator

    init(alwaysAllow: Bool = true) throws {
        suiteName = "heymate.computerUseTakeBack.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(alwaysAllow, forKey: ComputerUseCoordinator.alwaysAllowPreferenceKey)
        let executor = SlowComputerUseExecutor()
        let watcher = FakeTakeBackWatcher()
        let coordinator = ComputerUseCoordinator(userDefaults: defaults, executor: executor, takeBackWatcher: watcher)
        coordinator.isEnabled = true
        coordinator.accessibilityTrustCheck = { true }
        self.defaults = defaults
        self.executor = executor
        self.watcher = watcher
        self.coordinator = coordinator
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func waitUntilExecuting() async -> Bool {
        for _ in 0..<100 {
            if executor.startedCount > 0 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
