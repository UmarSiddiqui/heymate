//
//  MemoryRepositoryTests.swift
//  leanring-buddyTests
//
//  Tests for the JSON-file memory store: ordering, cross-instance
//  persistence, targeted delete, deleteAll, session-summary trimming that
//  spares preferences/projectFacts, and corrupt-file resilience. Every
//  suite writes into its own temporary directory so parallel tests never
//  share state and the user's real Application Support store is untouched.
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct MemoryRepositoryTests {

    /// Unique subdirectory per suite instance: parallel test runs each get a
    /// private file, and the defer removes everything even when tests fail.
    private func makeTemporaryStoreFileURL() -> URL {
        let uniqueSubdirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: uniqueSubdirectory, withIntermediateDirectories: true)
        return uniqueSubdirectory.appendingPathComponent("memory.json")
    }

    private func removeTemporaryFile(at fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func makeItem(
        kind: MemoryKind,
        text: String,
        minutesAfterEpochBase: Int,
        id: UUID = UUID()
    ) -> MemoryItem {
        MemoryItem(
            id: id,
            kind: kind,
            text: text,
            createdAt: Date(timeIntervalSinceReferenceDate: TimeInterval(minutesAfterEpochBase * 60))
        )
    }

    // MARK: - Append + loadAll ordering

    @Test func loadAllReturnsAppendedItemsOldestFirstRegardlessOfAppendOrder() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { removeTemporaryFile(at: storeFileURL) }

        let repository = FileMemoryRepository(fileURL: storeFileURL)

        // Appended newest-first on purpose to prove loadAll sorts by date.
        let newestSummary = makeItem(kind: .sessionSummary, text: "newest summary", minutesAfterEpochBase: 3)
        let middleSummary = makeItem(kind: .sessionSummary, text: "middle summary", minutesAfterEpochBase: 2)
        let oldestSummary = makeItem(kind: .sessionSummary, text: "oldest summary", minutesAfterEpochBase: 1)

        repository.append(newestSummary)
        repository.append(middleSummary)
        repository.append(oldestSummary)

        #expect(repository.loadAll().map(\.text) == ["oldest summary", "middle summary", "newest summary"])
    }

    @Test func emptyFreshStoreLoadsAsEmpty() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { removeTemporaryFile(at: storeFileURL) }

        let repository = FileMemoryRepository(fileURL: storeFileURL)

        #expect(repository.loadAll().isEmpty)
    }

    // MARK: - Persistence across instances

    @Test func newInstanceReadingSameFileSeesPriorAppends() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { removeTemporaryFile(at: storeFileURL) }

        let firstInstance = FileMemoryRepository(fileURL: storeFileURL)
        let preference = makeItem(kind: .preference, text: "prefers concise answers", minutesAfterEpochBase: 1)
        firstInstance.append(preference)

        let secondInstance = FileMemoryRepository(fileURL: storeFileURL)
        #expect(secondInstance.loadAll() == [preference])
    }

    @Test func deletePersistsAcrossInstancesAndDeleteAllEmptiesTheFile() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { removeTemporaryFile(at: storeFileURL) }

        let writerInstance = FileMemoryRepository(fileURL: storeFileURL)
        let keepMe = makeItem(kind: .projectFact, text: "uses Swift Testing", minutesAfterEpochBase: 1)
        let deleteMe = makeItem(kind: .projectFact, text: "legacy note", minutesAfterEpochBase: 2)
        writerInstance.append(keepMe)
        writerInstance.append(deleteMe)

        // Delete exactly one record via a fresh reader to prove persistence.
        FileMemoryRepository(fileURL: storeFileURL).delete(id: deleteMe.id)

        let afterDelete = FileMemoryRepository(fileURL: storeFileURL).loadAll()
        #expect(afterDelete == [keepMe])

        FileMemoryRepository(fileURL: storeFileURL).deleteAll()

        // Emptiness must itself be persisted: a brand-new instance must see
        // an empty store, not resurrect the pre-deleteAll contents.
        let afterDeleteAll = FileMemoryRepository(fileURL: storeFileURL).loadAll()
        #expect(afterDeleteAll.isEmpty)
    }

    // MARK: - Delete

    @Test func deleteRemovesExactlyOneRecordById() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { removeTemporaryFile(at: storeFileURL) }

        let repository = FileMemoryRepository(fileURL: storeFileURL)
        let firstItem = makeItem(kind: .preference, text: "first", minutesAfterEpochBase: 1)
        let secondItem = makeItem(kind: .preference, text: "second", minutesAfterEpochBase: 2)
        let thirdItem = makeItem(kind: .projectFact, text: "third", minutesAfterEpochBase: 3)
        repository.append(firstItem)
        repository.append(secondItem)
        repository.append(thirdItem)

        repository.delete(id: secondItem.id)

        let remainingItems = repository.loadAll()
        #expect(remainingItems.count == 2)
        #expect(remainingItems.map(\.text) == ["first", "third"])
        #expect(!remainingItems.contains(where: { $0.id == secondItem.id }))
    }

    @Test func deleteWithUnknownIdLeavesStoreUnchanged() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { removeTemporaryFile(at: storeFileURL) }

        let repository = FileMemoryRepository(fileURL: storeFileURL)
        let onlyItem = makeItem(kind: .preference, text: "only", minutesAfterEpochBase: 1)
        repository.append(onlyItem)

        repository.delete(id: UUID())

        #expect(repository.loadAll() == [onlyItem])
    }

    // MARK: - Session summary trimming

    @Test func trimmingKeepsNewestSessionSummariesUpToCap() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { removeTemporaryFile(at: storeFileURL) }

        let maximumSummaries = 3
        let repository = FileMemoryRepository(fileURL: storeFileURL, maxSessionSummaries: maximumSummaries)

        for minuteOffset in 1...5 {
            let summary = makeItem(
                kind: .sessionSummary,
                text: "summary \(minuteOffset)",
                minutesAfterEpochBase: minuteOffset
            )
            repository.append(summary)
        }

        let survivingSummaries = repository.loadAll()
        #expect(survivingSummaries.count == maximumSummaries)
        // Oldest three must be gone; newest three must survive in order.
        #expect(survivingSummaries.map(\.text) == ["summary 3", "summary 4", "summary 5"])
    }

    @Test func trimmingNeverTouchesPreferencesOrProjectFacts() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { removeTemporaryFile(at: storeFileURL) }

        // Cap of 1 while appending many durable records proves trimming is
        // scoped strictly to session summaries.
        let repository = FileMemoryRepository(fileURL: storeFileURL, maxSessionSummaries: 1)

        for minuteOffset in 1...4 {
            repository.append(makeItem(kind: .preference, text: "preference \(minuteOffset)", minutesAfterEpochBase: minuteOffset))
            repository.append(makeItem(kind: .projectFact, text: "fact \(minuteOffset)", minutesAfterEpochBase: minuteOffset))
            repository.append(makeItem(kind: .sessionSummary, text: "summary \(minuteOffset)", minutesAfterEpochBase: minuteOffset))
        }

        let allMemories = repository.loadAll()
        #expect(allMemories.filter { $0.kind == .preference }.count == 4)
        #expect(allMemories.filter { $0.kind == .projectFact }.count == 4)
        // Compare by text: MemoryItem equality includes the UUID, and a
        // rebuilt fixture would carry a different id than the survivor.
        #expect(allMemories.filter { $0.kind == .sessionSummary }.map(\.text) == ["summary 4"])
        #expect(allMemories.count == 9)
    }

    @Test func trimmingResultSurvivesIntoANewInstance() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { removeTemporaryFile(at: storeFileURL) }

        let writerInstance = FileMemoryRepository(fileURL: storeFileURL, maxSessionSummaries: 2)
        for minuteOffset in 1...4 {
            writerInstance.append(makeItem(kind: .sessionSummary, text: "summary \(minuteOffset)", minutesAfterEpochBase: minuteOffset))
        }
        writerInstance.append(makeItem(kind: .preference, text: "durable", minutesAfterEpochBase: 10))

        let freshReader = FileMemoryRepository(fileURL: storeFileURL)
        let reloadedMemories = freshReader.loadAll()
        #expect(reloadedMemories.count == 3)
        #expect(reloadedMemories.filter { $0.kind == .sessionSummary }.map(\.text) == ["summary 3", "summary 4"])
    }

    // MARK: - Corrupt-file resilience

    @Test func corruptFileLoadsAsEmptyInsteadOfCrashing() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { removeTemporaryFile(at: storeFileURL) }

        // Garbage bytes simulate any unreadable/damaged file on disk.
        try? Data("not json at all {{{".utf8).write(to: storeFileURL)

        let repository = FileMemoryRepository(fileURL: storeFileURL)

        #expect(repository.loadAll().isEmpty)
    }

    @Test func storeHealsCorruptFileOnNextAppend() {
        let storeFileURL = makeTemporaryStoreFileURL()
        defer { removeTemporaryFile(at: storeFileURL) }

        try? Data("\u{0}\u{1}\u{2} garbage".utf8).write(to: storeFileURL)
        let repository = FileMemoryRepository(fileURL: storeFileURL)

        let recoveredItem = makeItem(kind: .preference, text: "written over corruption", minutesAfterEpochBase: 1)
        repository.append(recoveredItem)

        let freshReader = FileMemoryRepository(fileURL: storeFileURL)
        #expect(freshReader.loadAll() == [recoveredItem])
    }

    // MARK: - Privacy invariant (structural)

    @Test func memoryItemCarriesNoBinaryPayloadFields() {
        // Guards the invariant by construction: if someone adds an image or
        // audio field to MemoryItem, this round-trip through Codable still
        // compiles — but the encoded payload of a text-only item can no
        // longer grow keys beyond these four without failing this check.
        let item = makeItem(kind: .sessionSummary, text: "text only", minutesAfterEpochBase: 1)
        let encodedData = try? JSONEncoder().encode(item)
        let decodedKeys = (try? JSONSerialization.jsonObject(with: encodedData ?? Data())) as? [String: Any]

        let encodedKeys = decodedKeys.map { Set($0.keys) } ?? []
        #expect(encodedKeys == Set(["id", "kind", "text", "createdAt"]))
    }
}
