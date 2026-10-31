//
//  Note.swift
//  HeyMate
//
//  HeyMate's own notes model: a note is a title plus an ordered list of
//  blocks (text, ink drawing, todo, table). HeyMate's own Swift — modeled on
//  ReferenceRenderer's MateInk notes canvas but not copied from it.
//

import Foundation
import CoreGraphics

/// One block inside a note.
nonisolated struct NoteBlock: Equatable, Codable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case text
        case ink          // a hand-drawn stroke group
        case todo
        case table
    }

    let id: UUID
    let kind: Kind
    /// Plain text for text/todo blocks; serialized drawing data for ink.
    let content: String
    /// Formatting hints (bold, italic, size, color, alignment).
    let formatting: [String: String]
    /// Child blocks for tables (rows).
    let children: [NoteBlock]
    let createdAt: Date
    let updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: Kind,
        content: String = "",
        formatting: [String: String] = [:],
        children: [NoteBlock] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.content = content
        self.formatting = formatting
        self.children = children
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One note: title plus an ordered list of blocks.
nonisolated struct Note: Equatable, Codable, Identifiable {
    let id: UUID
    var title: String
    var blocks: [NoteBlock]
    /// A note the agent keeps (ReferenceRenderer's note tools) is markdown instead of blocks, and read-only here.
    var markdown: String?
    var isPreview: Bool?
    /// 2 once the note is a canvas document. Older files carry no version and only `blocks`.
    var version: Int?
    /// Pages of rich blocks / cards. `blocks` is kept as written so an older build still opens the file.
    var document: NoteDocument?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        blocks: [NoteBlock] = [],
        markdown: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.blocks = blocks
        self.markdown = markdown
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
