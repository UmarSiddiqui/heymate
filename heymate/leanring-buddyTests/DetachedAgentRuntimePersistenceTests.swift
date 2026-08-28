//
//  DetachedAgentRuntimePersistenceTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct DetachedAgentRuntimePersistenceTests {

    private func makeRootDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DetachedAgentRuntimeTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func protocolEnvelopesRoundTrip() throws {
        let runID = UUID()
        let eventEnvelope = DetachedAgentEventEnvelope(
            runID: runID,
            messageID: UUID(),
            emittedAt: Date(timeIntervalSince1970: 123),
            event: .approvalRequested(identifier: "approval-1", summary: "Run tests")
        )
        let commandEnvelope = DetachedAgentCommandEnvelope(
            runID: runID,
            messageID: UUID(),
            sentAt: Date(timeIntervalSince1970: 456),
            command: .respondToApproval(identifier: "approval-1", decision: .approve)
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        #expect(
            try decoder.decode(
                DetachedAgentEventEnvelope.self,
                from: encoder.encode(eventEnvelope)
            ) == eventEnvelope
        )
        #expect(
            try decoder.decode(
                DetachedAgentCommandEnvelope.self,
                from: encoder.encode(commandEnvelope)
            ) == commandEnvelope
        )
    }

    @Test func journalSequenceRemainsMonotonicAcrossReopen() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let firstJournal = try DetachedAgentRuntimeJournal(rootDirectoryURL: rootURL, runID: runID)

        let first = try firstJournal.append(
            DetachedAgentEventEnvelope(runID: runID, event: .ready)
        )
        let second = try firstJournal.append(
            DetachedAgentEventEnvelope(runID: runID, event: .phaseChanged(.running))
        )

        let reopened = try DetachedAgentRuntimeJournal(rootDirectoryURL: rootURL, runID: runID)
        let third = try reopened.append(
            DetachedAgentEventEnvelope(runID: runID, event: .heartbeat)
        )

        #expect([first.sequence, second.sequence, third.sequence] == [1, 2, 3])
        #expect(reopened.records().map(\.sequence) == [1, 2, 3])
    }

    @Test func truncatedFinalLineIsRemovedBeforeNextAppend() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let journal = try DetachedAgentRuntimeJournal(rootDirectoryURL: rootURL, runID: runID)
        _ = try journal.append(DetachedAgentEventEnvelope(runID: runID, event: .ready))
        _ = try journal.append(DetachedAgentEventEnvelope(runID: runID, event: .heartbeat))

        let fileHandle = try FileHandle(forWritingTo: journal.journalFileURL)
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: Data(#"{"schemaVersion":1,"runID":"partial""#.utf8))
        try fileHandle.close()

        let recovered = try DetachedAgentRuntimeJournal(rootDirectoryURL: rootURL, runID: runID)
        #expect(recovered.records().map(\.sequence) == [1, 2])
        let next = try recovered.append(
            DetachedAgentEventEnvelope(runID: runID, event: .phaseChanged(.detached))
        )
        #expect(next.sequence == 3)

        let persistedText = try String(contentsOf: recovered.journalFileURL, encoding: .utf8)
        #expect(!persistedText.contains("partial"))
        #expect(persistedText.last == "\n")
        #expect(persistedText.split(separator: "\n").count == 3)
    }

    @Test func persistenceUsesPrivateDirectoryAndFilePermissions() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let journal = try DetachedAgentRuntimeJournal(rootDirectoryURL: rootURL, runID: runID)
        let stateStore = try DetachedAgentDurableStateStore(rootDirectoryURL: rootURL, runID: runID)
        try stateStore.save(DetachedAgentDurableState(runID: runID))

        #expect(try permissions(at: rootURL) == 0o700)
        #expect(try permissions(at: journal.directoryURL) == 0o700)
        #expect(try permissions(at: journal.journalFileURL) == 0o600)
        #expect(try permissions(at: stateStore.stateFileURL) == 0o600)
    }

    @Test func durableStateUsesAtomicReplacementAndReloads() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let store = try DetachedAgentDurableStateStore(rootDirectoryURL: rootURL, runID: runID)
        var state = DetachedAgentDurableState(
            runID: runID,
            phase: .running,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastJournalSequence: 3,
            latestSafeSummary: "Running tests"
        )
        try store.save(state)

        state.phase = .succeeded
        state.updatedAt = Date(timeIntervalSince1970: 30)
        state.lastJournalSequence = 4
        state.exitCode = 0
        try store.save(state)

        #expect(try store.load() == state)
        let directoryContents = try FileManager.default.contentsOfDirectory(
            at: store.directoryURL,
            includingPropertiesForKeys: nil
        )
        #expect(directoryContents.map(\.lastPathComponent) == ["state.json"])
    }

    @Test func journalAndStateNeverPersistRawSecretsOrOutput() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let journal = try DetachedAgentRuntimeJournal(rootDirectoryURL: rootURL, runID: runID)
        let stateStore = try DetachedAgentDurableStateStore(rootDirectoryURL: rootURL, runID: runID)
        let apiKey = "sk-ant-api03-super-secret-value"
        let bearer = "secret-bearer-value"

        let outputRecord = try journal.append(
            DetachedAgentEventEnvelope(
                runID: runID,
                event: .output("OPENAI_API_KEY=\(apiKey)", stream: .standardError)
            )
        )
        let warningRecord = try journal.append(
            DetachedAgentEventEnvelope(
                runID: runID,
                event: .warning("Authorization: Bearer \(bearer)")
            )
        )
        try stateStore.save(
            DetachedAgentDurableState(
                runID: runID,
                latestSafeSummary: "token=\(bearer)"
            )
        )

        let journalBytes = try String(contentsOf: journal.journalFileURL, encoding: .utf8)
        let stateBytes = try String(contentsOf: stateStore.stateFileURL, encoding: .utf8)
        #expect(!journalBytes.contains(apiKey))
        #expect(!journalBytes.contains(bearer))
        #expect(!stateBytes.contains(bearer))
        #expect(!journalBytes.contains("OPENAI_API_KEY"))
        #expect(outputRecord.safeSummary == nil)
        #expect(outputRecord.outputByteCount != nil)
        #expect(warningRecord.safeSummary?.contains("[REDACTED]") == true)
        #expect(stateBytes.contains("[REDACTED]"))
    }

    @Test func journalRejectsEnvelopeForDifferentRun() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let journal = try DetachedAgentRuntimeJournal(rootDirectoryURL: rootURL, runID: UUID())

        do {
            _ = try journal.append(
                DetachedAgentEventEnvelope(runID: UUID(), event: .heartbeat)
            )
            Issue.record("Expected run ID mismatch")
        } catch let error as DetachedAgentPersistenceError {
            guard case .runIDMismatch = error else {
                Issue.record("Unexpected persistence error: \(error)")
                return
            }
        }
    }
}
