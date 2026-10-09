//
//  MateStore.swift
//  leanring-buddy
//
//  Application Support/heymate/mates.json. The first load with no mates
//  seeds HeyMate so older chats have somewhere to land.
//

import Foundation

nonisolated struct MateCatalogFile: Codable, Equatable {
    var defaultMateID: UUID
    var mates: [Mate]
}

@MainActor
final class FileMateStore {

    private let fileURL: URL
    private var catalog: MateCatalogFile

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let fileData = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(MateCatalogFile.self, from: fileData),
           !decoded.mates.isEmpty {
            let promoted = Self.promoted(decoded)
            self.catalog = promoted
            if promoted != decoded { persist() }
        } else {
            let seeded = Self.makeDefaultMate()
            self.catalog = MateCatalogFile(defaultMateID: seeded.id, mates: [seeded])
            persist()
        }
    }

    var defaultMateID: UUID { catalog.defaultMateID }

    func loadAll() -> [Mate] {
        catalog.mates.sorted { $0.updatedAt > $1.updatedAt }
    }

    func mate(id: UUID) -> Mate? {
        catalog.mates.first { $0.id == id }
    }

    @discardableResult
    func upsert(_ mate: Mate) -> Bool {
        if isNameTaken(mate.name, excluding: mate.id) { return false }
        catalog.mates.removeAll { $0.id == mate.id }
        catalog.mates.append(mate)
        persist()
        return true
    }

    /// Removes a mate. Deleting the default promotes the most recently updated
    /// active mate and makes them the conductor. If that leaves no active mate,
    /// `makeDefaultMate` is seeded and archived mates stay. Unknown ids do nothing.
    @discardableResult
    func delete(id: UUID) -> Bool {
        guard catalog.mates.contains(where: { $0.id == id }) else { return false }
        let deletedDefault = catalog.defaultMateID == id
        catalog.mates.removeAll { $0.id == id }
        let active = catalog.mates.filter { !$0.archived }
        if active.isEmpty {
            let seeded = Self.makeDefaultMate()
            catalog.mates.append(seeded)
            catalog.defaultMateID = seeded.id
        } else if deletedDefault {
            let promoted = active.max { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
                return lhs.createdAt < rhs.createdAt
            }
            if let promoted, let index = catalog.mates.firstIndex(where: { $0.id == promoted.id }) {
                catalog.defaultMateID = promoted.id
                catalog.mates[index].conductsOthers = true
            }
        }
        persist()
        return true
    }

    func archive(id: UUID) {
        guard id != catalog.defaultMateID else { return }
        guard let index = catalog.mates.firstIndex(where: { $0.id == id }) else { return }
        guard !catalog.mates[index].conductsOthers else { return }
        catalog.mates[index].archived = true
        catalog.mates[index].updatedAt = Date()
        persist()
    }

    func isNameTaken(_ name: String, excluding id: UUID? = nil) -> Bool {
        let key = Self.normalized(name)
        guard !key.isEmpty else { return false }
        return catalog.mates.contains { mate in
            guard !mate.archived, mate.id != id else { return false }
            return Self.normalized(mate.name) == key
        }
    }

    nonisolated static func appSupportFileURL() -> URL {
        let applicationSupportDirectory = HeyMateDataDirectory.applicationSupportURL
        let heymateDirectory = applicationSupportDirectory.appendingPathComponent("heymate", isDirectory: true)
        try? FileManager.default.createDirectory(at: heymateDirectory, withIntermediateDirectories: true)
        return heymateDirectory.appendingPathComponent("mates.json")
    }

    nonisolated static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// The stock "HeyMate / General chat" seed becomes First Mate. A default
    /// mate the user already renamed keeps that name and still conducts.
    static func promoted(_ catalog: MateCatalogFile) -> MateCatalogFile {
        var catalog = catalog
        guard let index = catalog.mates.firstIndex(where: { $0.id == catalog.defaultMateID }) else {
            return catalog
        }
        var mate = catalog.mates[index]
        mate.conductsOthers = true
        let stockName = normalized(mate.name) == normalized(Mate.legacyDefaultName)
        let stockJob = normalized(mate.job) == normalized(Mate.legacyDefaultJob)
        let untouchedSoul = mate.soul.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if stockName && stockJob && untouchedSoul {
            mate.name = Mate.defaultName
            mate.job = Mate.defaultJob
            mate.soul = Mate.firstMateSoul
            mate.pinned = true
        }
        catalog.mates[index] = mate
        return catalog
    }

    private static func makeDefaultMate(now: Date = Date()) -> Mate {
        Mate(
            id: UUID(),
            name: Mate.defaultName,
            job: Mate.defaultJob,
            pinned: true,
            archived: false,
            unreadCount: 0,
            createdAt: now,
            updatedAt: now,
            memoryNote: "",
            folderPath: nil,
            soul: Mate.firstMateSoul,
            conductsOthers: true
        )
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let fileData = try encoder.encode(catalog)
            try fileData.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort: an unwritable volume should not crash the app.
        }
    }
}
