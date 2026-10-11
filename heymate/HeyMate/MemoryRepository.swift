//
//  MemoryRepository.swift
//  HeyMate
//
//  Privacy-conscious long-term memory (text only). The model may remember
//  what was *said* about the user's projects and preferences, never what
//  was *seen*: raw screenshots and microphone audio are structurally
//  impossible to store because MemoryItem has no binary field by design.
//  Every record is inspectable and deletable so the user stays in control.
//

import Foundation

/// What kind of thing a memory record represents. Drives trimming policy:
/// session summaries are disposable rolling context; preferences and
/// project facts are durable user knowledge that must never be trimmed away.
nonisolated enum MemoryKind: String, Codable, CaseIterable {
    /// Rolling text summary of recent conversation turns.
    case sessionSummary
    /// User-approved stable preference.
    case preference
    /// Named project/entity fact.
    case projectFact
}

/// One inspectable/deletable memory record.
///
/// TEXT ONLY by design — see the privacy invariant in the file header.
/// Do NOT add image/audio/binary fields to this type; keeping the store
/// text-only is what makes "the app cannot retain captures" true without
/// trusting any call-site discipline.
nonisolated struct MemoryItem: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: MemoryKind
    var text: String
    let createdAt: Date
    /// Nil keeps explicit preferences and project facts shared. Old summaries
    /// have no provable owner: retain them for inspection, but never replay
    /// them into a mate's conversation.
    var mateID: UUID? = nil
}

nonisolated enum MemoryContext {
    /// Owner of HeyMate's own talk memory. Talk is not a mate, so it gets a
    /// fixed id of its own instead of borrowing First Mate's.
    static let heyMateTalkOwnerID = UUID(uuidString: "4E7A11C0-0000-4000-8000-000000000001")!

    static func items(_ items: [MemoryItem], for mateID: UUID?) -> [MemoryItem] {
        items.filter { item in
            if let owner = item.mateID { return owner == mateID }
            return item.kind != .sessionSummary
        }
    }
}

/// Storage surface for memory records. `AnyObject` so ownership semantics
/// are explicit (a single store instance, not value-copied snapshots).
nonisolated protocol MemoryRepository: AnyObject {
    /// All stored memories, oldest-first by creation date.
    func loadAll() -> [MemoryItem]
    func append(_ item: MemoryItem)
    func delete(id: UUID)
    func deleteAll()
    /// Replaces the text of one record and persists. Empty or whitespace-only
    /// text is refused. An unknown id leaves the store unchanged.
    func update(id: UUID, text: String)
}

/// JSON-file backed store (Application Support/heymate/memory.json in prod).
///
/// Writes are atomic so a crash mid-save can never leave a truncated file
/// behind. On every append the file is capped by trimming the OLDEST
/// sessionSummaries beyond `maxSessionSummaries` — preferences and project
/// facts are never trimmed, because losing a user's stable knowledge is a
/// correctness bug while losing old conversation context is the point of
/// a rolling summary.
@MainActor
final class FileMemoryRepository: MemoryRepository {

    private let fileURL: URL
    private let maxSessionSummaries: Int

    /// In-memory mirror of the file. Kept as the single source of truth for
    /// reads so loadAll() never hits disk; every mutation persists before
    /// returning, so a new instance always observes prior mutations.
    private var items: [MemoryItem]

    init(fileURL: URL, maxSessionSummaries: Int = 20) {
        self.fileURL = fileURL
        self.maxSessionSummaries = maxSessionSummaries

        // A missing file is a fresh store; a corrupt file degrades to an
        // empty store instead of crashing. Recovering with lost memory beats
        // a launch failure — and the next append atomically rewrites the
        // file, so the store heals itself rather than staying broken.
        if let fileData = try? Data(contentsOf: fileURL),
           let decodedItems = try? JSONDecoder().decode([MemoryItem].self, from: fileData) {
            self.items = decodedItems
        } else {
            self.items = []
        }
    }

    // MARK: - MemoryRepository

    func loadAll() -> [MemoryItem] {
        items.sorted { $0.createdAt < $1.createdAt }
    }

    func append(_ item: MemoryItem) {
        items.append(item)
        trimExcessSessionSummaries()
        persist()
    }

    /// Refreshes only this mate's rolling context in one write. Legacy
    /// unowned records stay intact, and another mate's summary is untouched.
    func updateSessionSummary(mateID: UUID, text: String, now: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.removeAll { $0.kind == .sessionSummary && $0.mateID == mateID }
        items.append(MemoryItem(
            id: UUID(), kind: .sessionSummary, text: trimmed, createdAt: now, mateID: mateID
        ))
        trimExcessSessionSummaries()
        persist()
    }

    func delete(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func deleteAll() {
        items.removeAll()
        persist()
    }

    func update(id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        items[index].text = trimmed
        persist()
    }

    // MARK: - Production location

    /// Default store location: `<Application Support>/heymate/memory.json`.
    /// The heymate directory is auto-created so first launch needs no setup.
    nonisolated static func appSupportFileURL() -> URL {
        let applicationSupportDirectory = HeyMateDataDirectory.applicationSupportURL
        let heymateDirectory = applicationSupportDirectory.appendingPathComponent("heymate", isDirectory: true)
        try? FileManager.default.createDirectory(at: heymateDirectory, withIntermediateDirectories: true)
        return heymateDirectory.appendingPathComponent("memory.json")
    }

    // MARK: - Trimming

    /// Drops the oldest session summaries beyond the cap, leaving preferences
    /// and project facts untouched regardless of how many accumulate.
    private func trimExcessSessionSummaries() {
        let sessionSummariesSortedOldestFirst = items
            .filter { $0.kind == .sessionSummary }
            .sorted { $0.createdAt < $1.createdAt }

        let summaryCountToRemove = sessionSummariesSortedOldestFirst.count - maxSessionSummaries
        guard summaryCountToRemove > 0 else { return }

        let idsToRemove = Set(
            sessionSummariesSortedOldestFirst
                .prefix(summaryCountToRemove)
                .map(\.id)
        )
        items.removeAll { idsToRemove.contains($0.id) }
    }

    // MARK: - Persistence

    private func persist() {
        let encoder = JSONEncoder()

        // Default Date encoding (seconds since reference date) keeps full
        // precision, so oldest-first ordering and trimming stay deterministic
        // even when records are created within the same wall-clock second.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let fileData = try encoder.encode(items)
            try fileData.write(to: fileURL, options: .atomic)
        } catch {
            // Persisting is best-effort: an unwritable volume should degrade
            // to in-memory-only operation, never crash the app. Record the
            // failure so the rest of the app can surface it.
            UserDefaults.standard.set(
                error.localizedDescription,
                forKey: "heymate.lastPersistError"
            )
            NotificationCenter.default.post(
                name: Notification.Name("heymate.persistFailed"),
                object: nil
            )
        }
    }
}
