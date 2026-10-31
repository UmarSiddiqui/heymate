//
//  NotesSnapshotTests.swift
//  HeyMateTests
//
//  Offscreen PNG renders of the notes views. Opt-in via HEYMATE_SNAPSHOT_DIR.
//

import SwiftUI
import Testing
@testable import HeyMate

@MainActor
struct NotesSnapshotTests {
    nonisolated private static var enabled: Bool { ProcessInfo.processInfo.environment["HEYMATE_SNAPSHOT_DIR"] != nil }
    private static let size = CGSize(width: 960, height: 640)

    private static func board() -> Page {
        let a = NoteCanvas.sticky(x: 40, y: 40, words: "Ship the notes canvas", color: "butter")
        let b = NoteCanvas.paper(x: 300, y: 50, title: "Plan", heading: "Launch week", subtitle: "three things to land")
        let c = NoteCanvas.clipping(x: 40, y: 270, title: "Fact", body: "Octopuses have three hearts.", source: "oceanic.org")
        let d = NoteCanvas.receipt(x: 360, y: 300, title: "Groceries", items: ["Oat milk", "Limes", "Coffee"])
        let e = NoteCanvas.photo(x: 640, y: 60, query: "harbour", caption: "Harbour, 6am", tilt: -4)
        let f = NoteCanvas.sticky(x: 640, y: 340, words: "Call Sam", color: "sky")
        return Page(name: "Board", isBoard: true, blocks: [a, b, c, d, e, f, NoteCanvas.tie(from: a, to: b), NoteCanvas.tie(from: d, to: f, bend: -0.3)])
    }

    private struct Holder: View {
        @State var page: Page
        var body: some View { NoteCanvasView(page: $page).background(DS.Colors.background) }
    }
    private struct EditorHolder: View {
        @State var page: Page
        var body: some View { NoteBlockEditor(page: $page).background(DS.Colors.background) }
    }

    private static func routines() -> [MateRoutine] {
        func r(_ task: String, _ s: RoutineSchedule, paused: String? = nil, fails: Int = 0, runs: Int) -> MateRoutine {
            MateRoutine(id: UUID(), mateID: UUID(), task: task, enabled: true, schedule: s,
                        nextRunAt: Date().addingTimeInterval(5_400), lastRunAt: nil, lastStatusMessage: nil,
                        consecutiveFailures: fails, pausedReason: paused, runCount: runs)
        }
        return [r("Summarise my inbox", .daily(hour: 8, minute: 0), runs: 31),
                r("Watch the build", .everyHours(2), runs: 12),
                r("Pull competitor news", .everyHours(6), paused: "Paused after 3 failures", fails: 3, runs: 4),
                r("Water the plants nudge", .everyHours(24), paused: MateRoutineAccounting.manualPauseReason, runs: 2)]
    }

    @Test(.enabled(if: enabled)) func canvas() throws {
        try UISnapshotTests.render(Holder(page: Self.board()), size: Self.size, dark: true, name: "notes-canvas")
    }

    @Test(.enabled(if: enabled)) func blockEditor() throws {
        let page = Page(blocks: [
            Block(kind: .heading, attributes: ["text": "Trip to Lisbon"]),
            Block(kind: .paragraph, attributes: ["text": "Flights land Friday evening; stay in Alfama."]),
            Block(kind: .quote, attributes: ["text": "Not all those who wander are lost."]),
            Block(kind: .todo, items: [Item(text: "Book flights", isChecked: true), Item(text: "Find a tram pass", isChecked: false)]),
            Block(kind: .table, items: [Item(items: [Item(text: "Fri"), Item(text: "Arrive")]), Item(items: [Item(text: "Sat"), Item(text: "Sintra")])], columns: ["Day", "Plan"]),
            Block(kind: .event, attributes: ["title": "Dinner at Taberna", "date": "Sat 8pm", "place": "Rua da Rosa"]),
            Block(kind: .drawing, attributes: ["strokes": "10,100 40,40 80,100 120,40 160,100"]),
        ])
        try UISnapshotTests.render(EditorHolder(page: page), size: Self.size, dark: true, name: "notes-editor")
    }

    @Test(.enabled(if: enabled)) func dashboard() throws {
        let board = DashboardBoard.routines(Self.routines().enumerated().map { RoutineControl($1, isRunning: $0 == 1) })
        try UISnapshotTests.render(DashboardBoardView(board: board), size: Self.size, dark: true, name: "notes-dashboard")
    }

    @Test(.enabled(if: enabled)) func routineEditor() throws {
        try UISnapshotTests.render(RoutineEditorView(routines: Self.routines()), size: Self.size, dark: true, name: "notes-routine-editor")
    }
}
