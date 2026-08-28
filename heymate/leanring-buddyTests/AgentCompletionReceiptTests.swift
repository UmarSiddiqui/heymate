//
//  AgentCompletionReceiptTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct AgentWorkspaceChangeScannerTests {
    @Test func hashesContentAndExcludesGeneratedTreesWhileCappingOnlyDisplayPaths() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentWorkspaceChangeScannerTests-\(UUID().uuidString)", isDirectory: true)
        let beforeURL = rootURL.appendingPathComponent("before", isDirectory: true)
        let currentURL = rootURL.appendingPathComponent("current", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try write("same", to: beforeURL.appendingPathComponent("Sources/Stable.swift"))
        try write("before", to: beforeURL.appendingPathComponent("Sources/Changed.swift"))
        try write("deleted", to: beforeURL.appendingPathComponent("Notes/Deleted.md"))
        try write("ignored before", to: beforeURL.appendingPathComponent(".git/config"))
        try write("ignored before", to: beforeURL.appendingPathComponent("node_modules/pkg/index.js"))
        try write("ignored before", to: beforeURL.appendingPathComponent("DerivedData/cache/item"))
        try write("ignored before", to: beforeURL.appendingPathComponent("build/output.o"))
        try write("ignored before", to: beforeURL.appendingPathComponent(".build/output.o"))

        try write("same", to: currentURL.appendingPathComponent("Sources/Stable.swift"))
        // Same byte count as the baseline proves timestamps and sizes are not
        // being mistaken for content identity.
        try write("after!", to: currentURL.appendingPathComponent("Sources/Changed.swift"))
        try write("added", to: currentURL.appendingPathComponent("Sources/Added.swift"))
        try write("ignored after", to: currentURL.appendingPathComponent(".git/config"))
        try write("ignored after", to: currentURL.appendingPathComponent("node_modules/pkg/index.js"))
        try write("ignored after", to: currentURL.appendingPathComponent("DerivedData/cache/item"))
        try write("ignored after", to: currentURL.appendingPathComponent("build/output.o"))
        try write("ignored after", to: currentURL.appendingPathComponent(".build/output.o"))

        let summary = try AgentWorkspaceChangeScanner.scan(
            beforeSnapshotURL: beforeURL,
            currentWorkspaceURL: currentURL,
            maximumDisplayedPaths: 2
        )

        #expect(summary.addedCount == 1)
        #expect(summary.modifiedCount == 1)
        #expect(summary.deletedCount == 1)
        #expect(summary.totalCount == 3)
        #expect(summary.displayedChanges.count == 2)
        #expect(summary.omittedDisplayPathCount == 1)
        #expect(summary.displayedChanges.allSatisfy { !$0.path.hasPrefix("/") })
        #expect(summary.displayedChanges.allSatisfy { !$0.path.contains("node_modules") })
        #expect(summary.displayedChanges.allSatisfy { !$0.path.contains("DerivedData") })
        #expect(summary.displayedChanges.allSatisfy { !$0.path.contains("build/") })
    }

    @Test func summaryIsCodable() throws {
        let summary = AgentWorkspaceChangeSummary(
            addedCount: 2,
            modifiedCount: 1,
            deletedCount: 3,
            displayedChanges: [
                AgentWorkspaceChange(kind: .added, path: "Sources/New.swift"),
                AgentWorkspaceChange(kind: .deleted, path: "Notes/Old.md")
            ],
            omittedDisplayPathCount: 4
        )

        let decoded = try JSONDecoder().decode(
            AgentWorkspaceChangeSummary.self,
            from: JSONEncoder().encode(summary)
        )
        #expect(decoded == summary)
    }

    @Test func missingBaselineReportsWhichDirectoryIsMissing() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        #expect(throws: AgentWorkspaceChangeScannerError.directoryMissing("before snapshot")) {
            _ = try AgentWorkspaceChangeScanner.scan(
                beforeSnapshotURL: missingURL,
                currentWorkspaceURL: missingURL
            )
        }
    }

    private func write(_ text: String, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

struct AgentCompletionReceiptTests {
    @Test func receiptIncludesProofAndExcludesPrivateRunState() {
        let sourceControlToken = "ghp_" + String(repeating: "x", count: 30)
        let bearerToken = "bearer-" + String(repeating: "y", count: 24)
        let sessionIdentifier = "private-session-" + UUID().uuidString
        let originalPrompt = "PRIVATE ORIGINAL PROMPT"
        let rawLog = "PRIVATE RAW ACTIVITY LOG"
        let workspacePath = "/Users/alice/SecretProject"

        var run = AgentRun.queued(
            id: UUID(),
            title: originalPrompt,
            prompt: originalPrompt,
            workspaceURL: URL(fileURLWithPath: workspacePath, isDirectory: true),
            executor: .codex,
            origin: .attached,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            sessionIdentifier: sessionIdentifier
        )
        run.status = .succeeded
        run.startedAt = Date(timeIntervalSinceReferenceDate: 120)
        run.finishedAt = Date(timeIntervalSinceReferenceDate: 185)
        run.summary = "Saved \(workspacePath)/README.md. Authorization: Bearer \(bearerToken)"
        run.error = "PRIVATE RAW ERROR"
        run.latestAction = "PRIVATE LATEST ACTION"
        run.activity.append(AgentActivityEntry(kind: .progress, text: rawLog))
        run.planText = "Plan contains private details but proves gate exists."
        run.undoEntryIdentifier = "private-undo-id"

        let changes = AgentWorkspaceChangeSummary(
            addedCount: 1,
            modifiedCount: 1,
            deletedCount: 1,
            displayedChanges: [
                AgentWorkspaceChange(kind: .added, path: "Sources/New.swift"),
                AgentWorkspaceChange(kind: .modified, path: workspacePath + "/Secret.swift")
            ],
            omittedDisplayPathCount: 1
        )
        let markdown = AgentCompletionReceipt.markdown(for: run, changes: changes)

        #expect(markdown.contains("# HeyMate completion receipt"))
        #expect(markdown.contains("Result: Completed"))
        #expect(markdown.contains("Duration: 1m 5s"))
        #expect(markdown.contains("Codex via your existing ChatGPT subscription sign-in"))
        #expect(markdown.contains("Changes: 1 added, 1 modified, 1 deleted"))
        #expect(markdown.contains("Added: `Sources/New.swift`"))
        #expect(markdown.contains("Read-only plan approved before write access"))
        #expect(markdown.contains("Pre-write workspace snapshot recorded for Undo"))
        #expect(markdown.contains("REDACTED"))

        #expect(markdown.contains(originalPrompt) == false)
        #expect(markdown.contains(sessionIdentifier) == false)
        #expect(markdown.contains(rawLog) == false)
        #expect(markdown.contains("PRIVATE RAW ERROR") == false)
        #expect(markdown.contains("PRIVATE LATEST ACTION") == false)
        #expect(markdown.contains(workspacePath) == false)
        #expect(markdown.contains(sourceControlToken) == false)
        #expect(markdown.contains(bearerToken) == false)
    }

    @Test func receiptStatesWhenPlanAndUndoEvidenceAreUnavailable() {
        var run = AgentRun.queued(
            id: UUID(),
            title: "Inspect project",
            prompt: "Inspect project",
            workspaceURL: URL(fileURLWithPath: "/tmp/private", isDirectory: true),
            executor: .openCode,
            origin: .sandbox,
            createdAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        run.status = .failed
        run.finishedAt = Date(timeIntervalSinceReferenceDate: 12)

        let markdown = AgentCompletionReceipt.markdown(for: run, generatedAt: Date())
        #expect(markdown.contains("OpenCode via your configured provider sign-in"))
        #expect(markdown.contains("Changes: Not measured"))
        #expect(markdown.contains("No plan-gate record is available"))
        #expect(markdown.contains("No pre-write workspace snapshot is recorded"))
        #expect(markdown.contains("/tmp/private") == false)
    }

    @Test func commonCredentialShapesAreRedacted() {
        let apiKey = "api_key=" + String(repeating: "a", count: 28)
        let accessKey = "AKIA" + String(repeating: "Z", count: 16)
        let jwt = "eyJ" + String(repeating: "a", count: 12)
            + "." + String(repeating: "b", count: 12)
            + "." + String(repeating: "c", count: 12)
        var run = AgentRun.queued(
            id: UUID(),
            title: "Credential check",
            prompt: "prompt",
            workspaceURL: URL(fileURLWithPath: "/tmp/private", isDirectory: true),
            executor: .claudeCode,
            origin: .sandbox
        )
        run.status = .succeeded
        run.summary = "Found \(apiKey), \(accessKey), and \(jwt)."

        let markdown = AgentCompletionReceipt.markdown(for: run)
        #expect(markdown.contains(apiKey) == false)
        #expect(markdown.contains(accessKey) == false)
        #expect(markdown.contains(jwt) == false)
        #expect(markdown.contains("REDACTED"))
    }
}
