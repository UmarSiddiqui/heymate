//
//  DetachedAgentRunnerDiagnosticLogsTests.swift
//  HeyMateTests
//

import Foundation
import Testing
@testable import HeyMate

struct DetachedAgentRunnerDiagnosticLogsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func logsDirectoryStaysOutOfTheRealLogsFolderUnderTests() {
        let realLogs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/HeyMate", isDirectory: true)
        #expect(HeyMateDataDirectory.isHostingTests)
        #expect(DetachedAgentRunnerDiagnosticLogs.directoryURL.standardizedFileURL != realLogs.standardizedFileURL)
        let runnerLog = DetachedAgentRunnerBootstrap.diagnosticLogURL(attemptID: UUID())
        #expect(runnerLog?.path.hasPrefix(realLogs.path) == false)
    }

    @Test func fileNameRoundTripsAndIgnoresOtherLogs() {
        let attemptID = UUID()
        let url = DetachedAgentRunnerDiagnosticLogs.fileURL(attemptID: attemptID, directoryURL: URL(fileURLWithPath: "/tmp"))
        #expect(DetachedAgentRunnerDiagnosticLogs.attemptID(fromFileName: url.lastPathComponent) == attemptID)
        #expect(DetachedAgentRunnerDiagnosticLogs.attemptID(fromFileName: "heymate.log") == nil)
        #expect(DetachedAgentRunnerDiagnosticLogs.attemptID(fromFileName: "heymate.1.log") == nil)
        #expect(DetachedAgentRunnerDiagnosticLogs.attemptID(fromFileName: "agent-runner-nope.log") == nil)
    }

    @Test func pruneRuleKeepsOnlyRecentLogsForExistingAttempts() {
        let existing = UUID()
        let gone = UUID()
        let recent = now.addingTimeInterval(-60)
        let eightDaysAgo = now.addingTimeInterval(-8 * 24 * 60 * 60)

        #expect(!DetachedAgentRunnerDiagnosticLogs.shouldPrune(
            attemptID: existing, modifiedAt: recent, existingAttemptIDs: [existing], now: now))
        #expect(DetachedAgentRunnerDiagnosticLogs.shouldPrune(
            attemptID: existing, modifiedAt: eightDaysAgo, existingAttemptIDs: [existing], now: now))
        #expect(DetachedAgentRunnerDiagnosticLogs.shouldPrune(
            attemptID: gone, modifiedAt: recent, existingAttemptIDs: [existing], now: now))
    }

    @Test func pruneStaleLogsRemovesOnlyStaleAgentRunnerLogs() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("heymate-diagnostic-logs-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let logsURL = root.appendingPathComponent("Logs", isDirectory: true)
        let runtimeURL = root.appendingPathComponent("runtime", isDirectory: true)
        try fileManager.createDirectory(at: logsURL, withIntermediateDirectories: true)

        let liveAttempt = UUID()
        let oldAttempt = UUID()
        let goneAttempt = UUID()
        for attemptID in [liveAttempt, oldAttempt] {
            try fileManager.createDirectory(
                at: DetachedAgentRuntimePaths.attemptDirectoryURL(
                    rootDirectoryURL: runtimeURL, runID: UUID(), attemptID: attemptID),
                withIntermediateDirectories: true
            )
        }

        func makeLog(_ attemptID: UUID, modifiedAt: Date) throws -> URL {
            let url = DetachedAgentRunnerDiagnosticLogs.fileURL(attemptID: attemptID, directoryURL: logsURL)
            #expect(fileManager.createFile(atPath: url.path, contents: Data()))
            try fileManager.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
            return url
        }
        let liveLog = try makeLog(liveAttempt, modifiedAt: now.addingTimeInterval(-60))
        let oldLog = try makeLog(oldAttempt, modifiedAt: now.addingTimeInterval(-8 * 24 * 60 * 60))
        let goneLog = try makeLog(goneAttempt, modifiedAt: now.addingTimeInterval(-60))
        let appLog = logsURL.appendingPathComponent("heymate.log")
        let rolledAppLog = logsURL.appendingPathComponent("heymate.1.log")
        for url in [appLog, rolledAppLog] {
            #expect(fileManager.createFile(atPath: url.path, contents: Data("x".utf8)))
            try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-30 * 24 * 60 * 60)], ofItemAtPath: url.path)
        }

        let removed = DetachedAgentRunnerDiagnosticLogs.pruneStaleLogs(
            directoryURL: logsURL, runtimeRootURL: runtimeURL, now: now, fileManager: fileManager)

        #expect(removed == 2)
        #expect(fileManager.fileExists(atPath: liveLog.path))
        #expect(!fileManager.fileExists(atPath: oldLog.path))
        #expect(!fileManager.fileExists(atPath: goneLog.path))
        #expect(fileManager.fileExists(atPath: appLog.path))
        #expect(fileManager.fileExists(atPath: rolledAppLog.path))
    }

    @Test func removeIfEmptyKeepsLogsWithContent() throws {
        let fileManager = FileManager.default
        let logsURL = fileManager.temporaryDirectory
            .appendingPathComponent("heymate-diagnostic-logs-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: logsURL) }
        try fileManager.createDirectory(at: logsURL, withIntermediateDirectories: true)

        let emptyAttempt = UUID()
        let crashedAttempt = UUID()
        let emptyLog = DetachedAgentRunnerDiagnosticLogs.fileURL(attemptID: emptyAttempt, directoryURL: logsURL)
        let crashedLog = DetachedAgentRunnerDiagnosticLogs.fileURL(attemptID: crashedAttempt, directoryURL: logsURL)
        #expect(fileManager.createFile(atPath: emptyLog.path, contents: Data()))
        #expect(fileManager.createFile(atPath: crashedLog.path, contents: Data("Fatal error\n".utf8)))

        DetachedAgentRunnerDiagnosticLogs.removeIfEmpty(attemptID: emptyAttempt, directoryURL: logsURL, fileManager: fileManager)
        DetachedAgentRunnerDiagnosticLogs.removeIfEmpty(attemptID: crashedAttempt, directoryURL: logsURL, fileManager: fileManager)

        #expect(!fileManager.fileExists(atPath: emptyLog.path))
        #expect(fileManager.fileExists(atPath: crashedLog.path))
    }
}
