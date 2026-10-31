//
//  NoteDetailView.swift
//  HeyMate
//
//  A note's detail: title, page tabs, and either the block editor or, for a
//  board page, the card canvas. Edits are saved (debounced) through
//  `NoteStore.updateDocument`.
//

import SwiftUI

struct NoteDetailView: View {
    @ObservedObject var store: NoteStore
    let noteID: UUID
    @State private var document: NoteDocument
    @State private var pageIndex = 0
    @State private var saveTask: Task<Void, Never>?

    init(store: NoteStore, note: Note) {
        self.store = store
        noteID = note.id
        _document = State(initialValue: note.document ?? NoteDocument.migrating(title: note.title, legacy: note.blocks))
    }

    private var safeIndex: Int { min(pageIndex, document.pages.count - 1) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Title", text: Binding(get: { document.title ?? "" }, set: { document.title = $0 }))
                    .textFieldStyle(.plain).font(DS.Fonts.title).foregroundColor(DS.Colors.textPrimary)
                Spacer()
                Menu {
                    Button("Add page") { document.pages.append(Page(name: "Page \(document.pages.count + 1)")); pageIndex = document.pages.count - 1 }
                    Button("Add board") { document.pages.append(Page(name: "Board", isBoard: true)); pageIndex = document.pages.count - 1 }
                    if document.pages.count > 1 {
                        Button("Delete this page", role: .destructive) { document.pages.remove(at: safeIndex); pageIndex = 0 }
                    }
                } label: { Image(systemName: "plus.square.on.square").foregroundColor(DS.Colors.textSecondary) }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(DS.Spacing.md)

            if document.pages.count > 1 { pageTabs }
            Divider().background(DS.Colors.borderSubtle)

            let page = $document.pages[safeIndex]
            if page.wrappedValue.isBoard { NoteCanvasView(page: page) } else { NoteBlockEditor(page: page) }

            Divider().background(DS.Colors.borderSubtle)
            HStack {
                Text("\(document.pages.reduce(0) { $0 + $1.blocks.count }) blocks · \(document.pages.count) page\(document.pages.count == 1 ? "" : "s")")
                    .font(DS.Fonts.caption).foregroundColor(DS.Colors.textTertiary)
                Spacer()
            }.padding(DS.Spacing.sm)
        }
        .background(DS.Colors.background)
        .onChange(of: document) { _, new in scheduleSave(new) }
        .onDisappear { flush() }
    }

    private var pageTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(document.pages.enumerated()), id: \.element.id) { index, page in
                    Button { pageIndex = index } label: {
                        Text(page.name).font(DS.Fonts.caption).foregroundColor(DS.Colors.textPrimary)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(index == safeIndex ? DS.Colors.surface3 : DS.Colors.surface1))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, DS.Spacing.md).padding(.bottom, DS.Spacing.sm)
        }
    }

    private func scheduleSave(_ doc: NoteDocument) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            try? store.updateDocument(doc, for: noteID)
        }
    }
    private func flush() {
        saveTask?.cancel()
        try? store.updateDocument(document, for: noteID)
    }
}
