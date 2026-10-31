//
//  NoteListView.swift
//  HeyMate
//
//  HeyMate's own notes list: shows all notes, lets you open one, create a new
//  one, or delete one. HeyMate's own SwiftUI — modeled on ReferenceRenderer's notes
//  list but not copied from it.
//

import SwiftUI

struct NoteListView: View {
    @ObservedObject var store: NoteStore
    var routines: [MateRoutine] = []
    var runningRoutineID: UUID?
    var routineActions = RoutineActions()

    enum Selection: Hashable { case note(UUID), dashboard, routines }
    @State private var selection: Selection?
    @State private var showingNewNote = false
    @State private var newTitle = ""

    private var boards: [Note] { store.notes.filter { $0.document?.pages.contains { $0.isBoard } == true && $0.document?.pages.count == 1 } }
    private var documents: [Note] { store.notes.filter { n in !boards.contains { $0.id == n.id } } }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 250)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 420)
        .sheet(isPresented: $showingNewNote) {
            NewNoteSheet(store: store, showing: $showingNewNote, title: $newTitle)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notes").font(DS.Fonts.title).foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Menu {
                    Button("New note") { showingNewNote = true }
                    Button("New board") { if let b = try? store.createBoard() { selection = .note(b.id) } }
                } label: { Image(systemName: "square.and.pencil").foregroundColor(DS.Colors.textPrimary) }
                .menuStyle(.borderlessButton).fixedSize().help("New note or board")
            }
            .padding(DS.Spacing.md)
            List(selection: $selection) {
                Section("Overview") {
                    Label("Dashboard", systemImage: "square.grid.2x2").tag(Selection.dashboard)
                    Label("Routines", systemImage: "clock.arrow.circlepath").tag(Selection.routines)
                }
                if !boards.isEmpty { Section("Boards") { ForEach(boards) { row($0, symbol: "rectangle.on.rectangle.angled") } } }
                Section("Notes") {
                    ForEach(documents) { row($0, symbol: "doc.text") }
                    if documents.isEmpty { Text("No notes yet").font(DS.Fonts.caption).foregroundColor(DS.Colors.textTertiary) }
                }
            }
            .listStyle(.sidebar)
        }
        .background(DS.Colors.surface1)
    }

    private func row(_ note: Note, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundColor(DS.Colors.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title).font(DS.Fonts.body).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                if note.isPreview == true {
                    Text("Writing…").font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                } else {
                    Text(preview(note)).font(DS.Fonts.caption).foregroundColor(DS.Colors.textTertiary).lineLimit(1)
                }
            }
        }
        .tag(Selection.note(note.id))
        .contextMenu {
            Button("Delete", role: .destructive) {
                try? store.delete(note.id)
                if selection == .note(note.id) { selection = nil }
            }
        }
    }

    private func preview(_ note: Note) -> String {
        if let line = note.markdown.flatMap(NoteMarkdownView.previewLine) { return line }
        if let doc = note.document {
            if doc.pages.first?.isBoard == true { return "\(NoteCanvas.cards(doc.pages[0]).count) cards" }
            if let text = doc.pages.flatMap(\.blocks).first(where: { !$0.text.isEmpty })?.text { return text }
        }
        return "Empty note"
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .dashboard:
            DashboardBoardView(board: .routines(routines.map { RoutineControl($0, isRunning: $0.id == runningRoutineID) }))
        case .routines:
            RoutineEditorView(routines: routines, runningID: runningRoutineID, actions: routineActions)
        case .note(let id):
            if let note = store.notes.first(where: { $0.id == id }) {
                if let markdown = note.markdown { NoteMarkdownView(markdown: markdown) }
                else { NoteDetailView(store: store, note: note).id(id) }
            }
        case nil:
            Text("Select a note").font(DS.Fonts.body).foregroundColor(DS.Colors.textSecondary)
        }
    }
}

/// Sheet for creating a new note.
private struct NewNoteSheet: View {
    @ObservedObject var store: NoteStore
    @Binding var showing: Bool
    @Binding var title: String

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            Text("New Note")
                .font(DS.Fonts.title)
                .foregroundColor(DS.Colors.textPrimary)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(DS.Fonts.body)
            HStack {
                Button("Cancel") {
                    title = ""
                    showing = false
                }
                .buttonStyle(.bordered)
                Button("Create") {
                    try? store.create(title: title.isEmpty ? "Untitled Note" : title)
                    title = ""
                    showing = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(DS.Spacing.lg)
        .frame(width: 400)
    }
}
