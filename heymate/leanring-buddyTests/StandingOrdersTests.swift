//
//  StandingOrdersTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct StandingOrderMarkdownTests {

    @Test func parsesUserOwnedRuleAndKeepsPreplanningOffByDefault() {
        let sourceURL = URL(fileURLWithPath: "/tmp/copied-figma.md")
        let parsed = StandingOrderMarkdownParser.parse(
            contents: """
            ---
            name: Offer Figma scaffold
            signal: clipboard
            contains: figma.com, figma.design
            task: Scaffold the copied design.
            enabled: true
            cooldown-minutes: 90
            ---
            Notes for the user.
            """,
            sourceURL: sourceURL
        )

        #expect(parsed?.id == "copied-figma")
        #expect(parsed?.signalKind == .clipboard)
        #expect(parsed?.containsAny == ["figma.com", "figma.design"])
        #expect(parsed?.task == "Scaffold the copied design.")
        #expect(parsed?.cooldownMinutes == 90)
        #expect(parsed?.minimumMatchMinutes == 0)
        #expect(parsed?.preplanEnabled == false)
    }

    @Test func rejectsRuleWithoutExplicitTaskOrMatchText() {
        let sourceURL = URL(fileURLWithPath: "/tmp/incomplete.md")
        #expect(StandingOrderMarkdownParser.parse(
            contents: """
            ---
            name: Incomplete
            signal: clipboard
            ---
            """,
            sourceURL: sourceURL
        ) == nil)
    }
}

struct StandingOrderMatcherTests {

    private let order = StandingOrder(
        id: "figma",
        name: "Figma",
        signalKind: .clipboard,
        containsAny: ["figma.com"],
        task: "Scaffold it",
        enabled: true,
        cooldownMinutes: 60,
        minimumMatchMinutes: 0,
        preplanEnabled: false,
        sourcePath: "/tmp/figma.md"
    )

    @Test func signalKindAndContentMustBothMatch() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let clipboardSignal = StandingOrderSignal(
            kind: .clipboard,
            value: "https://www.figma.com/design/abc",
            observedAt: now
        )
        let appSignal = StandingOrderSignal(kind: .frontmostApp, value: "Figma", observedAt: now)

        #expect(StandingOrderMatcher.firstMatch(
            for: clipboardSignal,
            in: [order],
            lastTriggeredAt: [:],
            now: now
        ) == order)
        #expect(StandingOrderMatcher.firstMatch(
            for: appSignal,
            in: [order],
            lastTriggeredAt: [:],
            now: now
        ) == nil)
    }

    @Test func cooldownSuppressesRepeatedNudges() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let signal = StandingOrderSignal(kind: .clipboard, value: "figma.com", observedAt: now)
        #expect(StandingOrderMatcher.firstMatch(
            for: signal,
            in: [order],
            lastTriggeredAt: [order.id: now.addingTimeInterval(-30 * 60)],
            now: now
        ) == nil)
        #expect(StandingOrderMatcher.firstMatch(
            for: signal,
            in: [order],
            lastTriggeredAt: [order.id: now.addingTimeInterval(-61 * 60)],
            now: now
        ) == order)
    }
}

struct StandingOrderDurationAndVoiceTests {
    private let delayedOrder = StandingOrder(
        id: "failing-test",
        name: "Failing test",
        signalKind: .screenText,
        containsAny: ["test failed"],
        task: "Fix failing test",
        enabled: true,
        cooldownMinutes: 60,
        minimumMatchMinutes: 10,
        preplanEnabled: false,
        sourcePath: "/tmp/failing-test.md"
    )

    @Test func durationGateWaitsForContinuousMatch() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let signal = StandingOrderSignal(kind: .screenText, value: "TEST FAILED", observedAt: start)
        var evaluator = StandingOrderEvaluator()
        #expect(evaluator.firstReadyMatch(for: signal, in: [delayedOrder], lastTriggeredAt: [:], now: start) == nil)
        #expect(evaluator.firstReadyMatch(
            for: signal,
            in: [delayedOrder],
            lastTriggeredAt: [:],
            now: start.addingTimeInterval(599)
        ) == nil)
        #expect(evaluator.firstReadyMatch(
            for: signal,
            in: [delayedOrder],
            lastTriggeredAt: [:],
            now: start.addingTimeInterval(600)
        ) == delayedOrder)
    }

    @Test func explicitSpokenRuleParsesWithoutModelCall() {
        let instruction = StandingOrderVoiceInstruction.parse(
            "standing order, when clipboard contains figma.com, offer to scaffold copied design"
        )
        #expect(instruction?.signalKind == .clipboard)
        #expect(instruction?.contains == "figma.com")
        #expect(instruction?.task == "scaffold copied design")
        #expect(StandingOrderVoiceInstruction.parse("build a website") == nil)
    }
}

@MainActor
struct AgentUndoLedgerTests {

    @Test func undoRestoresPriorBytesAndRemovesAgentCreatedFiles() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-undo-test-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = temporaryRoot.appendingPathComponent("workspace", isDirectory: true)
        let ledgerURL = temporaryRoot.appendingPathComponent("ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let originalFileURL = workspaceURL.appendingPathComponent("index.html")
        try "before".write(to: originalFileURL, atomically: true, encoding: .utf8)

        let run = AgentRun.queued(
            id: UUID(),
            title: "Change site",
            prompt: "Change site",
            workspaceURL: workspaceURL,
            executor: .claudeCode,
            origin: .sandbox,
            sessionIdentifier: UUID().uuidString
        )
        let ledger = FileAgentUndoLedger(rootDirectoryURL: ledgerURL)
        let entry = try ledger.prepareSnapshot(for: run)

        try "after".write(to: originalFileURL, atomically: true, encoding: .utf8)
        let createdFileURL = workspaceURL.appendingPathComponent("new.css")
        try "new".write(to: createdFileURL, atomically: true, encoding: .utf8)
        ledger.markReady(entryID: entry.id)

        let restored = try ledger.undo(entryID: entry.id)

        #expect(try String(contentsOf: originalFileURL, encoding: .utf8) == "before")
        #expect(FileManager.default.fileExists(atPath: createdFileURL.path) == false)
        #expect(restored.status == .undone)
        #expect(!restored.recoveryPath.isEmpty)
        #expect(FileManager.default.fileExists(atPath: restored.recoveryPath))
        #expect(ledger.latestReadyEntry() == nil)
    }

    @Test func snapshotRefusesAWorkspaceContainingTheLedger() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-undo-recursion-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = temporaryRoot.appendingPathComponent("workspace", isDirectory: true)
        let ledgerURL = workspaceURL.appendingPathComponent("undo-ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let run = AgentRun.queued(
            id: UUID(),
            title: "Unsafe snapshot",
            prompt: "Unsafe snapshot",
            workspaceURL: workspaceURL,
            executor: .claudeCode,
            origin: .attached,
            sessionIdentifier: UUID().uuidString
        )
        let ledger = FileAgentUndoLedger(rootDirectoryURL: ledgerURL)

        #expect(throws: AgentUndoLedgerError.self) {
            _ = try ledger.prepareSnapshot(for: run)
        }
    }
}
