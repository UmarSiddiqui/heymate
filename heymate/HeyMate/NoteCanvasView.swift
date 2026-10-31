//
//  NoteCanvasView.swift
//  HeyMate
//
//  The card canvas: draggable, zoomable, closable cards and curved ties.
//  Pure SwiftUI; geometry lives in `NoteCanvas` (NoteDocument.swift).
//

import AppKit
import SwiftUI

struct NoteCanvasView: View {
    @Binding var page: Page
    @State private var dragging: UUID?
    @State private var dragOffset: CGSize = .zero
    @State private var tieFrom: UUID?

    private var cards: [Block] { page.blocks.filter { $0.kind.isCard && $0.kind != .tie } }
    private var ties: [Block] { page.blocks.filter { $0.kind == .tie } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().background(DS.Colors.borderSubtle)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: 1600, height: 1000)
                    ForEach(ties) { tie in tieView(tie) }
                    ForEach(cards) { card in cardView(card) }
                }
                .frame(width: 1600, height: 1000, alignment: .topLeading)
            }
            .background(DS.Colors.background)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: DS.Spacing.sm) {
            ForEach(NoteCanvas.stickyColors, id: \.self) { color in
                Button { add(NoteCanvas.sticky(x: spawn.x, y: spawn.y, words: "New note", color: color)) } label: {
                    RoundedRectangle(cornerRadius: 3).fill(NoteStyle.stock(color)).frame(width: 16, height: 16)
                }
                .buttonStyle(.plain).help("Add a \(color) sticky")
            }
            Divider().frame(height: 16)
            pill("Paper", "doc.richtext") { add(NoteCanvas.paper(x: spawn.x, y: spawn.y, title: "Paper", heading: "Heading", subtitle: "")) }
            pill("Photo", "photo") { add(NoteCanvas.photo(x: spawn.x, y: spawn.y, query: "photo", caption: "Caption", tilt: -3)) }
            pill("Receipt", "list.bullet.rectangle") { add(NoteCanvas.receipt(x: spawn.x, y: spawn.y, title: "List", items: ["One", "Two"])) }
            pill("Clipping", "newspaper") { add(NoteCanvas.clipping(x: spawn.x, y: spawn.y, title: "Fact", body: "A fact worth keeping.", source: "source")) }
            Spacer()
            if tieFrom != nil {
                Text("Pick the second card…").font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                Button("Cancel") { self.tieFrom = nil }.buttonStyle(.plain).font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            pill("Keep notes only", "line.3.horizontal.decrease") { page = NoteCanvas.keepNotesOnly(page) }
        }
        .padding(.horizontal, DS.Spacing.md).padding(.vertical, DS.Spacing.sm)
    }

    private func pill(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(DS.Colors.surface2))
        }.buttonStyle(.plain)
    }

    /// Next free spot: cascades so new cards never stack exactly.
    private var spawn: (x: Double, y: Double) {
        let n = Double(cards.count % 8)
        return (40 + n * 36, 40 + n * 30)
    }
    private func add(_ block: Block) { page.blocks.append(block) }

    // MARK: Cards

    private func origin(_ card: Block) -> CGPoint {
        let f = NoteCanvas.frame(of: card)
        let extra = dragging == card.id ? dragOffset : .zero
        return CGPoint(x: f.x + extra.width, y: f.y + extra.height)
    }

    private func cardView(_ card: Block) -> some View {
        let f = NoteCanvas.frame(of: card)
        let zoom = NoteCanvas.zoom(of: card)
        let position = origin(card)
        return NoteCardView(card: card, size: CGSize(width: f.w, height: f.h),
                            onClose: { page = NoteCanvas.closeCard(page, id: card.id) },
                            onZoom: { delta in page = NoteCanvas.zoomCard(page, id: card.id, to: zoom + delta) },
                            onTie: { startTie(card) },
                            onEdit: { text in edit(card.id, text) })
            .scaleEffect(zoom, anchor: .topLeading)
            .offset(x: position.x, y: position.y)
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in dragging = card.id; dragOffset = value.translation }
                    .onEnded { value in
                        page = NoteCanvas.moveCard(page, id: card.id,
                                                   to: (max(0, f.x + value.translation.width), max(0, f.y + value.translation.height)))
                        dragging = nil; dragOffset = .zero
                    }
            )
    }

    private func edit(_ id: UUID, _ text: String) {
        guard let i = page.blocks.firstIndex(where: { $0.id == id }) else { return }
        page.blocks[i].attributes["text"] = text
    }

    private func startTie(_ card: Block) {
        if let first = tieFrom, first != card.id,
           let a = page.blocks.first(where: { $0.id == first }) {
            add(NoteCanvas.tie(from: a, to: card)); tieFrom = nil
        } else { tieFrom = card.id }
    }

    // MARK: Ties

    private func rect(_ id: String) -> CGRect? {
        guard let uuid = UUID(uuidString: id), let card = cards.first(where: { $0.id == uuid }) else { return nil }
        let f = NoteCanvas.frame(of: card), z = NoteCanvas.zoom(of: card)
        let o = origin(card)
        return CGRect(x: o.x, y: o.y, width: f.w * z, height: f.h * z)
    }
    /// Where the segment from a rect's center toward `point` leaves the rect (plus a small gap).
    private func edge(of r: CGRect, toward point: CGPoint) -> CGPoint {
        let c = CGPoint(x: r.midX, y: r.midY)
        let dx = point.x - c.x, dy = point.y - c.y
        guard dx != 0 || dy != 0 else { return c }
        let t = min(dx == 0 ? .infinity : (r.width / 2 + 6) / abs(dx), dy == 0 ? .infinity : (r.height / 2 + 6) / abs(dy))
        return CGPoint(x: c.x + dx * t, y: c.y + dy * t)
    }

    @ViewBuilder private func tieView(_ tie: Block) -> some View {
        if let ra = rect(tie.attributes["from"] ?? ""), let rb = rect(tie.attributes["to"] ?? "") {
            let a = edge(of: ra, toward: CGPoint(x: rb.midX, y: rb.midY)), b = edge(of: rb, toward: CGPoint(x: ra.midX, y: ra.midY))
            let bend = tie.attributes["bend"].flatMap(Double.init) ?? 0.3
            TieShape(from: a, to: b, bend: bend)
                .stroke(NoteStyle.ink, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .shadow(color: NoteStyle.inkGlow, radius: 3)
                .allowsHitTesting(false)
        }
    }
}

/// A curved arrow from one point to another. `bend` is the sideways pull as a fraction of the length.
struct TieShape: Shape {
    var from: CGPoint, to: CGPoint, bend: Double
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let dx = to.x - from.x, dy = to.y - from.y
        let mid = CGPoint(x: (from.x + to.x) / 2 - dy * bend, y: (from.y + to.y) / 2 + dx * bend)
        p.move(to: from)
        p.addQuadCurve(to: to, control: mid)
        // Arrowhead along the curve's end tangent.
        let angle = atan2(to.y - mid.y, to.x - mid.x), head: CGFloat = 12
        for turn in [CGFloat.pi * 0.85, -CGFloat.pi * 0.85] {
            p.move(to: to)
            p.addLine(to: CGPoint(x: to.x + head * cos(angle + turn), y: to.y + head * sin(angle + turn)))
        }
        return p
    }
}

/// One paper card. Content colors come from `NoteStyle`; the frame is a taped, slightly lifted sheet.
struct NoteCardView: View {
    let card: Block
    let size: CGSize
    var onClose: () -> Void = {}
    var onZoom: (Double) -> Void = { _ in }
    var onTie: () -> Void = {}
    var onEdit: (String) -> Void = { _ in }
    @State private var hovering = false

    var body: some View {
        let subject = CardSubject(block: card)
        content(subject)
            .frame(width: size.width, height: card.kind == .receipt ? nil : size.height, alignment: .topLeading)
            .rotationEffect(.degrees(card.attributes["tilt"].flatMap(Double.init) ?? 0))
            .overlay(alignment: .topTrailing) { if hovering { controls.padding(4) } }
            .onHover { hovering = $0 }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            control("link", "Tie to another card", onTie)
            control("plus.magnifyingglass", "Zoom in") { onZoom(0.25) }
            control("minus.magnifyingglass", "Zoom out") { onZoom(-0.25) }
            control("xmark", "Close card", onClose)
        }
    }
    private func control(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                .frame(width: 18, height: 18).background(Circle().fill(Color.black.opacity(0.7)))
        }.buttonStyle(.plain).help(help)
    }

    @ViewBuilder private func content(_ subject: CardSubject) -> some View {
        switch card.kind {
        case .sticky: sticky(subject)
        case .photo: photo
        case .receipt: window(title: card.attributes["title"] ?? "List", subject: subject) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(card.items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundColor(NoteStyle.ink)
                        Text(item.text).font(NoteFont.hand(15)).foregroundColor(NoteStyle.onPaper)
                    }
                }
            }
        }
        case .clipping: window(title: card.attributes["source"] ?? "source", subject: subject) {
            VStack(alignment: .leading, spacing: 4) {
                Text(card.attributes["title"] ?? "").font(NoteFont.library(15)).foregroundColor(NoteStyle.onPaper)
                Text(card.text).font(NoteFont.hand(14)).foregroundColor(NoteStyle.onPaperMuted)
            }
        }
        default: paper(subject)
        }
    }

    private func paper(_ subject: CardSubject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let t = card.attributes["title"], !t.isEmpty {
                Text(t.uppercased()).font(NoteFont.library(10)).tracking(1).foregroundColor(NoteStyle.onPaperMuted)
            }
            Text(card.attributes["heading"] ?? "").font(NoteFont.hand(22)).foregroundColor(NoteStyle.onPaper)
            if let s = card.attributes["subtitle"], !s.isEmpty {
                Text(s).font(NoteFont.hand(14)).foregroundColor(NoteStyle.onPaperMuted)
            }
            Spacer(minLength: 0)
            if subject.isRunning { ProgressView().controlSize(.small) }
        }
        .padding(14)
        .background(sheet(NoteStyle.stock(subject.stock)))
    }

    private func sticky(_ subject: CardSubject) -> some View {
        StickyText(text: card.text, onEdit: onEdit)
            .padding(14)
            .background(sheet(NoteStyle.stock(card.attributes["color"] ?? "butter")))
    }

    private var photo: some View {
        VStack(spacing: 8) {
            Group {
                if let path = card.attributes["from"], !path.isEmpty, let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color(hex: "#D8D2C4")
                        Image(systemName: "photo").font(.system(size: 28)).foregroundColor(NoteStyle.onPaperMuted)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            Text(card.attributes["caption"] ?? "").font(NoteFont.hand(15)).foregroundColor(NoteStyle.onPaper).lineLimit(2)
        }
        .padding(10).padding(.bottom, 4)
        .background(sheet(NoteStyle.stock("white")))
        .overlay(alignment: .top) {
            Rectangle().fill(NoteStyle.stock("butter").opacity(0.8)).frame(width: 54, height: 16)
                .rotationEffect(.degrees(-4)).offset(y: -8)
        }
    }

    private func window<Body: View>(title: String, subject: CardSubject, @ViewBuilder body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(NoteStyle.onPaperMuted.opacity(0.4)).frame(width: 7, height: 7) }
                Text(title).font(NoteFont.library(11)).foregroundColor(NoteStyle.onPaperMuted).lineLimit(1).padding(.leading, 4)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.black.opacity(0.06))
            VStack(alignment: .leading) { body() }.padding(12)
            Spacer(minLength: 0)
        }
        .background(sheet(NoteStyle.stock(card.attributes["color"] ?? (card.kind == .clipping ? "news" : "white"))))
    }

    private func sheet(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color)
            .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
    }
}

private struct StickyText: View {
    let text: String
    let onEdit: (String) -> Void
    @State private var draft = ""
    var body: some View {
        TextEditor(text: $draft)
            .font(NoteFont.hand(18)).foregroundColor(NoteStyle.onPaper)
            .scrollContentBackground(.hidden)
            .onAppear { draft = text }
            .onChange(of: draft) { _, new in onEdit(new) }
    }
}
