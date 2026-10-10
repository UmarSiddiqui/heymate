//
//  DetachedAgentRuntimeJournalLimitsTests.swift
//  HeyMateTests
//

import Foundation
import Testing
@testable import HeyMate

struct DetachedAgentRuntimeJournalLimitsTests {
    private func makeRootDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DetachedJournalLimitsTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func appendRejectsRecordCountAndRecordSizePastLimits() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let attemptID = UUID()
        let countLimits = DetachedAgentJournalLimits(
            maximumFileByteCount: 1_024 * 1_024,
            maximumRecordByteCount: 16 * 1_024,
            maximumRecordCount: 2
        )
        let journal = try DetachedAgentRuntimeJournal(
            rootDirectoryURL: rootURL,
            runID: runID,
            attemptID: attemptID,
            limits: countLimits
        )
        _ = try journal.append(.init(runID: runID, attemptID: attemptID, event: .ready))
        _ = try journal.append(.init(runID: runID, attemptID: attemptID, event: .heartbeat))

        do {
            _ = try journal.append(.init(
                runID: runID,
                attemptID: attemptID,
                event: .phaseChanged(.running)
            ))
            Issue.record("Expected record-count limit rejection")
        } catch let error as DetachedAgentPersistenceError {
            #expect(error == .journalRecordLimitExceeded(maximumRecords: 2, actualRecords: 3))
        }

        let secondRootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: secondRootURL) }
        let sizeLimitedJournal = try DetachedAgentRuntimeJournal(
            rootDirectoryURL: secondRootURL,
            runID: runID,
            attemptID: attemptID,
            limits: .init(
                maximumFileByteCount: 1_024,
                maximumRecordByteCount: 32,
                maximumRecordCount: 10
            )
        )
        #expect(throws: DetachedAgentPersistenceError.self) {
            _ = try sizeLimitedJournal.append(.init(
                runID: runID,
                attemptID: attemptID,
                event: .ready
            ))
        }
        #expect(sizeLimitedJournal.records().isEmpty)
        #expect((try Data(contentsOf: sizeLimitedJournal.journalFileURL)).isEmpty)
    }

    @Test func writerAndReadOnlyLoaderRejectOversizedExistingFileBeforeReading() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let attemptID = UUID()
        let journalFileURL: URL
        do {
            let journal = try DetachedAgentRuntimeJournal(
                rootDirectoryURL: rootURL,
                runID: runID,
                attemptID: attemptID
            )
            _ = try journal.append(.init(runID: runID, attemptID: attemptID, event: .ready))
            journalFileURL = journal.journalFileURL
        }
        let handle = try FileHandle(forWritingTo: journalFileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x78, count: 2_048))
        try handle.close()
        let limits = DetachedAgentJournalLimits(
            maximumFileByteCount: 512,
            maximumRecordByteCount: 256,
            maximumRecordCount: 10
        )

        for load in [
            {
                _ = try DetachedAgentRuntimeJournal(
                    rootDirectoryURL: rootURL,
                    runID: runID,
                    attemptID: attemptID,
                    limits: limits
                )
            },
            {
                _ = try DetachedAgentRuntimeJournal.loadReadOnly(
                    rootDirectoryURL: rootURL,
                    runID: runID,
                    attemptID: attemptID,
                    limits: limits
                )
            }
        ] {
            do {
                try load()
                Issue.record("Expected oversized journal rejection")
            } catch let error as DetachedAgentPersistenceError {
                guard case .artifactTooLarge(let path, let maximumBytes, let actualBytes) = error else {
                    Issue.record("Unexpected persistence error: \(error)")
                    continue
                }
                #expect(path == journalFileURL.path)
                #expect(maximumBytes == 512)
                #expect(actualBytes > maximumBytes)
            }
        }
    }

    @Test func recoveryRejectsTooManyExistingRecords() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let attemptID = UUID()
        do {
            let journal = try DetachedAgentRuntimeJournal(
                rootDirectoryURL: rootURL,
                runID: runID,
                attemptID: attemptID
            )
            _ = try journal.append(.init(runID: runID, attemptID: attemptID, event: .ready))
            _ = try journal.append(.init(runID: runID, attemptID: attemptID, event: .heartbeat))
            _ = try journal.append(.init(runID: runID, attemptID: attemptID, event: .heartbeat))
        }

        do {
            _ = try DetachedAgentRuntimeJournal(
                rootDirectoryURL: rootURL,
                runID: runID,
                attemptID: attemptID,
                limits: .init(
                    maximumFileByteCount: 1_024 * 1_024,
                    maximumRecordByteCount: 16 * 1_024,
                    maximumRecordCount: 2
                )
            )
            Issue.record("Expected recovered record-count limit rejection")
        } catch let error as DetachedAgentPersistenceError {
            #expect(error == .journalRecordLimitExceeded(maximumRecords: 2, actualRecords: 3))
        }
    }

    @Test func appendRechecksActualFileSizeAfterWriterInitialization() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let attemptID = UUID()
        let limits = DetachedAgentJournalLimits(
            maximumFileByteCount: 512,
            maximumRecordByteCount: 256,
            maximumRecordCount: 10
        )
        let journal = try DetachedAgentRuntimeJournal(
            rootDirectoryURL: rootURL,
            runID: runID,
            attemptID: attemptID,
            limits: limits
        )
        let handle = try FileHandle(forWritingTo: journal.journalFileURL)
        try handle.write(contentsOf: Data(repeating: 0x79, count: 500))
        try handle.close()

        #expect(throws: DetachedAgentPersistenceError.self) {
            _ = try journal.append(.init(
                runID: runID,
                attemptID: attemptID,
                event: .ready
            ))
        }
        #expect(journal.records().isEmpty)
        #expect(try Data(contentsOf: journal.journalFileURL).count == 500)
    }
}
