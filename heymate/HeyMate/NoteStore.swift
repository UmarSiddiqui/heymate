//
//  NoteStore.swift
//  HeyMate
//
//  HeyMate's own notes store: persists notes as individual JSON files in a
//  private application-support folder. HeyMate's own Swift — modeled on
//  ReferenceRenderer's MateInkNoteStore but not copied from it.
//

import Combine
import Foundation

/// Errors thrown by the note store.
enum NoteStoreError: LocalizedError, Equatable {
    case noteNotFound(UUID)
    case invalidTitle
    case writeFailed(Error)
    case readFailed(Error)

    var errorDescription: String? {
        switch self {
        case .noteNotFound(let id): return "Note not found: \(id.uuidString)"
        case .invalidTitle: return "Note title cannot be empty."
        case .writeFailed(let error): return "Failed to write note: \(error.localizedDescription)"
        case .readFailed(let error): return "Failed to read note: \(error.localizedDescription)"
        }
    }

    static func == (lhs: NoteStoreError, rhs: NoteStoreError) -> Bool {
        switch (lhs, rhs) {
        case (.noteNotFound(let a), .noteNotFound(let b)): return a == b
        case (.invalidTitle, .invalidTitle): return true
        default: return false
        }
    }
}

/// Persists notes as JSON files in ~/Library/Application Support/HeyMate/Notes/.
@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] = []

    private let folderURL: URL
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    static let shared = NoteStore()

    private init() {
        // Beside the agent's own folder: its note tools write here too (and tests get their own copy).
        folderURL = HeyMateDataDirectory.url.appendingPathComponent("Notes", isDirectory: true)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        loadAll()
        watchFolder()
    }

    /// The agent writes its note while it works: every save (a rename into the folder) reloads the notes.
    private var folderWatch: DispatchSourceFileSystemObject?
    private var previewExpiry: Timer?
    private func watchFolder() {
        let descriptor = open(folderURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.loadAll() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        folderWatch = source
    }

    // MARK: - Loading

    private func loadAll() {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var notes: [Note] = urls.compactMap { url in
            if url.lastPathComponent.hasSuffix(".preview.json") { return nil }
            if url.pathExtension == "md" { return loadMarkdownNote(from: url) }
            guard url.pathExtension == "json" else { return nil }
            return try? loadNote(from: url)
        }
        struct Preview: Decodable { let noteID: UUID; let markdown: String; let updatedAt: Double }
        var hasPreview = false
        for url in urls where url.lastPathComponent.hasSuffix(".preview.json") {
            guard let data = try? Data(contentsOf: url),
                  let preview = try? decoder.decode(Preview.self, from: data),
                  abs(Date().timeIntervalSince1970 - preview.updatedAt / 1000) < 8 else { continue }
            hasPreview = true
            let title = preview.markdown.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? "Writing note…"
            var note = Note(id: preview.noteID, title: title, markdown: preview.markdown, updatedAt: Date(timeIntervalSince1970: preview.updatedAt / 1000))
            note.isPreview = true
            notes.removeAll { $0.id == preview.noteID }; notes.append(note)
        }
        previewExpiry?.invalidate(); previewExpiry = nil
        if hasPreview {
            previewExpiry = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in self?.loadAll() }
            }
        }
        self.notes = notes.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func loadNote(from url: URL) throws -> Note {
        let data = try Data(contentsOf: url)
        var note = try decoder.decode(Note.self, from: data)
        if let migrated = Self.migrated(note) {
            // Rewrite in place: the legacy `blocks` stay in the file, so nothing is lost.
            note = migrated
            try? save(note)
        }
        return note
    }

    /// A pre-canvas note carried forward onto one page. Nil when already current or the agent's markdown.
    nonisolated static func migrated(_ note: Note) -> Note? {
        guard note.markdown == nil, note.document == nil || (note.version ?? 0) < NoteDocument.currentVersion else { return nil }
        var note = note
        if note.document == nil { note.document = NoteDocument.migrating(title: note.title, legacy: note.blocks) }
        note.version = NoteDocument.currentVersion
        return note
    }

    /// The agent's note: <id>.md, titled by its first # heading.
    private func loadMarkdownNote(from url: URL) -> Note? {
        guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
              let markdown = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let title = markdown.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? "Note"
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        return Note(id: id, title: title.trimmingCharacters(in: .whitespaces), markdown: markdown,
                    createdAt: values?.creationDate ?? Date(), updatedAt: values?.contentModificationDate ?? Date())
    }

    private func fileURL(for noteID: UUID) -> URL {
        let markdown = folderURL.appendingPathComponent("\(noteID.uuidString).md")
        if fileManager.fileExists(atPath: markdown.path) { return markdown }
        return folderURL.appendingPathComponent("\(noteID.uuidString).json")
    }

    // MARK: - CRUD

    /// Creates a new note and adds it to the store.
    func create(title: String = "Untitled Note") throws -> Note {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NoteStoreError.invalidTitle
        }
        var note = Note(title: title)
        note.version = NoteDocument.currentVersion
        note.document = NoteDocument(title: title)
        try save(note)
        notes.insert(note, at: 0)
        return note
    }

    /// Fetches a note by ID, or throws if not found.
    func note(_ id: UUID) throws -> Note {
        guard let note = notes.first(where: { $0.id == id }) else {
            throw NoteStoreError.noteNotFound(id)
        }
        return note
    }

    /// Updates an existing note's title and/or blocks.
    func update(_ note: Note, title: String? = nil, blocks: [NoteBlock]? = nil) throws {
        var updated = note
        if let title { updated.title = title }
        if let blocks { updated.blocks = blocks }
        updated.updatedAt = Date()
        try save(updated)
        notes.removeAll { $0.id == note.id }
        notes.insert(updated, at: 0)
    }

    /// Creates a note whose first page is a card board.
    func createBoard(title: String = "Untitled Board") throws -> Note {
        var note = try create(title: title)
        note.document = NoteDocument(title: title, pages: [Page(name: "Board", isBoard: true)])
        try save(note)
        replace(note)
        return note
    }

    /// Replaces a note's document (title follows it). The one write path the editors use.
    func updateDocument(_ document: NoteDocument, for noteID: UUID) throws {
        var note = try note(noteID)
        note.document = document
        note.version = NoteDocument.currentVersion
        if let title = document.title, !title.trimmingCharacters(in: .whitespaces).isEmpty { note.title = title }
        note.updatedAt = Date()
        try save(note)
        replace(note)
    }

    private func replace(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        notes.insert(note, at: 0)
    }

    /// Appends a block to a note.
    func appendBlock(_ block: NoteBlock, to noteID: UUID) throws {
        var note = try note(noteID)
        note.blocks.append(block)
        note.updatedAt = Date()
        try save(note)
        notes.removeAll { $0.id == noteID }
        notes.insert(note, at: 0)
    }

    /// Removes a block from a note by index.
    func removeBlock(at index: Int, from noteID: UUID) throws {
        var note = try note(noteID)
        guard index >= 0, index < note.blocks.count else { return }
        note.blocks.remove(at: index)
        note.updatedAt = Date()
        try save(note)
        notes.removeAll { $0.id == noteID }
        notes.insert(note, at: 0)
    }

    /// Deletes a note entirely.
    func delete(_ noteID: UUID) throws {
        let url = fileURL(for: noteID)
        try fileManager.removeItem(at: url)
        notes.removeAll { $0.id == noteID }
    }

    // MARK: - Persistence

    private func save(_ note: Note) throws {
        // The agent's markdown notes are its own: the app never rewrites them.
        guard note.markdown == nil else { return }
        let data = try encoder.encode(note)
        try data.write(to: fileURL(for: note.id), options: .atomic)
    }
}
