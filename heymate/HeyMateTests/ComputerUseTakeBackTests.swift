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
        var shake = PointerShakeDetector()
        for type in [CGEventType.mouseMoved, .leftMouseDown, .keyDown, .scrollWheel] {
            let input = ComputerUseTakeBack.Input(type: type, isSynthesized: true, delta: CGVector(dx: 400, dy: 0))
            #expect(ComputerUseTakeBack.reason(for: input, shake: &shake) == nil)
        }
    }

    @Test func escapeAndOtherKeysAreToldApart() {
        var shake = PointerShakeDetector()
        let escape = ComputerUseTakeBack.Input(type: .keyDown, isSynthesized: false, keyCode: 53)
        let letter = ComputerUseTakeBack.Input(type: .keyDown, isSynthesized: false, keyCode: 0)
        #expect(ComputerUseTakeBack.reason(for: escape, shake: &shake) == .escape)
        #expect(ComputerUseTakeBack.reason(for: letter, shake: &shake) == .keyboard)
    }

    @Test func clicksAndScrollsTakeBackAtOnce() {
        var shake = PointerShakeDetector()
        for type in [CGEventType.leftMouseDown, .rightMouseDown, .scrollWheel] {
            let input = ComputerUseTakeBack.Input(type: type, isSynthesized: false)
            #expect(ComputerUseTakeBack.reason(for: input, shake: &shake) == .pointer)
        }
    }

    @Test func ordinaryMovesNeverTakeBackButAShakeDoes() {
        var shake = PointerShakeDetector()
        // A long, steady move across the screen is just the person working.
        for step in 0..<100 {
            let move = ComputerUseTakeBack.Input(type: .mouseMoved, isSynthesized: false, delta: CGVector(dx: 20, dy: 3), time: Double(step) * 0.01)
            #expect(ComputerUseTakeBack.reason(for: move, shake: &shake) == nil)
        }
        // Left, right, left, right in quick strokes is a shake.
        var reasons: [ComputerUseTakeBackReason?] = []
        for (stroke, direction) in [-1.0, 1, -1, 1].enumerated() {
            for step in 0..<5 {
                let time = 2 + Double(stroke) * 0.1 + Double(step) * 0.02
                let move = ComputerUseTakeBack.Input(type: .mouseMoved, isSynthesized: false, delta: CGVector(dx: 20 * direction, dy: 0), time: time)
                reasons.append(ComputerUseTakeBack.reason(for: move, shake: &shake))
            }
        }
        #expect(reasons.contains(.pointer))
    }
}

struct PointerShakeDetectorTests {
    private func strokes(_ directions: [CGFloat], length: CGFloat, every gap: TimeInterval, into shake: inout PointerShakeDetector) -> Bool {
        var shook = false
        for (index, direction) in directions.enumerated() {
            shook = shake.observe(CGVector(dx: length * direction, dy: 0), at: Double(index) * gap) || shook
        }
        return shook
    }

    @Test func jitterAndSlowBackAndForthAreNotShakes() {
        var jitter = PointerShakeDetector()
        #expect(!strokes([1, -1, 1, -1, 1, -1, 1, -1], length: 6, every: 0.02, into: &jitter))
        var slow = PointerShakeDetector()
        #expect(!strokes([1, -1, 1, -1], length: 100, every: 0.5, into: &slow))
    }

    @Test func quickReversalsOnEitherAxisAreAShake() {
        var horizontal = PointerShakeDetector()
        #expect(strokes([1, -1, 1, -1], length: 80, every: 0.1, into: &horizontal))
        var vertical = PointerShakeDetector()
        var shook = false
        for (index, direction) in [1.0, -1, 1, -1].enumerated() {
            shook = vertical.observe(CGVector(dx: 0, dy: 80 * direction), at: Double(index) * 0.1) || shook
        }
        #expect(shook)
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
