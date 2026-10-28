//
//  NoteDetailView.swift
//  HeyMate
//
//  HeyMate's own note detail: shows a note's blocks and lets you add text,
//  ink, and todo blocks. HeyMate's own SwiftUI — modeled on ReferenceRenderer's notes
//  canvas but not copied from it.
//

import SwiftUI

struct NoteDetailView: View {
    @ObservedObject var store: NoteStore
    @State var note: Note
    @State private var newText = ""
    @State private var editingTitle = false

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                TextField("Title", text: $note.title)
                    .font(DS.Fonts.title)
                    .foregroundColor(DS.Colors.textPrimary)
                    .onSubmit {
                        try? save()
                    }
                Spacer()
                Button(action: { try? save() }) {
                    Image(systemName: "checkmark")
                        .foregroundColor(DS.Colors.accent)
                }
                .buttonStyle(.plain)
                .help("Save")
            }
            .padding(DS.Spacing.md)

            Divider()

            // Blocks
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    ForEach(Array(note.blocks.enumerated()), id: \.element.id) { index, block in
                        NoteBlockView(block: block) { updated in
                            var blocks = note.blocks
                            blocks[index] = updated
                            try? store.update(note, blocks: blocks)
                            note.blocks = blocks
                        } onDelete: {
                            try? store.removeBlock(at: index, from: note.id)
                            note.blocks.remove(at: index)
                        }
                    }

                    // Add block controls
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        Text("Add block")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textTertiary)
                        HStack(spacing: DS.Spacing.sm) {
                            Button("Text") {
                                let block = NoteBlock(kind: .text, content: newText)
                                newText = ""
                                try? store.appendBlock(block, to: note.id)
                                note.blocks.append(block)
                            }
                            .buttonStyle(.bordered)
                            .disabled(newText.isEmpty)

                            Button("Todo") {
                                let block = NoteBlock(kind: .todo, content: newText)
                                newText = ""
                                try? store.appendBlock(block, to: note.id)
                                note.blocks.append(block)
                            }
                            .buttonStyle(.bordered)
                            .disabled(newText.isEmpty)

                            Button("Ink") {
                                let block = NoteBlock(kind: .ink, content: "")
                                try? store.appendBlock(block, to: note.id)
                                note.blocks.append(block)
                            }
                            .buttonStyle(.bordered)

                            TextField("Enter text…", text: $newText)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding(DS.Spacing.md)
                }
                .padding(DS.Spacing.md)
            }

            Divider()

            // Status
            HStack {
                Text("\(note.blocks.count) block\(note.blocks.count == 1 ? "" : "s")")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(DS.Spacing.md)
        }
        .frame(minWidth: 400, minHeight: 300)
    }

    private func save() throws {
        try store.update(note, title: note.title)
    }
}

/// Renders a single block inside a note.
private struct NoteBlockView: View {
    @State var block: NoteBlock
    let onUpdate: (NoteBlock) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            switch block.kind {
            case .text:
                Text(block.content.isEmpty ? "(empty text)" : block.content)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .todo:
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: block.content.isEmpty ? "square" : "checkmark.square")
                        .foregroundColor(DS.Colors.accent)
                    Text(block.content.isEmpty ? "(empty todo)" : block.content)
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textPrimary)
                    Spacer()
                }
            case .ink:
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DS.Colors.surface2)
                    .frame(height: 100)
                    .overlay(
                        VStack {
                            Image(systemName: "scribble")
                                .foregroundColor(DS.Colors.textTertiary)
                            Text("Ink drawing")
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                    )
            case .table:
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    ForEach(block.children.indices, id: \.self) { rowIndex in
                        HStack(spacing: DS.Spacing.sm) {
                            ForEach(block.children[rowIndex].content.components(separatedBy: "\t"), id: \.self) { cell in
                                Text(cell)
                                    .font(DS.Fonts.caption)
                                    .foregroundColor(DS.Colors.textSecondary)
                                Divider()
                                    .frame(height: 12)
                            }
                        }
                    }
                }
            }
        }
        .padding(DS.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface2.opacity(0.5))
        )
        .contextMenu {
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}
