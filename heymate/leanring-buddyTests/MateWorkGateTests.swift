//
//  MateWorkGateTests.swift
//  leanring-buddyTests
//
//  A follow-up while a plan waits for approval must not start a second run.
//

import Foundation
import Testing
@testable import HeyMate

struct MateWorkGateTests {

    private func run(_ status: AgentRunStatus) -> AgentRun {
        let id = UUID()
        var run = AgentRun.queued(
            id: id,
            title: "count emails",
            prompt: "count emails",
            workspaceURL: URL(fileURLWithPath: "/tmp/\(id.uuidString)", isDirectory: true),
            executor: .claudeCode,
            origin: .sandbox,
            createdAt: Date()
        )
        run.status = status
        return run
    }

    @Test func aPlanWaitingForApprovalBlocksAnotherRun() {
        let mate = UUID()
        let waiting = run(.awaitingPlanApproval)
        let found = MateWorkGate.runAwaitingUser(ownedBy: mate, owners: [waiting.id: mate], runs: [waiting])
        #expect(found?.id == waiting.id)
        #expect(MateWorkGate.reminder(for: waiting).contains("Approve"))
    }

    @Test func aPlanStillBeingWrittenAlsoBlocks() {
        let mate = UUID()
        let planning = run(.planning)
        #expect(MateWorkGate.runAwaitingUser(ownedBy: mate, owners: [planning.id: mate], runs: [planning]) != nil)
    }

    @Test func runningFinishedOrOtherMatesRunsDoNotBlock() {
        let mate = UUID()
        let running = run(.running)
        let done = run(.succeeded)
        let someoneElses = run(.awaitingPlanApproval)
        let owners = [running.id: mate, done.id: mate, someoneElses.id: UUID()]
        #expect(MateWorkGate.runAwaitingUser(ownedBy: mate, owners: owners, runs: [running, done, someoneElses]) == nil)
    }

    @Test func briefSendsEmailToConnectedAppsNotARun() {
        let mate = Mate(
            id: UUID(), name: "Sagely", job: "friend", pinned: false, archived: false,
            unreadCount: 0, createdAt: Date(), updatedAt: Date(), memoryNote: "",
            folderPath: "/tmp/sagely"
        )
        let block = MateAgentBrief.promptBlock(mate: mate, runsCanOperateApps: true)
        #expect(block.contains("for email, calendar"))
        #expect(block.contains("none of your connected apps can reach"))
    }
}

struct ComposioBridgeRepairTests {
    @Test func bridgeIsRepairedOnlyWhenItsKeyAndAppsSurvived() {
        #expect(ConnectorRuntime.composioBridgeIsOrphaned(isEnabled: false, hasStoredKey: true, authorisedToolkitCount: 3))
        // Already on: nothing to repair.
        #expect(!ConnectorRuntime.composioBridgeIsOrphaned(isEnabled: true, hasStoredKey: true, authorisedToolkitCount: 3))
        // Disconnecting deletes the key, so a deliberate disconnect stays off.
        #expect(!ConnectorRuntime.composioBridgeIsOrphaned(isEnabled: false, hasStoredKey: false, authorisedToolkitCount: 3))
        // A key with no authorised apps has nothing to bridge to.
        #expect(!ConnectorRuntime.composioBridgeIsOrphaned(isEnabled: false, hasStoredKey: true, authorisedToolkitCount: 0))
    }
}
