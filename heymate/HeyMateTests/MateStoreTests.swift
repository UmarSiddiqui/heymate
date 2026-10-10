//
//  MateStoreTests.swift
//  HeyMateTests
//
//  Mate persistence. Writes into a unique temp directory.
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct MateStoreTests {

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MateStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func firstLoadSeedsFirstMate() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMateStore(fileURL: directory.appendingPathComponent("mates.json"))
        let mates = store.loadAll()
        #expect(mates.count == 1)
        #expect(mates[0].name == "First Mate")
        #expect(mates[0].job == Mate.defaultJob)
        #expect(mates[0].conductsOthers)
        #expect(mates[0].pinned)
        #expect(mates[0].id == store.defaultMateID)
        #expect(mates[0].folderPath == nil)

        let reloaded = FileMateStore(fileURL: directory.appendingPathComponent("mates.json"))
        #expect(reloaded.defaultMateID == store.defaultMateID)
        #expect(reloaded.loadAll().map(\.name) == ["First Mate"])
    }

    @Test func stockHeyMateBecomesFirstMate() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("mates.json")
        let id = UUID()
        let now = Date()
        let stock = Mate(
            id: id,
            name: "HeyMate",
            job: "General chat",
            pinned: false,
            archived: false,
            unreadCount: 0,
            createdAt: now,
            updatedAt: now,
            memoryNote: "",
            folderPath: nil
        )
        let catalog = MateCatalogFile(defaultMateID: id, mates: [stock])
        let data = try? JSONEncoder().encode(catalog)
        try? data?.write(to: fileURL)
        let store = FileMateStore(fileURL: fileURL)
        let mate = store.loadAll()[0]
        #expect(mate.name == "First Mate")
        #expect(mate.conductsOthers)
        #expect(mate.pinned)
        #expect(mate.id == id)
    }

    @Test func renamedDefaultMateKeepsItsNameAndConducts() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("mates.json")
        let id = UUID()
        let now = Date()
        let custom = Mate(
            id: id,
            name: "HeyMate",
            job: "Keeps my inbox honest",
            pinned: false,
            archived: false,
            unreadCount: 0,
            createdAt: now,
            updatedAt: now,
            memoryNote: "",
            folderPath: nil
        )
        let catalog = MateCatalogFile(defaultMateID: id, mates: [custom])
        try? JSONEncoder().encode(catalog).write(to: fileURL)
        let store = FileMateStore(fileURL: fileURL)
        let mate = store.loadAll()[0]
        #expect(mate.name == "HeyMate")
        #expect(mate.job == "Keeps my inbox honest")
        #expect(mate.conductsOthers)
    }

    @Test func namesAreUniqueIgnoringCaseAmongActiveMates() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMateStore(fileURL: directory.appendingPathComponent("mates.json"))
        let now = Date()
        let taken = Mate(
            id: UUID(),
            name: "Inbox Scout",
            job: "Watch the inbox",
            pinned: false,
            archived: false,
            unreadCount: 0,
            createdAt: now,
            updatedAt: now,
            memoryNote: "",
            folderPath: nil
        )
        #expect(store.upsert(taken))
        #expect(store.isNameTaken("inbox scout"))
        let duplicate = Mate(
            id: UUID(),
            name: "INBOX SCOUT",
            job: "Again",
            pinned: false,
            archived: false,
            unreadCount: 0,
            createdAt: now,
            updatedAt: now,
            memoryNote: "",
            folderPath: nil
        )
        #expect(store.upsert(duplicate) == false)
        #expect(store.loadAll().filter { !$0.archived }.count == 2)
    }

    @Test func archiveKeepsTheRecord() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMateStore(fileURL: directory.appendingPathComponent("mates.json"))
        let seeded = store.loadAll()[0]
        store.archive(id: seeded.id)
        #expect(store.loadAll().first?.archived == false)
        let now = Date()
        let other = Mate(
            id: UUID(),
            name: "Inbox Scout",
            job: "Watch the inbox",
            pinned: false,
            archived: false,
            unreadCount: 0,
            createdAt: now,
            updatedAt: now,
            memoryNote: "",
            folderPath: nil
        )
        #expect(store.upsert(other))
        store.archive(id: other.id)
        #expect(store.mate(id: other.id)?.archived == true)
        #expect(store.isNameTaken(other.name) == false)
    }

    @Test func deleteNonDefaultRemovesIt() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMateStore(fileURL: directory.appendingPathComponent("mates.json"))
        let seeded = store.loadAll()[0]
        let otherID = UUID()
        let now = Date()
        let other = Mate(
            id: otherID,
            name: "Inbox Scout",
            job: "Watch the inbox",
            pinned: false,
            archived: false,
            unreadCount: 0,
            createdAt: now,
            updatedAt: now,
            memoryNote: "",
            folderPath: nil
        )
        #expect(store.upsert(other))
        #expect(store.delete(id: otherID))
        #expect(store.mate(id: otherID) == nil)
        #expect(store.defaultMateID == seeded.id)
        #expect(store.loadAll().count == 1)
    }

    @Test func deleteDefaultPromotesAnother() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMateStore(fileURL: directory.appendingPathComponent("mates.json"))
        let seeded = store.loadAll()[0]
        let now = Date()
        let olderID = UUID()
        let newerID = UUID()
        let archivedID = UUID()
        #expect(store.upsert(Mate(
            id: olderID,
            name: "Older",
            job: "Earlier",
            pinned: false,
            archived: false,
            unreadCount: 0,
            createdAt: now.addingTimeInterval(-30),
            updatedAt: now.addingTimeInterval(-20),
            memoryNote: "",
            folderPath: nil
        )))
        #expect(store.upsert(Mate(
            id: newerID,
            name: "Newer",
            job: "Later",
            pinned: false,
            archived: false,
            unreadCount: 0,
            createdAt: now,
            updatedAt: now.addingTimeInterval(20),
            memoryNote: "",
            folderPath: nil
        )))
        #expect(store.upsert(Mate(
            id: archivedID,
            name: "Shelved",
            job: "Paused",
            pinned: false,
            archived: true,
            unreadCount: 0,
            createdAt: now,
            updatedAt: now.addingTimeInterval(40),
            memoryNote: "",
            folderPath: nil
        )))
        #expect(store.delete(id: seeded.id))
        #expect(store.mate(id: seeded.id) == nil)
        #expect(store.defaultMateID == newerID)
        #expect(store.mate(id: newerID)?.conductsOthers == true)
        #expect(store.mate(id: archivedID)?.archived == true)
    }

    @Test func deleteLastMateSeedsAFreshDefault() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMateStore(fileURL: directory.appendingPathComponent("mates.json"))
        let seededID = store.loadAll()[0].id
        #expect(store.delete(id: seededID))
        let mates = store.loadAll()
        #expect(mates.count == 1)
        #expect(mates[0].id != seededID)
        #expect(mates[0].name == Mate.defaultName)
        #expect(mates[0].conductsOthers)
        #expect(store.defaultMateID == mates[0].id)
    }

    @Test func deleteUnknownIdIsANoOp() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMateStore(fileURL: directory.appendingPathComponent("mates.json"))
        let before = store.loadAll()
        #expect(store.delete(id: UUID()) == false)
        #expect(store.loadAll() == before)
        #expect(store.defaultMateID == before[0].id)
    }

    @Test func deleteLastActiveMateKeepsArchivedAndSeedsAFreshDefault() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileMateStore(fileURL: directory.appendingPathComponent("mates.json"))
        let seededID = store.loadAll()[0].id
        let archivedID = UUID()
        let now = Date()
        #expect(store.upsert(Mate(
            id: archivedID,
            name: "Paused Scout",
            job: "Waiting",
            pinned: false,
            archived: true,
            unreadCount: 0,
            createdAt: now,
            updatedAt: now,
            memoryNote: "",
            folderPath: nil
        )))
        #expect(store.delete(id: seededID))
        let mates = store.loadAll()
        #expect(mates.contains { $0.id == archivedID && $0.archived })
        let fresh = mates.first { !$0.archived }
        #expect(fresh?.name == Mate.defaultName)
        #expect(fresh?.id != seededID)
        #expect(store.defaultMateID == fresh?.id)
        #expect(mates.count == 2)
    }

    @Test func brainAndConnectorExclusionsRoundTrip() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("mates.json")
        let store = FileMateStore(fileURL: fileURL)
        var mate = store.loadAll()[0]
        mate.brainRawValue = "claudeCode"
        mate.connectorExclusionIDs = ["connector:gmail", "composio:slack"]
        #expect(store.upsert(mate))
        let reloaded = FileMateStore(fileURL: fileURL)
        let saved = reloaded.mate(id: mate.id)
        #expect(saved?.brainRawValue == "claudeCode")
        #expect(saved?.connectorExclusionIDs == ["connector:gmail", "composio:slack"])
    }

    @Test func oldMateJSONDecodesWithoutBrainOrExclusions() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let json = """
        {"defaultMateID":"\(id.uuidString)","mates":[{"archived":false,"createdAt":0,"id":"\(id.uuidString)","job":"Custom job","memoryNote":"","name":"Scout","pinned":false,"unreadCount":0,"updatedAt":0}]}
        """
        let fileURL = directory.appendingPathComponent("mates.json")
        try json.write(to: fileURL, atomically: true, encoding: .utf8)
        let store = FileMateStore(fileURL: fileURL)
        let mate = try #require(store.mate(id: id))
        #expect(mate.brainRawValue == nil)
        #expect(mate.connectorExclusionIDs == nil)
        #expect(mate.name == "Scout")
    }
}
