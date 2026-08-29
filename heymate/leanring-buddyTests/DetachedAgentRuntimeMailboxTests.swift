//
//  DetachedAgentRuntimeMailboxTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct DetachedAgentLaunchRequestTests {
    private func makeRequest(runID: UUID, attemptID: UUID) -> DetachedAgentLaunchRequest {
        DetachedAgentLaunchRequest(
            runID: runID,
            attemptID: attemptID,
            executor: .codex,
            leg: .execute,
            createdAt: Date(timeIntervalSince1970: 123),
            spec: DetachedAgentLaunchSpec(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: ["--prompt", "private prompt", "session-opaque"],
                currentDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
                environmentKeysToRemove: ["OPENAI_API_KEY"],
                environmentOverrides: ["PRIVATE_TOKEN": "runtime-only"],
                temporaryDirectoriesToRemove: [URL(fileURLWithPath: "/tmp/runtime-private")],
                usesDuplexStandardInput: true,
                runtimeLimit: 30
            )
        )
    }

    @Test func boundedPipeFrameRoundTripsTransientLaunchPayload() throws {
        let runID = UUID()
        let attemptID = UUID()
        let request = makeRequest(runID: runID, attemptID: attemptID)
        let pipe = Pipe()

        try request.write(to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        let decoded = try DetachedAgentLaunchRequest.read(
            from: pipe.fileHandleForReading,
            expectedRunID: runID,
            expectedAttemptID: attemptID
        )

        #expect(decoded == request)
        #expect(decoded.executor == .codex)
        #expect(decoded.spec.arguments.contains("private prompt"))
        #expect(decoded.spec.environmentOverrides["PRIVATE_TOKEN"] == "runtime-only")
    }

    @Test func bootstrapIdentifiersCannotBeSwapped() throws {
        let runID = UUID()
        let attemptID = UUID()
        let request = makeRequest(runID: runID, attemptID: attemptID)
        let pipe = Pipe()
        try request.write(to: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()

        #expect(throws: DetachedAgentLaunchRequestError.self) {
            _ = try DetachedAgentLaunchRequest.read(
                from: pipe.fileHandleForReading,
                expectedRunID: runID,
                expectedAttemptID: UUID()
            )
        }
    }

    @Test func oversizedLaunchFrameIsRejectedBeforeWriting() throws {
        let runID = UUID()
        let attemptID = UUID()
        let oversizedArgument = String(
            repeating: "x",
            count: DetachedAgentLaunchRequest.maximumEncodedBytes + 1
        )
        let request = DetachedAgentLaunchRequest(
            runID: runID,
            attemptID: attemptID,
            executor: .codex,
            leg: .execute,
            spec: DetachedAgentLaunchSpec(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [oversizedArgument],
                currentDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true),
                runtimeLimit: 30
            )
        )
        let pipe = Pipe()

        #expect(throws: DetachedAgentLaunchRequestError.self) {
            try request.write(to: pipe.fileHandleForWriting)
        }
    }
}

struct DetachedAgentCommandMailboxTests {
    private func makeRootDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DetachedAgentMailboxTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func commandRemainsPendingUntilHandlerSucceedsThenDeduplicates() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let attemptID = UUID()
        let mailbox = try DetachedAgentCommandMailbox(
            rootDirectoryURL: rootURL,
            runID: runID,
            attemptID: attemptID
        )
        let command = DetachedAgentCommandEnvelope(
            runID: runID,
            attemptID: attemptID,
            messageID: UUID(),
            sentAt: Date(timeIntervalSince1970: 1),
            command: .cancel
        )

        #expect(try mailbox.enqueue(command))
        #expect(try mailbox.drain { _ in false }.isEmpty)
        #expect(try mailbox.enqueue(command) == false)

        var received: [DetachedAgentCommandEnvelope] = []
        let handled = try mailbox.drain { envelope in
            received.append(envelope)
            return true
        }
        #expect(handled == [command])
        #expect(received == [command])
        #expect(try mailbox.enqueue(command) == false)
        #expect(try mailbox.drain { _ in true }.isEmpty)
    }

    @Test func reusedMessageIDWithDifferentPayloadFailsClosed() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let attemptID = UUID()
        let messageID = UUID()
        let mailbox = try DetachedAgentCommandMailbox(
            rootDirectoryURL: rootURL,
            runID: runID,
            attemptID: attemptID
        )
        _ = try mailbox.enqueue(DetachedAgentCommandEnvelope(
            runID: runID,
            attemptID: attemptID,
            messageID: messageID,
            command: .cancel
        ))

        #expect(throws: DetachedAgentCommandMailboxError.self) {
            _ = try mailbox.enqueue(DetachedAgentCommandEnvelope(
                runID: runID,
                attemptID: attemptID,
                messageID: messageID,
                command: .shutdown
            ))
        }
    }

    @Test func inboxFilesArePrivateAndPayloadIsRemovedAfterAcknowledgement() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let attemptID = UUID()
        let mailbox = try DetachedAgentCommandMailbox(
            rootDirectoryURL: rootURL,
            runID: runID,
            attemptID: attemptID
        )
        let followUpText = "private follow-up already held by the app"
        _ = try mailbox.enqueue(DetachedAgentCommandEnvelope(
            runID: runID,
            attemptID: attemptID,
            command: .sendFollowUp(followUpText)
        ))
        let pendingURL = try #require(
            FileManager.default.contentsOfDirectory(
                at: mailbox.directoryURL,
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "json" }
        )
        let permissions = try FileManager.default.attributesOfItem(atPath: pendingURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)

        _ = try mailbox.drain { _ in true }
        let remainingJSON = try FileManager.default.contentsOfDirectory(
            at: mailbox.directoryURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        let remainingBytes = try remainingJSON.map {
            try String(contentsOf: $0, encoding: .utf8)
        }.joined()
        #expect(!remainingBytes.contains(followUpText))
    }

    @Test func mailboxRejectsCommandForDifferentAttempt() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let attemptID = UUID()
        let mailbox = try DetachedAgentCommandMailbox(
            rootDirectoryURL: rootURL,
            runID: runID,
            attemptID: attemptID
        )

        #expect(throws: DetachedAgentPersistenceError.self) {
            _ = try mailbox.enqueue(DetachedAgentCommandEnvelope(
                runID: runID,
                attemptID: UUID(),
                command: .cancel
            ))
        }
    }

    @Test func oneDrainOwnsTheInboxExclusively() throws {
        let rootURL = makeRootDirectoryURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let runID = UUID()
        let attemptID = UUID()
        let first = try DetachedAgentCommandMailbox(rootDirectoryURL: rootURL, runID: runID, attemptID: attemptID)
        let second = try DetachedAgentCommandMailbox(rootDirectoryURL: rootURL, runID: runID, attemptID: attemptID)
        _ = try first.enqueue(DetachedAgentCommandEnvelope(runID: runID, attemptID: attemptID, command: .cancel))
        var secondDrainWasRejected = false

        _ = try first.drain { _ in
            do {
                _ = try second.drain { _ in true }
            } catch let error as DetachedAgentPersistenceError {
                if case .writerAlreadyActive = error {
                    secondDrainWasRejected = true
                }
            }
            return true
        }
        #expect(secondDrainWasRejected)
    }
}
