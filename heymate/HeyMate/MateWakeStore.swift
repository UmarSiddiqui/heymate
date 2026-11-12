//
//  MateWakeStore.swift
//  HeyMate
//
//  Application Support/heymate/agent-wakes.json. Its own file, so a build
//  that has never heard of wakes leaves routines and agents alone. Entries
//  are decoded one by one: a wake kind added later costs an older build
//  that one entry, not the whole list.
//

import Foundation

/// Decodes what it can from an array and skips the rest.
nonisolated struct LossyArray<Element: Decodable>: Decodable {
    private struct Skipped: Decodable {}
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var kept: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                kept.append(element)
            } else {
                _ = try? container.decode(Skipped.self)
            }
        }
        elements = kept
    }
}

@MainActor
final class FileMateWakeStore {
    private let fileURL: URL
    private var wakes: [MateWake]

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(LossyArray<MateWake>.self, from: data) {
            wakes = decoded.elements
        } else {
            wakes = []
        }
    }

    func loadAll() -> [MateWake] { wakes }

    func upsert(_ wake: MateWake) {
        if let index = wakes.firstIndex(where: { $0.id == wake.id }) {
            wakes[index] = wake
        } else {
            wakes.append(wake)
        }
        persist()
    }

    func delete(id: UUID) {
        wakes.removeAll { $0.id == id }
        persist()
    }

    func deleteAll(mateID: UUID) {
        guard wakes.contains(where: { $0.mateID == mateID }) else { return }
        wakes.removeAll { $0.mateID == mateID }
        persist()
    }

    nonisolated static func appSupportFileURL() -> URL {
        let directory = HeyMateDataDirectory.applicationSupportURL
            .appendingPathComponent("heymate", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("agent-wakes.json")
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(wakes).write(to: fileURL, options: .atomic)
        } catch {
            UserDefaults.standard.set(error.localizedDescription, forKey: "heymate.lastPersistError")
            NotificationCenter.default.post(name: Notification.Name("heymate.persistFailed"), object: nil)
        }
    }
}
