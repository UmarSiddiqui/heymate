//
//  NoteDocumentTests.swift
//  HeyMateTests
//
//  Notes canvas model, migration, card operations, routine control. Store
//  tests go through NoteStore.shared, which HeyMateDataDirectory points at a
//  throwaway folder while hosting tests.
//

import Foundation
import Testing
@testable import HeyMate

struct NoteDocumentTests {
    private func routine(_ schedule: RoutineSchedule = .everyHours(2), paused: String? = nil, failures: Int = 0) -> MateRoutine {
        MateRoutine(id: UUID(), mateID: UUID(), task: "Check the inbox", enabled: true, schedule: schedule,
                    nextRunAt: Date(timeIntervalSince1970: 1_800_000_000), lastRunAt: nil, lastStatusMessage: nil,
                    consecutiveFailures: failures, pausedReason: paused, runCount: 7)
    }

    @Test func knownKindsAre46AndUnique() {
        #expect(BlockKind.known.count == 46)
        #expect(Set(BlockKind.known).count == 46)
    }

    @Test func unknownKindSurvivesRoundTrip() throws {
        let json = #"{"id":"6E1F2B9A-0000-4000-8000-000000000001","kind":"hologram","attributes":{"x":"1"},"future":42}"#
        let block = try JSONDecoder().decode(Block.self, from: Data(json.utf8))
        #expect(block.kind.rawValue == "hologram")
        #expect(block.kind.isKnown == false)
        let back = try JSONDecoder().decode(Block.self, from: JSONEncoder().encode(block))
        #expect(back == block)
    }

    @Test func missingFieldsTakeDefaults() throws {
        let doc = try JSONDecoder().decode(NoteDocument.self, from: Data("{}".utf8))
        #expect(doc.pages.count == 1)
        let item = try JSONDecoder().decode(Item.self, from: Data(#"{"text":"hi"}"#.utf8))
        #expect(item.isChecked == nil && item.items.isEmpty)
    }

    @Test func recursiveItemsRoundTrip() throws {
        let item = Item(text: "a", items: [Item(text: "b", items: [Item(text: "c", isChecked: true, url: "u", number: 3)])])
        let back = try JSONDecoder().decode(Item.self, from: JSONEncoder().encode(item))
        #expect(back == item)
    }

    @Test func legacyNoteMigratesWithoutLosingBlocks() throws {
        let legacy = [
            NoteBlock(kind: .text, content: "hello"),
            NoteBlock(kind: .todo, content: "buy milk"),
            NoteBlock(kind: .ink, content: "1,2 3,4"),
            NoteBlock(kind: .table, content: "", children: [NoteBlock(kind: .text, content: "a\tb")]),
        ]
        var note = Note(title: "Old", blocks: legacy)
        let json = try JSONEncoder().encode(note)
        // A file written before the canvas has no version and no document.
        note = try JSONDecoder().decode(Note.self, from: json)
        #expect(note.document == nil && note.version == nil)

        let migrated = try #require(NoteStore.migrated(note))
        let blocks = try #require(migrated.document?.pages.first?.blocks)
        #expect(blocks.count == 4)
        #expect(blocks.map(\.kind) == [.paragraph, .todo, .drawing, .table])
        #expect(blocks[0].text == "hello")
        #expect(blocks[1].items.first?.text == "buy milk")
        #expect(blocks[2].attributes["strokes"] == "1,2 3,4")
        #expect(blocks[3].items.first?.items.map(\.text) == ["a", "b"])
        #expect(migrated.blocks == legacy)           // legacy copy kept for rollback
        #expect(migrated.version == NoteDocument.currentVersion)
        #expect(NoteStore.migrated(migrated) == nil) // idempotent
    }

    @Test func agentMarkdownNotesAreNotMigrated() {
        #expect(NoteStore.migrated(Note(title: "m", markdown: "# m")) == nil)
    }

    @MainActor @Test func storeCreatesAndUpdatesDocuments() throws {
        let store = NoteStore.shared
        let note = try store.createBoard(title: "Test board \(UUID().uuidString.prefix(6))")
        defer { try? store.delete(note.id) }
        #expect(note.document?.pages.first?.isBoard == true)
        var doc = try #require(store.notes.first { $0.id == note.id }?.document)
        doc.pages[0].blocks.append(NoteCanvas.sticky(x: 10, y: 20, words: "hi", color: "mint"))
        try store.updateDocument(doc, for: note.id)
        #expect(try store.note(note.id).document == doc)
        let onDisk = try Data(contentsOf: HeyMateDataDirectory.url.appendingPathComponent("Notes/\(note.id.uuidString).json"))
        #expect(String(decoding: onDisk, as: UTF8.self).contains("\"version\" : 2"))
    }

    // MARK: Canvas

    @Test func cardConstructorsMatchContract() {
        let sticky = NoteCanvas.sticky(x: 1, y: 2, words: "w", color: "chartreuse")
        #expect(sticky.attributes["color"] == "butter")   // unknown stock falls back
        #expect(NoteCanvas.frame(of: sticky).w == 170 && NoteCanvas.frame(of: sticky).h == 170)
        let receipt = NoteCanvas.receipt(x: 0, y: 0, title: "t", items: ["a", "b"])
        #expect(receipt.items.map(\.text) == ["a", "b"])
        let photo = NoteCanvas.photo(x: 0, y: 0, query: "cat", tilt: 4, web: true)
        #expect(photo.attributes["web"] == "true" && photo.attributes["tilt"] == "4")
    }

    @Test func moveZoomCloseAndTies() {
        let a = NoteCanvas.sticky(x: 0, y: 0, words: "a"), b = NoteCanvas.paper(x: 300, y: 0, title: "p")
        let c = NoteCanvas.photo(x: 0, y: 300, query: "q")
        var page = Page(isBoard: true, blocks: [a, b, c, NoteCanvas.tie(from: a, to: b), NoteCanvas.tie(from: a, to: c)])
        #expect(NoteCanvas.cards(page).count == 5)

        page = NoteCanvas.moveCard(page, id: a.id, to: (50, 60))
        #expect(NoteCanvas.frame(of: page.blocks[0]).x == 50 && NoteCanvas.frame(of: page.blocks[0]).y == 60)
        page = NoteCanvas.zoomCard(page, id: a.id, to: 9)
        #expect(NoteCanvas.zoom(of: page.blocks[0]) == 3)
        page = NoteCanvas.zoomCard(page, id: a.id, to: 0.1)
        #expect(NoteCanvas.zoom(of: page.blocks[0]) == 0.5)

        let closed = NoteCanvas.closeCard(page, id: c.id)
        #expect(closed.blocks.count == 3)  // photo and its tie are gone
        let notes = NoteCanvas.keepNotesOnly(page)
        #expect(notes.blocks.map(\.kind) == [.sticky, .paper, BlockKind("tie")])
    }

    // MARK: Dashboard and routines

    @Test func routineControlReadsRealRoutine() {
        let running = RoutineControl(routine(), isRunning: true)
        #expect(running.intervalMinutes == 120 && running.runCount == 7 && running.isRunning && !running.isPaused)
        #expect(RoutineControl(routine(.daily(hour: 8, minute: 0))).intervalMinutes == 1440)
        let broke = RoutineControl(routine(paused: "Paused after failures", failures: 3))
        #expect(broke.isPaused && broke.isPausedAfterFailures)
        let manual = RoutineControl(routine(paused: MateRoutineAccounting.manualPauseReason))
        #expect(manual.isPaused && !manual.isPausedAfterFailures)
    }

    @Test func dashboardRollsUpWorstStatus() {
        let board = DashboardBoard.routines([
            RoutineControl(routine()),
            RoutineControl(routine(paused: "x", failures: 3)),
        ])
        #expect(board.overall == .failed)
        #expect(board.sections.map(\.title) == ["Paused after failures", "Scheduled"])
        #expect(board.changes.count == 1)
        #expect(DashboardBoard.routines([]).overall == .idle)
    }
}
