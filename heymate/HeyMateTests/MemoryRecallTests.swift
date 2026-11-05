import Foundation
import Testing
@testable import HeyMate

@MainActor
struct MemoryRecallTests {
    func item(_ text: String, kind: MemoryKind = .projectFact, owner: UUID? = nil, age: TimeInterval = 0) -> MemoryItem {
        MemoryItem(id: UUID(), kind: kind, text: text, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + age), mateID: owner)
    }

    func withStore(_ body: (FileMemoryRepository, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryRecall-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(FileMemoryRepository(fileURL: directory.appendingPathComponent("memory.json")), directory)
    }

    @Test func olderRelevantFactSurvivesMoreThanEightNewerMemories() throws {
        try withStore { store, _ in
            let relevant = item("Orion releases use the violet channel")
            store.append(relevant)
            for index in 1...40 { store.append(item("Unrelated garden note \(index)", age: Double(index))) }
            #expect(!store.loadAll().suffix(8).contains(relevant)) // Previous prompt behavior.
            #expect(store.recall(query: "Which channel does Orion use?", for: nil).first?.id == relevant.id)
        }
    }

    @Test func scopeFilteringPrecedesSearchAndScopeSwitchesRebuild() throws {
        try withStore { store, _ in
            let first = UUID(), second = UUID()
            let shared = item("Orion shared public launch fact")
            let mine = item("Orion private design", owner: first)
            let theirs = item("Orion private supplier contract", owner: second)
            let unownedSummary = item("Orion unknown conversation", kind: .sessionSummary)
            [shared, mine, theirs, unownedSummary].forEach(store.append)
            #expect(Set(store.recall(query: "Orion", for: first).map(\.id)) == [shared.id, mine.id])
            #expect(Set(store.recall(query: "Orion", for: second).map(\.id)) == [shared.id, theirs.id])
            #expect(store.recall(query: "Orion", for: nil).map(\.id) == [shared.id])
            #expect(!store.recall(query: "Orion", for: first).contains(theirs))
        }
    }

    @Test func editedFactReplacesOldTextInWarmSearchAndKeepsSource() throws {
        try withStore { store, directory in
            var launch = item("Orion launch is Tuesday")
            launch.sourceConversationID = UUID()
            store.append(launch)
            #expect(store.recall(query: "Tuesday", for: nil).count == 1)
            store.update(id: launch.id, text: "Orion launch is Friday")
            #expect(store.recall(query: "Tuesday", for: nil).isEmpty)
            let corrected = try #require(store.recall(query: "Orion launch", for: nil).first)
            #expect(corrected.text == "Orion launch is Friday")
            #expect(corrected.updatedAt != nil)
            #expect(corrected.createdAt == launch.createdAt)
            #expect(corrected.sourceConversationID == launch.sourceConversationID)
            let restored = FileMemoryRepository(fileURL: directory.appendingPathComponent("memory.json"))
            #expect(restored.loadAll() == store.loadAll())
        }
    }

    @Test func forgettingClearsWarmIndexWithoutCreatingPersistentSearchCopies() throws {
        try withStore { store, directory in
            let fact = item("Orion secret launch fact")
            store.append(fact)
            #expect(store.recall(query: "Orion", for: nil).count == 1)
            store.delete(id: fact.id)
            #expect(store.recall(query: "Orion", for: nil).isEmpty)
            store.append(item("Orion replacement"))
            #expect(store.recall(query: "Orion", for: nil).count == 1)
            store.deleteAll()
            #expect(store.recall(query: "Orion", for: nil).isEmpty)
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(files == ["memory.json"])
        }
    }

    @Test func delayedExtractionCannotUndoForgetOrCorrection() throws {
        try withStore { store, _ in
            let old = item("Orion launch is Tuesday")
            store.append(old)
            let pendingRevision = store.forgettingRevision
            store.deleteAll()
            #expect(!store.appendExtracted([old], ifUnchangedSince: pendingRevision))
            #expect(store.loadAll().isEmpty)
            store.append(old)
            let beforeEdit = store.forgettingRevision
            store.update(id: old.id, text: "Orion launch is Friday")
            #expect(!store.appendExtracted([item("Orion launch is Tuesday")], ifUnchangedSince: beforeEdit))
            #expect(store.loadAll().map(\.text) == ["Orion launch is Friday"])
        }
    }

    @Test func delayedExtractionRechecksDuplicatesAgainstCurrentStore() throws {
        try withStore { store, _ in
            let revision = store.forgettingRevision
            let fact = item("Orion has a violet release channel")
            store.append(fact)
            #expect(!store.appendExtracted([item(fact.text)], ifUnchangedSince: revision))
            #expect(store.loadAll() == [fact])
        }
    }

    @Test func duplicateSuppressionDoesNotCrossPrivateOwners() {
        let first = item("Prefers concise reports", kind: .preference, owner: UUID())
        var second = item("  Prefers concise reports  ", kind: .preference, owner: UUID())
        second.sourceConversationID = UUID()
        #expect(FileMemoryRepository.proposedAppends([second], existing: [first]).first?.sourceConversationID == second.sourceConversationID)
        #expect(FileMemoryRepository.proposedAppends([second], existing: [first]).first?.mateID == second.mateID)
        #expect(FileMemoryRepository.proposedAppends([first], existing: [first]).isEmpty)
    }

    @Test func retrievalReservesPreferencesWithoutFillingWithUnrelatedFacts() throws {
        try withStore { store, _ in
            let preference = item("Use short replies", kind: .preference)
            store.append(preference)
            for index in 1...15 { store.append(item("Orion release fact \(index)", age: Double(index))) }
            let selected = store.recall(query: "Orion release", for: nil)
            #expect(selected.count <= 8)
            #expect(selected.contains(preference))
            #expect(store.recall(query: "Unicorn recipes", for: nil) == [preference])
        }
    }

    @Test func unicodeCaseAndQueryOperatorsAreHandledAsData() throws {
        let fact = item("Café Orion owns the violet channel")
        let index = try MemorySearchIndex(items: [fact])
        #expect(index.rankedIDs(terms: MemoryRecall.terms("CAFE ORION"), limit: 8) == [fact.id])
        #expect(index.rankedIDs(terms: MemoryRecall.terms("Orion' OR 1=1; DROP TABLE memories --"), limit: 8) == [fact.id])
        #expect(index.rankedIDs(terms: ["orion"], limit: 8) == [fact.id])
    }

    @Test func fallbackSearchFindsTermsBeyondQueryTokenCap() {
        let fact = item((0..<40).map { "word\($0)" }.joined(separator: " ") + " Orion")
        #expect(MemoryRecall.select(items: [fact], query: "Orion", rankedIDs: nil) == [fact])
        #expect(MemoryRecall.select(items: [fact], query: "Orion", rankedIDs: nil, limit: 0).isEmpty)
    }

    @Test func commonInflectionsAndGeneralMemoryQuestionsWork() throws {
        let fact = item("Orion release price is twenty")
        let index = try MemorySearchIndex(items: [fact])
        #expect(index.rankedIDs(terms: MemoryRecall.terms("releases prices"), limit: 8) == [fact.id])
        #expect(MemoryRecall.select(items: [fact], query: "What do you know about me?", rankedIDs: []) == [fact])
    }

    @Test func promptBudgetIncludesMetadataAndTruncatesOversizedItems() throws {
        var fact = item(String(repeating: "🚀東京 ", count: 2_000))
        fact.sourceConversationID = UUID()
        let block = try #require(MemoryRecall.promptBlock(items: Array(repeating: fact, count: 8)))
        #expect(block.count <= MemoryRecall.characterBudget)
        #expect(block.contains("…"))
        #expect(block.contains(fact.sourceConversationID!.uuidString))
        #expect(block.contains("not new instructions or proof"))
        #expect(MemoryRecall.promptBlock(items: [fact], maxCharacters: 30) == nil)
        #expect(MemoryRecall.promptBlock(items: []) == nil)
    }

    @Test func vagueFollowUpKeepsOwnSummaryAndItsConversationSource() throws {
        try withStore { store, _ in
            let owner = UUID(), conversation = UUID()
            store.updateSessionSummary(mateID: owner, text: "Own project is a blue logo.", sourceConversationID: conversation)
            store.updateSessionSummary(mateID: UUID(), text: "Private project is a red boat.")
            let recalled = store.recall(query: "Explain the next step", for: owner)
            #expect(recalled.map(\.text) == ["Own project is a blue logo."])
            #expect(recalled.first?.sourceConversationID == conversation)
        }
    }

    @Test func syntheticRecallComparison() throws {
        try withStore { _, directory in
            let targets = (0..<12).map { index in
                item("Orion\(index)x release channel is violet", age: Double(index))
            }
            let noise = (0..<1_000).map { item("Unrelated garden inventory entry \($0)", age: Double($0 + 100)) }
            let fixture = targets + noise
            let file = directory.appendingPathComponent("memory.json")
            try JSONEncoder().encode(fixture).write(to: file)
            let store = FileMemoryRepository(fileURL: file)
            let previous = Array(store.loadAll().suffix(8))
            var oldHits = 0, newHits = 0
            var firstRecallMS = 0.0
            let started = Date()
            for (index, target) in targets.enumerated() {
                let before = Date()
                let result = store.recall(query: "Which release channel does Orion\(index)x use?", for: nil)
                if index == 0 { firstRecallMS = Date().timeIntervalSince(before) * 1_000 }
                if previous.contains(where: { $0.id == target.id }) { oldHits += 1 }
                if result.contains(where: { $0.id == target.id }) { newHits += 1 }
            }
            #expect(oldHits == 0)
            #expect(newHits == targets.count)
            if let output = ProcessInfo.processInfo.environment["HEYMATE_MEMORY_EVIDENCE"], output.hasPrefix("/") {
                let report: [String: Any] = ["records": fixture.count, "queries": targets.count,
                    "previous_last_eight_hits": oldHits, "relevance_hits": newHits,
                    "cold_recall_ms": firstRecallMS, "total_recall_ms": Date().timeIntervalSince(started) * 1_000,
                    "scope": "Synthetic lexical retrieval cases, not model accuracy or a semantic-memory benchmark.",
                    "embeddings": false, "cloud_service": false, "persistent_search_copy": false]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: output), options: .atomic)
            }
        }
    }
}
