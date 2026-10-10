//
//  ChatHistoryStoreTests.swift
//  HeyMateTests
//
//  Chat session persistence and API-history pairing. Writes into a unique
//  temp directory so the real Application Support store is never touched.
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct ChatHistoryStoreTests {

    private func makeTemporaryStoreFileURL() -> URL {
        let uniqueSubdirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: uniqueSubdirectory, withIntermediateDirectories: true)
        return uniqueSubdirectory.appendingPathComponent("chats.json")
    }

    private func removeTemporaryFile(at fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func makeSession(
        title: String,
        minutesAfterEpochBase: Int,
        messages: [ChatMessage]
    ) -> ChatSession {
        let stamp = Date(timeIntervalSinceReferenceDate: TimeInterval(minutesAfterEpochBase * 60))
        return ChatSession(
            id: UUID(),
            title: title,
            createdAt: stamp,
            updatedAt: stamp,
            messages: messages
        )
    }

    private func makeMessage(role: ChatRole, text: String, offset: Int) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: role,
            text: text,
            createdAt: Date(timeIntervalSinceReferenceDate: TimeInterval(offset))
        )
    }

    @Test func emptyStoreLoadsEmpty() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { removeTemporaryFile(at: storeFileURL) }

        let store = FileChatHistoryStore(fileURL: storeFileURL)
        #expect(store.loadAll().isEmpty)
    }

    @Test func upsertSkipsEmptySessions() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { removeTemporaryFile(at: storeFileURL) }

        let store = FileChatHistoryStore(fileURL: storeFileURL)
        store.upsert(ChatSession.empty())
        #expect(store.loadAll().isEmpty)
    }

    @Test func loadAllReturnsNewestUpdatedFirst() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { removeTemporaryFile(at: storeFileURL) }

        let store = FileChatHistoryStore(fileURL: storeFileURL)
        let older = makeSession(
            title: "older",
            minutesAfterEpochBase: 1,
            messages: [makeMessage(role: .user, text: "hi", offset: 1)]
        )
        let newer = makeSession(
            title: "newer",
            minutesAfterEpochBase: 5,
            messages: [makeMessage(role: .user, text: "hey", offset: 5)]
        )
        store.upsert(older)
        store.upsert(newer)

        #expect(store.loadAll().map(\.title) == ["newer", "older"])
    }

    @Test func newInstanceSeesPriorUpserts() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { removeTemporaryFile(at: storeFileURL) }

        let firstStore = FileChatHistoryStore(fileURL: storeFileURL)
        firstStore.upsert(makeSession(
            title: "kept",
            minutesAfterEpochBase: 2,
            messages: [makeMessage(role: .user, text: "hello", offset: 2)]
        ))

        let secondStore = FileChatHistoryStore(fileURL: storeFileURL)
        #expect(secondStore.loadAll().map(\.title) == ["kept"])
    }

    @Test func trimDropsOldestBeyondCap() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { removeTemporaryFile(at: storeFileURL) }

        let store = FileChatHistoryStore(fileURL: storeFileURL, maxSessions: 2)
        store.upsert(makeSession(
            title: "one",
            minutesAfterEpochBase: 1,
            messages: [makeMessage(role: .user, text: "1", offset: 1)]
        ))
        store.upsert(makeSession(
            title: "two",
            minutesAfterEpochBase: 2,
            messages: [makeMessage(role: .user, text: "2", offset: 2)]
        ))
        store.upsert(makeSession(
            title: "three",
            minutesAfterEpochBase: 3,
            messages: [makeMessage(role: .user, text: "3", offset: 3)]
        ))

        #expect(store.loadAll().map(\.title) == ["three", "two"])
    }

    @Test func deleteRemovesOneSession() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { removeTemporaryFile(at: storeFileURL) }

        let store = FileChatHistoryStore(fileURL: storeFileURL)
        var keep = makeSession(
            title: "keep",
            minutesAfterEpochBase: 2,
            messages: [makeMessage(role: .user, text: "keep", offset: 2)]
        )
        let drop = makeSession(
            title: "drop",
            minutesAfterEpochBase: 1,
            messages: [makeMessage(role: .user, text: "drop", offset: 1)]
        )
        store.upsert(keep)
        store.upsert(drop)
        store.delete(id: drop.id)

        keep.updatedAt = Date(timeIntervalSinceReferenceDate: 120)
        #expect(store.loadAll().map(\.title) == ["keep"])
    }

    @Test func titleTruncatesLongFirstMessage() {
        let long = String(repeating: "a", count: 80)
        let title = ChatSession.title(from: long)
        #expect(title.count == 42)
        #expect(title.hasSuffix("…"))
    }

    @Test func apiHistoryPairsConsecutiveTurnsAndDropsTrailingUser() {
        let session = ChatSession(
            id: UUID(),
            title: "t",
            createdAt: Date(),
            updatedAt: Date(),
            messages: [
                makeMessage(role: .user, text: "q1", offset: 1),
                makeMessage(role: .assistant, text: "a1", offset: 2),
                makeMessage(role: .user, text: "q2", offset: 3),
                makeMessage(role: .assistant, text: "a2", offset: 4),
                makeMessage(role: .user, text: "q3 in flight", offset: 5)
            ]
        )
        let pairs = session.apiHistoryPairs(limit: 10)
        #expect(pairs.map(\.userTranscript) == ["q1", "q2"])
        #expect(pairs.map(\.assistantResponse) == ["a1", "a2"])
    }

    @Test func apiHistoryPairsHonorsLimit() {
        var messages: [ChatMessage] = []
        for index in 1...6 {
            messages.append(makeMessage(role: .user, text: "u\(index)", offset: index * 2))
            messages.append(makeMessage(role: .assistant, text: "a\(index)", offset: index * 2 + 1))
        }
        let session = ChatSession(
            id: UUID(),
            title: "t",
            createdAt: Date(),
            updatedAt: Date(),
            messages: messages
        )
        let pairs = session.apiHistoryPairs(limit: 2)
        #expect(pairs.map(\.userTranscript) == ["u5", "u6"])
    }

    @Test func chatMessageHasNoBinaryFields() {
        let fieldNames = Mirror(reflecting: ChatMessage(
            id: UUID(),
            role: .user,
            text: "hi",
            createdAt: Date()
        )).children.compactMap(\.label)
        #expect(!fieldNames.contains("imageData"))
        #expect(!fieldNames.contains("audioData"))
        #expect(!fieldNames.contains("screenshot"))
    }

    @Test func nilMateIDIsAssignedOnceAndDraftRoundTrips() throws {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { removeTemporaryFile(at: storeFileURL) }

        let sessionID = UUID()
        let messageID = UUID()
        let raw = """
        [{
          "createdAt": 0,
          "id": "\(sessionID.uuidString)",
          "messages": [{
            "createdAt": 0,
            "id": "\(messageID.uuidString)",
            "role": "user",
            "text": "hello"
          }],
          "title": "old",
          "updatedAt": 0
        }]
        """
        try Data(raw.utf8).write(to: storeFileURL)

        let defaultMateID = UUID()
        let store = FileChatHistoryStore(fileURL: storeFileURL)
        #expect(store.loadAll().first?.mateID == nil)
        store.migrateNilMateIDs(to: defaultMateID)
        store.migrateNilMateIDs(to: UUID())

        let reloaded = FileChatHistoryStore(fileURL: storeFileURL)
        #expect(reloaded.loadAll().first?.mateID == defaultMateID)

        var drafted = reloaded.loadAll()[0]
        drafted.draftText = "unsent"
        reloaded.upsert(drafted)
        let withDraft = FileChatHistoryStore(fileURL: storeFileURL)
        #expect(withDraft.loadAll().first?.draftText == "unsent")
        #expect(withDraft.loadAll().first?.mateID == defaultMateID)
    }

    @Test func attachmentNamesRoundTripWithoutBinaryData() throws {
        let message = ChatMessage(
            id: UUID(),
            role: .user,
            text: "Read this chart",
            createdAt: Date(),
            attachmentNames: ["chart.png"]
        )
        let decoded = try JSONDecoder().decode(
            ChatMessage.self,
            from: JSONEncoder().encode(message)
        )
        #expect(decoded.attachmentNames == ["chart.png"])
    }

    @Test func deleteSessionsRemovesOnlyThatMatesSessions() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { removeTemporaryFile(at: storeFileURL) }

        let mateA = UUID()
        let mateB = UUID()
        var sessionA = makeSession(
            title: "a",
            minutesAfterEpochBase: 1,
            messages: [makeMessage(role: .user, text: "from a", offset: 1)]
        )
        sessionA.mateID = mateA
        var sessionB = makeSession(
            title: "b",
            minutesAfterEpochBase: 2,
            messages: [makeMessage(role: .user, text: "from b", offset: 2)]
        )
        sessionB.mateID = mateB
        let unassigned = makeSession(
            title: "unassigned",
            minutesAfterEpochBase: 3,
            messages: [makeMessage(role: .user, text: "no mate", offset: 3)]
        )

        let store = FileChatHistoryStore(fileURL: storeFileURL)
        store.upsert(sessionA)
        store.upsert(sessionB)
        store.upsert(unassigned)
        store.deleteSessions(mateID: mateA)

        let reloaded = FileChatHistoryStore(fileURL: storeFileURL)
        #expect(Set(reloaded.loadAll().map(\.title)) == ["b", "unassigned"])
        #expect(reloaded.loadAll().allSatisfy { $0.mateID != mateA })
        #expect(reloaded.loadAll().contains { $0.mateID == nil })
    }

    @Test func trimNoticeCountsDroppedSessionsOnce() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { removeTemporaryFile(at: storeFileURL) }

        let wide = FileChatHistoryStore(fileURL: storeFileURL, maxSessions: 10)
        for index in 1...4 {
            wide.upsert(makeSession(
                title: "s\(index)",
                minutesAfterEpochBase: index,
                messages: [makeMessage(role: .user, text: "m\(index)", offset: index)]
            ))
        }
        #expect(wide.consumeTrimNotice() == 0)

        let store = FileChatHistoryStore(fileURL: storeFileURL, maxSessions: 2)
        store.upsert(makeSession(
            title: "newest",
            minutesAfterEpochBase: 9,
            messages: [makeMessage(role: .user, text: "new", offset: 9)]
        ))

        #expect(store.loadAll().map(\.title) == ["newest", "s4"])
        #expect(store.consumeTrimNotice() == 3)
        #expect(store.consumeTrimNotice() == 0)
    }

    @Test func exportPlainTextIncludesBothRoles() {
        let session = ChatSession(
            id: UUID(),
            title: "Notes",
            createdAt: Date(),
            updatedAt: Date(),
            messages: [
                makeMessage(role: .user, text: "question", offset: 1),
                makeMessage(role: .assistant, text: "answer", offset: 2)
            ]
        )
        let text = session.exportPlainText()
        #expect(text.hasPrefix("Notes\n"))
        #expect(text.contains("user: question"))
        #expect(text.contains("assistant: answer"))
    }

    @Test func persistFailureRecordsErrorWithoutCrashing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let blocker = directory.appendingPathComponent("blocker")
        try Data([0x00]).write(to: blocker)
        let storeFileURL = blocker.appendingPathComponent("chats.json")

        let key = "heymate.lastPersistError"
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let probe = PersistFailureProbe()
        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name("heymate.persistFailed"),
            object: nil,
            queue: nil
        ) { _ in
            probe.didNotify = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let store = FileChatHistoryStore(fileURL: storeFileURL)
        store.upsert(makeSession(
            title: "unsaved",
            minutesAfterEpochBase: 1,
            messages: [makeMessage(role: .user, text: "hi", offset: 1)]
        ))

        #expect(UserDefaults.standard.string(forKey: key) == "Couldn't save chat history.")
        #expect(probe.didNotify)
    }
}

private final class PersistFailureProbe: @unchecked Sendable {
    var didNotify = false
}
