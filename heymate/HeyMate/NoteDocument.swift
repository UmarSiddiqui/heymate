//
//  NoteDocument.swift
//  HeyMate
//
//  The notes canvas model: Document -> Page -> Block -> Item. HeyMate's own
//  Swift, shaped by the contract recovered from HeyClicky 1.1.1's ClickyInk
//  (field names and card vocabulary only; no code was recovered or copied).
//  Every type decodes tolerantly: missing fields take defaults and unknown
//  block kinds survive a round trip.
//

import Foundation

// MARK: - Block kinds

/// A block's kind. A string wrapper rather than a closed enum so a kind this
/// build does not know (written by a newer build or the agent) still decodes,
/// renders as a paragraph, and is written back unchanged.
nonisolated struct BlockKind: RawRepresentable, Codable, Hashable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // Text
    static let heading = BlockKind("heading")
    static let subheading = BlockKind("subheading")
    static let paragraph = BlockKind("paragraph")
    static let answer = BlockKind("answer")
    static let quote = BlockKind("quote")
    static let callout = BlockKind("callout")
    static let code = BlockKind("code")
    static let equation = BlockKind("equation")
    static let definition = BlockKind("definition")
    static let summary = BlockKind("summary")
    // Lists
    static let list = BlockKind("list")
    static let numberedList = BlockKind("numberedList")
    static let todo = BlockKind("todo")
    static let steps = BlockKind("steps")
    static let timeline = BlockKind("timeline")
    static let table = BlockKind("table")
    static let comparison = BlockKind("comparison")
    // Media and references
    static let image = BlockKind("image")
    static let gallery = BlockKind("gallery")
    static let drawing = BlockKind("drawing")
    static let file = BlockKind("file")
    static let audio = BlockKind("audio")
    static let video = BlockKind("video")
    static let link = BlockKind("link")
    static let bookmark = BlockKind("bookmark")
    static let source = BlockKind("source")
    // Structured
    static let event = BlockKind("event")
    static let reminder = BlockKind("reminder")
    static let contact = BlockKind("contact")
    static let place = BlockKind("place")
    static let stat = BlockKind("stat")
    static let chart = BlockKind("chart")
    static let progress = BlockKind("progress")
    static let status = BlockKind("status")
    static let tag = BlockKind("tag")
    static let routine = BlockKind("routine")
    static let dashboard = BlockKind("dashboard")
    static let divider = BlockKind("divider")
    // Canvas cards (HeyClicky's draw pieces)
    static let paper = BlockKind("paper")
    static let photo = BlockKind("photo")
    static let receipt = BlockKind("receipt")
    static let clipping = BlockKind("clipping")
    static let sticky = BlockKind("sticky")
    static let tie = BlockKind("tie")

    /// The 46 kinds this build knows how to edit.
    static let known: [BlockKind] = [
        heading, subheading, paragraph, answer, quote, callout, code, equation, definition, summary,
        list, numberedList, todo, steps, timeline, table, comparison,
        image, gallery, drawing, file, audio, video, link, bookmark, source,
        event, reminder, contact, place, stat, chart, progress, status, tag, routine, dashboard, divider,
        paper, photo, receipt, clipping, sticky, tie,
        BlockKind("ink"), BlockKind("text")
    ]

    static let cardKinds: Set<BlockKind> = [paper, photo, receipt, clipping, sticky, tie]
    var isCard: Bool { Self.cardKinds.contains(self) }
    var isKnown: Bool { Self.known.contains(self) }
    var label: String {
        rawValue.reduce(into: "") { out, ch in
            if ch.isUppercase { out.append(" ") }
            out.append(out.isEmpty ? Character(ch.uppercased()) : ch)
        }
    }
}

// MARK: - Item

/// One entry inside a block: a list row, table row, receipt line, gallery image.
nonisolated struct Item: Codable, Equatable, Identifiable {
    var id: UUID
    var text: String
    var mark: String?
    var attributes: [String: String]
    var items: [Item]
    var isChecked: Bool?
    var url: String?
    var number: Int?

    init(
        id: UUID = UUID(), text: String = "", mark: String? = nil,
        attributes: [String: String] = [:], items: [Item] = [],
        isChecked: Bool? = nil, url: String? = nil, number: Int? = nil
    ) {
        self.id = id; self.text = text; self.mark = mark; self.attributes = attributes
        self.items = items; self.isChecked = isChecked; self.url = url; self.number = number
    }

    private enum CodingKeys: String, CodingKey { case id, text, mark, attributes, items, isChecked, url, number }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        mark = try? c.decode(String.self, forKey: .mark)
        attributes = (try? c.decode([String: String].self, forKey: .attributes)) ?? [:]
        items = (try? c.decode([Item].self, forKey: .items)) ?? []
        isChecked = try? c.decode(Bool.self, forKey: .isChecked)
        url = try? c.decode(String.self, forKey: .url)
        number = try? c.decode(Int.self, forKey: .number)
    }
}

// MARK: - Block

nonisolated struct Block: Codable, Equatable, Identifiable {
    var id: UUID
    var kind: BlockKind
    var attributes: [String: String]
    var items: [Item]
    var columns: [String]

    init(
        id: UUID = UUID(), kind: BlockKind, attributes: [String: String] = [:],
        items: [Item] = [], columns: [String] = []
    ) {
        self.id = id; self.kind = kind; self.attributes = attributes; self.items = items; self.columns = columns
    }

    /// The block's main text: `attributes["text"]`.
    var text: String {
        get { attributes["text"] ?? "" }
        set { attributes["text"] = newValue }
    }

    private enum CodingKeys: String, CodingKey { case id, kind, attributes, items, columns }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? c.decode(BlockKind.self, forKey: .kind)) ?? .paragraph
        attributes = (try? c.decode([String: String].self, forKey: .attributes)) ?? [:]
        items = (try? c.decode([Item].self, forKey: .items)) ?? []
        columns = (try? c.decode([String].self, forKey: .columns)) ?? []
    }
}

// MARK: - Page and document

nonisolated struct Page: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    /// A board page lays its blocks out as cards on a canvas instead of a column.
    var isBoard: Bool
    var blocks: [Block]

    init(id: UUID = UUID(), name: String = "Page 1", isBoard: Bool = false, blocks: [Block] = []) {
        self.id = id; self.name = name; self.isBoard = isBoard; self.blocks = blocks
    }

    private enum CodingKeys: String, CodingKey { case id, name, isBoard, blocks }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Page"
        isBoard = (try? c.decode(Bool.self, forKey: .isBoard)) ?? false
        blocks = (try? c.decode([Block].self, forKey: .blocks)) ?? []
    }
}

nonisolated struct NoteDocument: Codable, Equatable {
    var title: String?
    var pages: [Page]

    init(title: String? = nil, pages: [Page] = [Page()]) {
        self.title = title; self.pages = pages.isEmpty ? [Page()] : pages
    }

    private enum CodingKeys: String, CodingKey { case title, pages }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try? c.decode(String.self, forKey: .title)
        let decoded = (try? c.decode([Page].self, forKey: .pages)) ?? []
        pages = decoded.isEmpty ? [Page()] : decoded
    }

    static let currentVersion = 2

    /// Carries a pre-canvas note (flat blocks) forward onto one page. Nothing is dropped.
    static func migrating(title: String, legacy blocks: [NoteBlock]) -> NoteDocument {
        let moved: [Block] = blocks.map { old in
            var attributes = old.formatting
            let id = old.id
            switch old.kind {
            case .text:
                attributes["text"] = old.content
                return Block(id: id, kind: .paragraph, attributes: attributes)
            case .todo:
                attributes["text"] = old.content
                return Block(id: id, kind: .todo, attributes: attributes,
                             items: [Item(text: old.content, isChecked: false)])
            case .ink:
                attributes["strokes"] = old.content
                return Block(id: id, kind: .drawing, attributes: attributes)
            case .table:
                let rows = old.children.map { row in
                    Item(id: row.id, text: row.content,
                         items: row.content.components(separatedBy: "\t").map { Item(text: $0) })
                }
                return Block(id: id, kind: .table, attributes: attributes, items: rows)
            }
        }
        return NoteDocument(title: title, pages: [Page(name: "Page 1", blocks: moved)])
    }
}

// MARK: - Status, subjects, dashboards

nonisolated enum StatusState: String, Codable, CaseIterable {
    case idle, running, ok, warning, failed

    /// Worst wins when sections roll up into an overall state.
    var severity: Int {
        switch self {
        case .idle: return 0
        case .ok: return 1
        case .running: return 2
        case .warning: return 3
        case .failed: return 4
        }
    }
    var label: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .ok: return "All good"
        case .warning: return "Needs a look"
        case .failed: return "Failed"
        }
    }
}

/// What a canvas card is about: drives its paper color and live state.
nonisolated struct CardSubject: Codable, Equatable, Identifiable {
    var id: String
    var kind: String
    var isRunning: Bool
    var phase: String?
    var status: StatusState
    /// Paper stock: butter, mint, peach, lilac, sky, white, news.
    var stock: String

    init(block: Block) {
        id = block.id.uuidString
        kind = block.kind.rawValue
        isRunning = block.attributes["running"] == "true"
        phase = block.attributes["phase"]
        status = StatusState(rawValue: block.attributes["status"] ?? "") ?? (isRunning ? .running : .idle)
        stock = block.attributes["color"] ?? (block.kind == .clipping ? "news" : "white")
    }
}

nonisolated struct DashboardSection: Codable, Equatable, Identifiable {
    var id: String { title }
    var title: String
    var status: StatusState
    var items: [Item]
}

nonisolated struct DashboardBoard: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var sections: [DashboardSection]
    var overall: StatusState
    var changes: [String]

    init(id: String, title: String, sections: [DashboardSection], changes: [String] = []) {
        self.id = id; self.title = title; self.sections = sections; self.changes = changes
        overall = sections.map(\.status).max { $0.severity < $1.severity } ?? .idle
    }

    /// The routines dashboard, derived live from the mates' real routines.
    static func routines(_ controls: [RoutineControl]) -> DashboardBoard {
        func row(_ r: RoutineControl) -> Item {
            Item(id: r.id, text: r.title,
                 mark: r.isRunning ? "running" : (r.isPaused ? "paused" : "scheduled"),
                 attributes: ["runs": String(r.runCount), "every": r.intervalLabel],
                 number: r.runCount)
        }
        let running = controls.filter(\.isRunning)
        let failed = controls.filter { $0.isPausedAfterFailures }
        let paused = controls.filter { $0.isPaused && !$0.isPausedAfterFailures }
        let scheduled = controls.filter { !$0.isPaused && !$0.isRunning }
        var sections: [DashboardSection] = []
        if !running.isEmpty { sections.append(.init(title: "Running", status: .running, items: running.map(row))) }
        if !failed.isEmpty { sections.append(.init(title: "Paused after failures", status: .failed, items: failed.map(row))) }
        if !paused.isEmpty { sections.append(.init(title: "Paused", status: .warning, items: paused.map(row))) }
        if !scheduled.isEmpty { sections.append(.init(title: "Scheduled", status: .ok, items: scheduled.map(row))) }
        let changes = failed.map { "\($0.title) paused after repeated failures" }
        return DashboardBoard(id: "routines", title: "Routines", sections: sections, changes: changes)
    }
}

// MARK: - Routine control (a view of MateRoutine, never a copy)

nonisolated struct RoutineControl: Equatable, Identifiable {
    var id: UUID
    var title: String
    var intervalMinutes: Int
    var isPaused: Bool
    var isPausedAfterFailures: Bool
    var isRunning: Bool
    var nextRunAt: Date
    var runCount: Int

    init(_ routine: MateRoutine, isRunning: Bool = false) {
        id = routine.id
        title = routine.task
        switch routine.schedule {
        case .everyHours(let hours): intervalMinutes = max(1, hours) * 60
        case .daily: intervalMinutes = 24 * 60
        }
        isPaused = !routine.enabled || routine.pausedReason != nil
        isPausedAfterFailures = routine.pausedReason != nil
            && routine.consecutiveFailures >= MateRoutineAccounting.failurePauseCount
        self.isRunning = isRunning
        nextRunAt = routine.nextRunAt
        runCount = routine.runCount ?? 0
    }

    var intervalLabel: String {
        intervalMinutes % 1440 == 0 ? (intervalMinutes == 1440 ? "daily" : "every \(intervalMinutes / 1440) days")
            : intervalMinutes % 60 == 0 ? "every \(intervalMinutes / 60)h" : "every \(intervalMinutes)m"
    }
}

// MARK: - Canvas cards

/// Card geometry and the card operations. Pure: they take a page and return a page.
nonisolated enum NoteCanvas {
    static let stickySide: Double = 170

    static func frame(of block: Block) -> (x: Double, y: Double, w: Double, h: Double) {
        func v(_ key: String, _ fallback: Double) -> Double { block.attributes[key].flatMap(Double.init) ?? fallback }
        let defaults: (Double, Double) = {
            switch block.kind {
            case .sticky: return (stickySide, stickySide)
            case .photo: return (190, 230)
            case .receipt: return (200, 160)
            case .clipping: return (240, 150)
            default: return (320, 220)
            }
        }()
        return (v("x", 0), v("y", 0), v("w", defaults.0), v("h", defaults.1))
    }

    static func place(_ kind: BlockKind, x: Double, y: Double, w: Double? = nil, h: Double? = nil,
                      attributes: [String: String] = [:], items: [Item] = []) -> Block {
        var a = attributes
        a["x"] = fmt(x); a["y"] = fmt(y)
        if let w { a["w"] = fmt(w) }
        if let h { a["h"] = fmt(h) }
        return Block(kind: kind, attributes: a, items: items)
    }

    // The six piece constructors, named for HeyClicky's draw-pieces contract.
    static func paper(x: Double, y: Double, w: Double = 320, h: Double = 220,
                      title: String = "", heading: String = "", subtitle: String = "", board: String = "") -> Block {
        place(.paper, x: x, y: y, w: w, h: h, attributes: ["title": title, "heading": heading, "subtitle": subtitle, "board": board])
    }
    static func photo(x: Double, y: Double, w: Double = 190, h: Double = 230, query: String, caption: String = "",
                      tilt: Double = 0, web: Bool = false, from: String = "", subtitle: String = "") -> Block {
        place(.photo, x: x, y: y, w: w, h: h, attributes: [
            "query": query, "caption": caption, "tilt": fmt(tilt), "web": web ? "true" : "false",
            "from": from, "subtitle": subtitle])
    }
    static func receipt(x: Double, y: Double, title: String, items: [String]) -> Block {
        place(.receipt, x: x, y: y, attributes: ["title": title], items: items.map { Item(text: $0) })
    }
    static func clipping(x: Double, y: Double, w: Double = 240, title: String, body: String, source: String) -> Block {
        place(.clipping, x: x, y: y, w: w, attributes: ["title": title, "text": body, "source": source])
    }
    static let stickyColors = ["butter", "mint", "peach", "lilac", "sky"]
    static func sticky(x: Double, y: Double, words: String, color: String = "butter") -> Block {
        place(.sticky, x: x, y: y, w: stickySide, h: stickySide,
              attributes: ["text": words, "color": stickyColors.contains(color) ? color : "butter"])
    }
    static func tie(from: Block, to: Block, bend: Double = 0.3) -> Block {
        Block(kind: .tie, attributes: ["from": from.id.uuidString, "to": to.id.uuidString, "bend": fmt(bend)])
    }

    // Card operations.
    static func cards(_ page: Page) -> [Block] { page.blocks.filter { $0.kind.isCard } }

    /// Drops everything but sticky notes and paper; ties to a removed card go too.
    static func keepNotesOnly(_ page: Page) -> Page {
        var page = page
        let keep: Set<BlockKind> = [.sticky, .paper]
        page.blocks.removeAll { $0.kind.isCard && $0.kind != .tie && !keep.contains($0.kind) }
        return dropDanglingTies(page)
    }

    static func closeCard(_ page: Page, id: UUID) -> Page {
        var page = page
        page.blocks.removeAll { $0.id == id }
        return dropDanglingTies(page)
    }

    static func moveCard(_ page: Page, id: UUID, to point: (x: Double, y: Double)) -> Page {
        update(page, id: id) { $0.attributes["x"] = fmt(point.x); $0.attributes["y"] = fmt(point.y) }
    }

    /// Zoom is a 0.5...3 multiplier on the card's drawn size.
    static func zoomCard(_ page: Page, id: UUID, to zoom: Double) -> Page {
        update(page, id: id) { $0.attributes["zoom"] = fmt(min(3, max(0.5, zoom))) }
    }
    static func zoom(of block: Block) -> Double { block.attributes["zoom"].flatMap(Double.init) ?? 1 }

    private static func update(_ page: Page, id: UUID, _ change: (inout Block) -> Void) -> Page {
        var page = page
        guard let index = page.blocks.firstIndex(where: { $0.id == id }) else { return page }
        change(&page.blocks[index])
        return page
    }
    private static func dropDanglingTies(_ page: Page) -> Page {
        var page = page
        let ids = Set(page.blocks.map { $0.id.uuidString })
        page.blocks.removeAll { block in
            block.kind == .tie && !(ids.contains(block.attributes["from"] ?? "") && ids.contains(block.attributes["to"] ?? ""))
        }
        return page
    }
    private static func fmt(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
