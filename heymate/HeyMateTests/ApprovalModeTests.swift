//
//  ApprovalModeTests.swift
//  HeyMateTests
//
//  Full access stops the routine cards; the floor (sending, deleting,
//  money, credentials, destructive keys) asks in every mode.
//

import CoreGraphics
import Foundation
import Testing
@testable import HeyMate

struct ApprovalModeTests {

    @Test func askMeIsTheDefaultAndKeepsTheChosenConnectorPolicy() {
        let defaults = UserDefaults(suiteName: "heymate.approvalMode.\(UUID().uuidString)")!
        #expect(ApprovalMode.current(defaults) == .askMe)
        #expect(ApprovalMode.askMe.connectorPolicy(.askAlways) == .askAlways)
        #expect(!ApprovalMode.askMe.skipsComputerUseApproval(for: .externalSideEffect))
        #expect(!ApprovalMode.askMe.autoApprovesPlan("Rename the files in output/"))
    }

    @Test func fullAccessLiftsWritesButNotSendsOrDeletes() {
        let policy = ApprovalMode.fullAccess.connectorPolicy(.askAlways)
        #expect(!policy.requiresApproval(forRisk: .readOnly))
        #expect(!policy.requiresApproval(forRisk: .reversibleWrite))
        #expect(policy.requiresApproval(forRisk: .externalSideEffect))
        #expect(policy.requiresApproval(forRisk: .destructive))
    }

    @Test func fullAccessComputerUseStopsShortOfDestructiveKeys() {
        let mode = ApprovalMode.fullAccess
        #expect(mode.skipsComputerUseApproval(for: ComputerUseAction.clickElement(label: "Next").risk))
        #expect(mode.skipsComputerUseApproval(for: ComputerUseAction.typeText("hello").risk))
        #expect(!mode.skipsComputerUseApproval(for: ComputerUseAction.pressKeyCombination("cmd+q").risk))
    }

    @Test(arguments: [
        ("1. Draft the reply and send it to Sam", "sends something"),
        ("Remove the old build folder", "deletes something"),
        ("Run git push --force on main", "deletes something"),
        ("Buy the domain on Namecheap", "handles money or credentials"),
        ("Read the API token from .env", "handles money or credentials"),
    ])
    func plansThatTouchTheFloorStillAsk(plan: String, reason: String) {
        #expect(ApprovalFloor.reasonPlanNeedsHuman(plan) == reason)
        #expect(!ApprovalMode.fullAccess.autoApprovesPlan(plan))
    }

    @Test(arguments: [
        "1. Read invoices.csv\n2. Write a summary to output/summary.md",
        "Update the display settings copy and the payload parser",
        "Rename sections in the landing page draft",
    ])
    func ordinaryPlansStartOnTheirOwn(plan: String) {
        #expect(ApprovalFloor.reasonPlanNeedsHuman(plan) == nil)
        #expect(ApprovalMode.fullAccess.autoApprovesPlan(plan))
    }
}

@MainActor
@Suite(.serialized)
struct ApprovalModeComputerUseTests {

    @Test func fullAccessRunsClicksWithoutACardButDestructiveKeysStillAsk() async throws {
        let suite = "heymate.approvalModeCU.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(ApprovalMode.fullAccess.rawValue, forKey: ApprovalMode.preferenceKey)
        let coordinator = ComputerUseCoordinator(
            userDefaults: defaults, executor: CountingExecutor(), takeBackWatcher: IdleWatcher())
        coordinator.isEnabled = true
        coordinator.accessibilityTrustCheck = { true }

        let click = await coordinator.perform(.clickElement(label: "Next"), statedReason: "next page")
        #expect(click == "executed")
        #expect(coordinator.pendingRequest == nil)

        let quit = Task { @MainActor in
            await coordinator.perform(.pressKeyCombination("cmd+q"), statedReason: "quit")
        }
        for _ in 0..<100 where coordinator.pendingRequest == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.pendingRequest != nil)
        coordinator.denyPendingRequest()
        _ = await quit.value
    }

    @Test func alwaysAllowNoLongerCoversDestructiveKeys() async throws {
        let suite = "heymate.approvalModeAlways.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ComputerUseCoordinator.alwaysAllowPreferenceKey)
        let coordinator = ComputerUseCoordinator(
            userDefaults: defaults, executor: CountingExecutor(), takeBackWatcher: IdleWatcher())
        coordinator.isEnabled = true
        coordinator.accessibilityTrustCheck = { true }

        let close = Task { @MainActor in
            await coordinator.perform(.pressKeyCombination("cmd+w"), statedReason: "close")
        }
        for _ in 0..<100 where coordinator.pendingRequest == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.pendingRequest != nil)
        coordinator.denyPendingRequest()
        #expect(await close.value == ComputerUseCoordinator.inputRefusalMessage)
    }
}

@MainActor
private final class CountingExecutor: ComputerUseExecuting {
    var onWillSynthesizeInput: ((CGPoint) -> Void)?
    func execute(_ request: ComputerUseRequest, approval: ComputerUseApprovalToken?) async throws -> ComputerUseOutcome {
        ComputerUseOutcome(summary: "executed", payload: nil)
    }
}

@MainActor
private final class IdleWatcher: ComputerUseTakeBackWatching {
    func start(onTakeBack: @escaping @MainActor (ComputerUseTakeBackReason) -> Void) {}
    func stop() {}
}
