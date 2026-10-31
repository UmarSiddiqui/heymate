//
//  NoteBlockEditor.swift
//  HeyMate
//
//  Rich block editor for one non-board page: every known block kind gets an
//  editor shape (text, items, table, fields, ink or divider).
//

import SwiftUI

enum BlockEditorShape {
    case text, items(todo: Bool), table, fields([(key: String, label: String)]), ink, divider

    static func shape(for kind: BlockKind) -> BlockEditorShape {
        switch kind {
        case .heading, .subheading, .paragraph, .answer, .quote, .callout, .code, .equation, .definition, .summary,
             BlockKind("text"):
            return .text
        case .list, .numberedList, .steps, .timeline, .gallery, .comparison:
            return .items(todo: false)
        case .todo:
            return .items(todo: true)
        case .table: return .table
        case .drawing, BlockKind("ink"): return .ink
        case .divider, .tie: return .divider
        case .link, .bookmark, .source, .image, .file, .audio, .video:
            return .fields([("title", "Title"), ("url", "URL"), ("text", "Note")])
        case .event: return .fields([("title", "Title"), ("date", "When"), ("place", "Where")])
        case .reminder: return .fields([("title", "Reminder"), ("date", "When")])
        case .contact: return .fields([("title", "Name"), ("phone", "Phone"), ("email", "Email")])
        case .place: return .fields([("title", "Place"), ("address", "Address")])
        case .stat: return .fields([("title", "Label"), ("value", "Value")])
        case .progress: return .fields([("title", "Label"), ("value", "Percent")])
        case .status: return .fields([("title", "Label"), ("status", "State")])
        default: return .fields([("title", "Title"), ("text", "Text")])
        }
    }
}

struct NoteBlockEditor: View {
    @Binding var page: Page

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                ForEach($page.blocks) { $block in
                    BlockRow(block: $block) { page.blocks.removeAll { $0.id == block.id } }
                }
                addMenu
            }
            .padding(DS.Spacing.lg)
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(Self.groups, id: \.title) { group in
                Menu(group.title) {
                    ForEach(group.kinds, id: \.self) { kind in
                        Button(kind.label) { page.blocks.append(Self.fresh(kind)) }
                    }
                }
            }
        } label: {
            Label("Add block", systemImage: "plus").font(DS.Fonts.control).foregroundColor(DS.Colors.textPrimary)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    static let groups: [(title: String, kinds: [BlockKind])] = [
        ("Text", [.heading, .subheading, .paragraph, .answer, .quote, .callout, .code, .equation, .definition, .summary]),
        ("Lists", [.list, .numberedList, .todo, .steps, .timeline, .table, .comparison]),
        ("Media", [.image, .gallery, .drawing, .file, .audio, .video, .link, .bookmark, .source]),
        ("Structured", [.event, .reminder, .contact, .place, .stat, .chart, .progress, .status, .tag, .routine, .dashboard, .divider]),
    ]

    static func fresh(_ kind: BlockKind) -> Block {
        switch BlockEditorShape.shape(for: kind) {
        case .items(let todo): return Block(kind: kind, items: [Item(isChecked: todo ? false : nil)])
        case .table: return Block(kind: kind, items: [Item(items: [Item(), Item()])], columns: ["A", "B"])
        default: return Block(kind: kind)
        }
    }
}

private struct BlockRow: View {
    @Binding var block: Block
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if !isPlainText { Text(block.kind.label.uppercased()).font(DS.Fonts.micro).foregroundColor(DS.Colors.textTertiary) }
            editor
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous).fill(DS.Colors.surface1))
        .contextMenu { Button("Delete", role: .destructive, action: onDelete) }
    }

    private var isPlainText: Bool { if case .text = BlockEditorShape.shape(for: block.kind) { return true } else { return false } }

    @ViewBuilder private var editor: some View {
        switch BlockEditorShape.shape(for: block.kind) {
        case .text:
            TextField(placeholder, text: attribute("text"), axis: .vertical)
                .textFieldStyle(.plain).font(font).foregroundColor(DS.Colors.textPrimary)
                .padding(.leading, block.kind == .quote ? 10 : 0)
                .overlay(alignment: .leading) { if block.kind == .quote { Rectangle().fill(NoteStyle.ink).frame(width: 2) } }
        case .items(let todo):
            VStack(alignment: .leading, spacing: 4) {
                ForEach($block.items) { $item in
                    HStack(spacing: 6) {
                        marker(for: $item, todo: todo)
                        TextField("Item", text: $item.text).textFieldStyle(.plain).font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                            .strikethrough(item.isChecked == true)
                        if block.kind == .gallery { TextField("URL", text: urlBinding($item)).textFieldStyle(.plain).font(DS.Fonts.caption) }
                    }
                }
                Button { block.items.append(Item(isChecked: todo ? false : nil)) } label: {
                    Label("Add item", systemImage: "plus").font(DS.Fonts.caption)
                }.buttonStyle(.plain).foregroundColor(DS.Colors.textSecondary)
            }
        case .table:
            VStack(alignment: .leading, spacing: 4) {
                HStack { ForEach(block.columns.indices, id: \.self) { i in
                    TextField("Column", text: columnBinding(i)).font(DS.Fonts.caption.weight(.semibold)).textFieldStyle(.plain)
                } }
                ForEach($block.items) { $row in
                    HStack { ForEach($row.items) { $cell in TextField("", text: $cell.text).textFieldStyle(.plain).font(DS.Fonts.body) } }
                }
                HStack {
                    Button("Row") { block.items.append(Item(items: block.columns.map { _ in Item() })) }
                    Button("Column") {
                        block.columns.append("New")
                        for i in block.items.indices { block.items[i].items.append(Item()) }
                    }
                }.buttonStyle(.plain).font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
            }
        case .fields(let fields):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(fields, id: \.key) { field in
                    HStack {
                        Text(field.label).font(DS.Fonts.caption).foregroundColor(DS.Colors.textTertiary).frame(width: 60, alignment: .leading)
                        TextField("", text: attribute(field.key)).textFieldStyle(.plain).font(DS.Fonts.body)
                    }
                }
            }
        case .ink:
            InkPad(strokes: attribute("strokes"))
        case .divider:
            Divider()
        }
    }

    private var placeholder: String { block.kind == .heading ? "Heading" : "Write something…" }
    private var font: Font {
        switch block.kind {
        case .heading: return DS.Fonts.hero
        case .subheading: return DS.Fonts.title
        case .code, .equation: return DS.Fonts.code
        case .quote: return DS.Fonts.reading.italic()
        default: return DS.Fonts.bodyLarge
        }
    }

    private func attribute(_ key: String) -> Binding<String> {
        Binding(get: { block.attributes[key] ?? "" }, set: { block.attributes[key] = $0.isEmpty ? nil : $0 })
    }
    private func urlBinding(_ item: Binding<Item>) -> Binding<String> {
        Binding(get: { item.wrappedValue.url ?? "" }, set: { item.wrappedValue.url = $0.isEmpty ? nil : $0 })
    }
    private func columnBinding(_ i: Int) -> Binding<String> {
        Binding(get: { i < block.columns.count ? block.columns[i] : "" }, set: { if i < block.columns.count { block.columns[i] = $0 } })
    }
    @ViewBuilder private func marker(for item: Binding<Item>, todo: Bool) -> some View {
        if todo {
            Button { item.wrappedValue.isChecked = !(item.wrappedValue.isChecked ?? false) } label: {
                Image(systemName: item.wrappedValue.isChecked == true ? "checkmark.square.fill" : "square")
                    .foregroundColor(DS.Colors.textPrimary)
            }.buttonStyle(.plain)
        } else if block.kind == .numberedList || block.kind == .steps {
            let n = (block.items.firstIndex { $0.id == item.wrappedValue.id } ?? 0) + 1
            Text("\(n).").font(DS.Fonts.numeric).foregroundColor(DS.Colors.textTertiary)
        } else {
            Text("•").foregroundColor(DS.Colors.textTertiary)
        }
    }
}

/// A scribble pad. Strokes are stored as "x,y x,y|x,y …" in `attributes["strokes"]`, ink-blue with a soft glow.
struct InkPad: View {
    @Binding var strokes: String
    @State private var live: [CGPoint] = []

    static func parse(_ raw: String) -> [[CGPoint]] {
        raw.split(separator: "|").map { stroke in
            stroke.split(separator: " ").compactMap { pair in
                let p = pair.split(separator: ",").compactMap { Double($0) }
                return p.count == 2 ? CGPoint(x: p[0], y: p[1]) : nil
            }
        }
    }
    static func encode(_ strokes: [[CGPoint]]) -> String {
        strokes.map { $0.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " ") }.joined(separator: "|")
    }

    var body: some View {
        let saved = Self.parse(strokes)
        ZStack(alignment: .topTrailing) {
            Canvas { context, _ in
                for stroke in saved + [live] where stroke.count > 1 {
                    var path = Path(); path.addLines(stroke)
                    context.stroke(path, with: .color(NoteStyle.ink), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                }
            }
            .shadow(color: NoteStyle.inkGlow, radius: 3)
            .frame(height: 140)
            .background(RoundedRectangle(cornerRadius: 8).fill(NoteStyle.stock("white")))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { live.append($0.location) }
                .onEnded { _ in strokes = Self.encode(saved + [live]); live = [] })
            if !saved.isEmpty {
                Button { strokes = "" } label: { Image(systemName: "eraser").padding(6) }.buttonStyle(.plain)
                    .foregroundColor(NoteStyle.onPaperMuted).help("Clear drawing")
            }
        }
    }
}
