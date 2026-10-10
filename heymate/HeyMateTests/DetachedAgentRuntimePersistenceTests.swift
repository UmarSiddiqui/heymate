//
//  DetachedAgentRuntimePersistenceTests.swift
//  HeyMateTests
//

import Darwin
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

    private func replacingSchemaVersion(
        in data: Data,
        with schemaVersion: Int,
        trailingNewline: Bool = false
    ) throws -> Data {
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["schemaVersion"] = schemaVersion
        var result = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        if trailingNewline { result.append(0x0A) }
        return result
    }

    @Test func protocolEnvelopesRoundTripWithAttemptAndOpaqueApprovalToken() throws {
        let runID = UUID()
        let attemptID = UUID()
        let approvalToken = DetachedAgentApprovalToken()
        let eventEnvelope = DetachedAgentEventEnvelope(
            runID: runID,
            attemptID: attemptID,
            messageID: UUID(),
            emittedAt: Date(timeIntervalSince1970: 123),
            event: .approvalRequested(token: approvalToken, summary: "Run tests")
        )
        let commandEnvelope = DetachedAgentCommandEnvelope(
            runID: runID,
            attemptID: attemptID,
            messageID: UUID(),
            sentAt: Date(timeIntervalSince1970: 456),
            command: .respondToApproval(token: approvalToken, decision: .approve)
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        #expect(try decoder.decode(DetachedAgentEventEnvelope.self, from: encoder.encode(eventEnvelope)) == eventEnvelope)
        #expect(try decoder.decode(DetachedAgentCommandEnvelope.self, from: encoder.encode(commandEnvelope)) == commandEnvelope)
    }

    @Test func journalSequenceRemainsMonotonicAcrossWriterReopen() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let attemptID = UUID()
        var firstTwoSequences: [UInt64] = []

        do {
            let journal = try DetachedAgentRuntimeJournal(rootDirectoryURL: rootURL, runID: runID, attemptID: attemptID)
            firstTwoSequences = [
                try journal.append(DetachedAgentEventEnvelope(runID: runID, attemptID: attemptID, event: .ready)).sequence,
                try journal.append(DetachedAgentEventEnvelope(runID: runID, attemptID: attemptID, event: .phaseChanged(.running))).sequence
            ]
        }

        let reopened = try DetachedAgentRuntimeJournal(rootDirectoryURL: rootURL, runID: runID, attemptID: attemptID)
        let third = try reopened.append(DetachedAgentEventEnvelope(runID: runID, attemptID: attemptID, event: .heartbeat))
        #expect(firstTwoSequences + [third.sequence] == [1, 2, 3])
        #expect(reopened.records().map(\.sequence) == [1, 2, 3])
    }

    @Test func versionTwoStateAndJournalRemainReadableAfterVersionThreeUpdate() throws {
        #expect(DetachedAgentRuntimeProtocol.currentSchemaVersion == 3)
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let attemptID = UUID()
        let stateFileURL: URL
        let journalFileURL: URL

        do {
            let journal = try DetachedAgentRuntimeJournal(
                rootDirectoryURL: rootURL,
                runID: runID,
                attemptID: attemptID
            )
            _ = try journal.append(DetachedAgentEventEnvelope(
                runID: runID,
                attemptID: attemptID,
                event: .phaseChanged(.running)
            ))
            journalFileURL = journal.journalFileURL

            let stateStore = try DetachedAgentDurableStateStore(
                rootDirectoryURL: rootURL,
                runID: runID,
                attemptID: attemptID
            )
            try stateStore.save(DetachedAgentDurableState(
                runID: runID,
                attemptID: attemptID,
                leg: .execute,
                phase: .running,
                lastJournalSequence: 1,
                latestSafeSummary: "Still running"
            ))
            stateFileURL = stateStore.stateFileURL
        }

        let versionTwoState = try replacingSchemaVersion(
            in: DetachedAgentSecureFiles.readRegularFile(stateFileURL),
            with: 2
        )
        try DetachedAgentSecureFiles.atomicDurableWrite(versionTwoState, to: stateFileURL)
        let versionTwoJournal = try replacingSchemaVersion(
            in: DetachedAgentSecureFiles.readRegularFile(journalFileURL),
            with: 2,
            trailingNewline: true
        )
        try DetachedAgentSecureFiles.atomicDurableWrite(versionTwoJournal, to: journalFileURL)

        let loadedState = try DetachedAgentDurableStateStore.loadReadOnly(
            rootDirectoryURL: rootURL,
            runID: runID,
            attemptID: attemptID
        )
        let state = try #require(loadedState)
        let records = try DetachedAgentRuntimeJournal.loadReadOnly(
            rootDirectoryURL: rootURL,
            runID: runID,
            attemptID: attemptID
        )

        #expect(state.schemaVersion == 2)
        #expect(state.phase == .running)
        #expect(state.latestSafeSummary == "Still running")
        #expect(records.count == 1)
        #expect(records.first?.schemaVersion == 2)
        #expect(records.first?.phase == .running)
    }

    @Test func persistenceRejectsVersionOneAndUnknownFutureVersions() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let attemptID = UUID()
        let stateFileURL: URL

        do {
            let stateStore = try DetachedAgentDurableStateStore(
                rootDirectoryURL: rootURL,
                runID: runID,
                attemptID: attemptID
            )
            try stateStore.save(DetachedAgentDurableState(
                runID: runID,
                attemptID: attemptID,
                leg: .execute
            ))
            stateFileURL = stateStore.stateFileURL
        }
        let currentState = try DetachedAgentSecureFiles.readRegularFile(stateFileURL)

        for unsupportedVersion in [1, 4] {
            try DetachedAgentSecureFiles.atomicDurableWrite(
                replacingSchemaVersion(in: currentState, with: unsupportedVersion),
                to: stateFileURL
            )
            do {
                _ = try DetachedAgentDurableStateStore.loadReadOnly(
                    rootDirectoryURL: rootURL,
                    runID: runID,
                    attemptID: attemptID
                )
                Issue.record("Expected schema version \(unsupportedVersion) rejection")
            } catch let error as DetachedAgentPersistenceError {
                #expect(error == .unsupportedSchemaVersion(unsupportedVersion))
            }
        }
    }

    @Test func readOnlyJournalIgnoresPartialFinalRecordWithoutTruncatingWriterBytes() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let attemptID = UUID()
        let journalFileURL: URL

        do {
            let journal = try DetachedAgentRuntimeJournal(rootDirectoryURL: rootURL, runID: runID, attemptID: attemptID)
            journalFileURL = journal.journalFileURL
            _ = try journal.append(DetachedAgentEventEnvelope(runID: runID, attemptID: attemptID, event: .ready))
            _ = try journal.append(DetachedAgentEventEnvelope(runID: runID, attemptID: attemptID, event: .heartbeat))
        }

        let fileHandle = try FileHandle(forWritingTo: journalFileURL)
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: Data(#"{"schemaVersion":2,"runID":"partial""#.utf8))
        try fileHandle.close()
        let bytesBeforeRead = try Data(contentsOf: journalFileURL)

        let records = try DetachedAgentRuntimeJournal.loadReadOnly(
            rootDirectoryURL: rootURL,
            runID: runID,
            attemptID: attemptID
        )
        #expect(records.map(\.sequence) == [1, 2])
        #expect(try Data(contentsOf: journalFileURL) == bytesBeforeRead)

        let recoveredWriter = try DetachedAgentRuntimeJournal(rootDirectoryURL: rootURL, runID: runID, attemptID: attemptID)
        let next = try recoveredWriter.append(DetachedAgentEventEnvelope(
            runID: runID,
            attemptID: attemptID,
            event: .phaseChanged(.detached)
        ))
        #expect(next.sequence == 3)
        #expect(!(try String(contentsOf: journalFileURL, encoding: .utf8)).contains("partial"))
    }

    @Test func persistenceUsesPrivateDirectoryAndFilePermissions() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let attemptID = UUID()
        let journal = try DetachedAgentRuntimeJournal(rootDirectoryURL: rootURL, runID: runID, attemptID: attemptID)
        let stateStore = try DetachedAgentDurableStateStore(rootDirectoryURL: rootURL, runID: runID, attemptID: attemptID)
        try stateStore.save(DetachedAgentDurableState(runID: runID, attemptID: attemptID, leg: .execute))

        #expect(try permissions(at: rootURL) == 0o700)
        #expect(try permissions(at: journal.directoryURL.deletingLastPathComponent()) == 0o700)
        #expect(try permissions(at: journal.directoryURL) == 0o700)
        #expect(try permissions(at: journal.journalFileURL) == 0o600)
        #expect(try permissions(at: stateStore.stateFileURL) == 0o600)
    }

    @Test func durableStateRoundTripsRuntimeOwnershipAndTerminalMetadata() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let attemptID = UUID()
        let store = try DetachedAgentDurableStateStore(rootDirectoryURL: rootURL, runID: runID, attemptID: attemptID)
        let runnerIdentity = try #require(AgentProcessIdentityInspector.identity(for: getpid()))
        var state = DetachedAgentDurableState(
            runID: runID,
            attemptID: attemptID,
            leg: .execute,
            phase: .running,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastJournalSequence: 3,
            latestSafeSummary: "Running tests",
            runnerIdentity: runnerIdentity,
            lastHeartbeatAt: Date(timeIntervalSince1970: 19),
            pendingApprovalToken: DetachedAgentApprovalToken()
        )
        try store.save(state)

        state.phase = .succeeded
        state.updatedAt = Date(timeIntervalSince1970: 30)
        state.lastJournalSequence = 4
        state.terminalSafeSummary = "Tests passed"
        state.terminalSafeError = "No error"
        state.pendingApprovalToken = nil
        state.handedOffToTerminal = true
        state.exitCode = 0
        try store.save(state)

        #expect(try store.load() == state)
        #expect(try DetachedAgentDurableStateStore.loadReadOnly(
            rootDirectoryURL: rootURL,
            runID: runID,
            attemptID: attemptID
        ) == state)
    }

    @Test func journalAndStateNeverPersistRawSecretsOutputOrOpaqueCLIIdentifiers() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let attemptID = UUID()
        let journal = try DetachedAgentRuntimeJournal(rootDirectoryURL: rootURL, runID: runID, attemptID: attemptID)
        let stateStore = try DetachedAgentDurableStateStore(rootDirectoryURL: rootURL, runID: runID, attemptID: attemptID)
        let apiKey = "sk-ant-api03-super-secret-value"
        let bearer = "secret-bearer-value"
        let sessionIdentifier = "provider-session-do-not-persist"

        let outputRecord = try journal.append(DetachedAgentEventEnvelope(
            runID: runID,
            attemptID: attemptID,
            event: .output("OPENAI_API_KEY=\(apiKey)", stream: .standardError)
        ))
        _ = try journal.append(DetachedAgentEventEnvelope(
            runID: runID,
            attemptID: attemptID,
            event: .sessionIdentified(sessionIdentifier)
        ))
        let warningRecord = try journal.append(DetachedAgentEventEnvelope(
            runID: runID,
            attemptID: attemptID,
            event: .warning("Authorization: Bearer \(bearer)")
        ))
        try stateStore.save(DetachedAgentDurableState(
            runID: runID,
            attemptID: attemptID,
            leg: .execute,
            latestSafeSummary: "token=\(bearer)",
            terminalSafeSummary: "password=\(bearer)",
            terminalSafeError: "secret=\(bearer)"
        ))

        let journalBytes = try String(contentsOf: journal.journalFileURL, encoding: .utf8)
        let stateBytes = try String(contentsOf: stateStore.stateFileURL, encoding: .utf8)
        for forbidden in [apiKey, bearer, sessionIdentifier, "OPENAI_API_KEY"] {
            #expect(!journalBytes.contains(forbidden))
            #expect(!stateBytes.contains(forbidden))
        }
        #expect(outputRecord.safeSummary == nil)
        #expect(outputRecord.outputByteCount != nil)
        #expect(warningRecord.safeSummary?.contains("[REDACTED]") == true)
        #expect(stateBytes.contains("[REDACTED]"))
    }

    @Test func journalRejectsDifferentRunOrAttempt() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let attemptID = UUID()
        let journal = try DetachedAgentRuntimeJournal(rootDirectoryURL: rootURL, runID: runID, attemptID: attemptID)

        #expect(throws: DetachedAgentPersistenceError.self) {
            _ = try journal.append(DetachedAgentEventEnvelope(runID: UUID(), attemptID: attemptID, event: .heartbeat))
        }
        #expect(throws: DetachedAgentPersistenceError.self) {
            _ = try journal.append(DetachedAgentEventEnvelope(runID: runID, attemptID: UUID(), event: .heartbeat))
        }
    }

    @Test func secondWriterForSameArtifactFailsClosed() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let attemptID = UUID()
        let first = try DetachedAgentRuntimeJournal(rootDirectoryURL: rootURL, runID: runID, attemptID: attemptID)
        _ = first

        do {
            _ = try DetachedAgentRuntimeJournal(rootDirectoryURL: rootURL, runID: runID, attemptID: attemptID)
            Issue.record("Expected exclusive writer rejection")
        } catch let error as DetachedAgentPersistenceError {
            guard case .writerAlreadyActive = error else {
                Issue.record("Unexpected persistence error: \(error)")
                return
            }
        }
    }

    @Test func symbolicLinkPersistenceRootIsRejected() throws {
        let parentURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: parentURL) }
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let targetURL = parentURL.appendingPathComponent("target", isDirectory: true)
        let linkURL = parentURL.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        #expect(throws: DetachedAgentPersistenceError.self) {
            _ = try DetachedAgentDurableStateStore(rootDirectoryURL: linkURL, runID: UUID(), attemptID: UUID())
        }
    }

    @Test func readOnlyLoaderRejectsSymbolicLinkRuntimeRoot() throws {
        let parentURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: parentURL) }
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let targetURL = parentURL.appendingPathComponent("target", isDirectory: true)
        let linkURL = parentURL.appendingPathComponent("link", isDirectory: true)
        let runID = UUID()
        let attemptID = UUID()
        do {
            let store = try DetachedAgentDurableStateStore(
                rootDirectoryURL: targetURL,
                runID: runID,
                attemptID: attemptID
            )
            try store.save(DetachedAgentDurableState(
                runID: runID,
                attemptID: attemptID,
                leg: .execute
            ))
        }
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

        #expect(throws: DetachedAgentPersistenceError.self) {
            _ = try DetachedAgentDurableStateStore.loadReadOnly(
                rootDirectoryURL: linkURL,
                runID: runID,
                attemptID: attemptID
            )
        }
    }

    @Test func readOnlyLoaderRejectsUnknownBootIdentity() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let attemptID = UUID()
        let stateFileURL: URL
        do {
            let store = try DetachedAgentDurableStateStore(
                rootDirectoryURL: rootURL,
                runID: runID,
                attemptID: attemptID
            )
            try store.save(DetachedAgentDurableState(
                runID: runID,
                attemptID: attemptID,
                leg: .execute
            ))
            stateFileURL = store.stateFileURL
        }
        let current = try #require(AgentProcessIdentityInspector.identity(for: getpid()))
        let unknownBootIdentity = AgentProcessIdentity(
            pid: current.pid,
            startSeconds: current.startSeconds,
            startMicroseconds: current.startMicroseconds,
            executablePath: current.executablePath,
            uid: current.uid,
            bootSessionID: "unknown"
        )
        let untrustedState = DetachedAgentDurableState(
            runID: runID,
            attemptID: attemptID,
            leg: .execute,
            runnerIdentity: unknownBootIdentity
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(untrustedState).write(to: stateFileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateFileURL.path
        )

        #expect(throws: DetachedAgentPersistenceError.self) {
            _ = try DetachedAgentDurableStateStore.loadReadOnly(
                rootDirectoryURL: rootURL,
                runID: runID,
                attemptID: attemptID
            )
        }
    }

    @Test func readOnlyLoaderRejectsInsecureStatePermissions() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let attemptID = UUID()
        let stateFileURL: URL
        do {
            let store = try DetachedAgentDurableStateStore(rootDirectoryURL: rootURL, runID: runID, attemptID: attemptID)
            try store.save(DetachedAgentDurableState(runID: runID, attemptID: attemptID, leg: .execute))
            stateFileURL = store.stateFileURL
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stateFileURL.path)

        #expect(throws: DetachedAgentPersistenceError.self) {
            _ = try DetachedAgentDurableStateStore.loadReadOnly(
                rootDirectoryURL: rootURL,
                runID: runID,
                attemptID: attemptID
            )
        }
    }
}
