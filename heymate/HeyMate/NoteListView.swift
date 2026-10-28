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
    @State private var selectedID: UUID?
    @State private var showingNewNote = false
    @State private var newTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Notes")
                    .font(DS.Fonts.title)
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Button(action: { showingNewNote = true }) {
                    Image(systemName: "square.and.pencil")
                        .foregroundColor(DS.Colors.accent)
                }
                .buttonStyle(.plain)
                .help("New note")
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.md)

            Divider()

            // List
            if store.notes.isEmpty {
                VStack {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 40))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text("No notes yet")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("Create your first note to get started.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.notes, selection: $selectedID) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title)
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                        if note.isPreview == true {
                            Text("Writing…").font(DS.Fonts.caption).foregroundColor(DS.Colors.accent)
                        }
                        if let line = note.markdown.flatMap(NoteMarkdownView.previewLine) {
                            Text(line)
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.textTertiary)
                                .lineLimit(2)
                        } else if let first = note.blocks.first(where: { $0.kind == .text && !$0.content.isEmpty }) {
                            Text(first.content)
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.textTertiary)
                                .lineLimit(2)
                        } else {
                            Text("Empty note")
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                    }
                    .tag(note.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            try? store.delete(note.id)
                            if selectedID == note.id { selectedID = nil }
                        }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()

            // Detail
            if let selectedID, let note = store.notes.first(where: { $0.id == selectedID }) {
                if let markdown = note.markdown {
                    NoteMarkdownView(markdown: markdown)
                } else {
                    NoteDetailView(store: store, note: note)
                }
            } else {
                VStack {
                    Text("Select a note")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .sheet(isPresented: $showingNewNote) {
            NewNoteSheet(store: store, showing: $showingNewNote, title: $newTitle)
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
