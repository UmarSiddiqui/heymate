//
//  MateStore.swift
//  HeyMate
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

    /// Removes an agent. The main HeyMate agent is permanent, so deleting
    /// it, or an unknown id, does nothing and returns false.
    @discardableResult
    func delete(id: UUID) -> Bool {
        guard id != catalog.defaultMateID,
              catalog.mates.contains(where: { $0.id == id }) else { return false }
        catalog.mates.removeAll { $0.id == id }
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

    /// A stock default ("HeyMate / General chat" or "First Mate") becomes the
    /// current main agent. One the user already renamed keeps that name and
    /// still conducts.
    static func promoted(_ catalog: MateCatalogFile) -> MateCatalogFile {
        var catalog = catalog
        guard let index = catalog.mates.firstIndex(where: { $0.id == catalog.defaultMateID }) else {
            return catalog
        }
        var mate = catalog.mates[index]
        mate.conductsOthers = true
        let legacyStock = normalized(mate.name) == normalized(Mate.legacyDefaultName)
            && normalized(mate.job) == normalized(Mate.legacyDefaultJob)
            && mate.soul.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let previousStock = normalized(mate.name) == normalized(Mate.previousDefaultName)
            && normalized(mate.job) == normalized(Mate.previousDefaultJob)
            && [Mate.previousFirstMateSoul, ""].contains(mate.soul.trimmingCharacters(in: .whitespacesAndNewlines))
        if legacyStock || previousStock {
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
