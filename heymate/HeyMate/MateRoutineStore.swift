//
//  MateRoutineStore.swift
//  HeyMate
//
//  Application Support/heymate/routines.json, plus routines-more.json for
//  schedules added in 1.0.92 (weekdays, one day a week, minutes). A build
//  from before then decodes routines.json as one array and loses all of it
//  on a case it does not know, so the new kinds never go in that file.
//

import Foundation

@MainActor
final class FileMateRoutineStore {

    private let fileURL: URL
    private let extendedFileURL: URL
    private var routines: [MateRoutine]

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.extendedFileURL = Self.extendedFileURL(for: fileURL)
        self.routines = Self.read(fileURL) + Self.read(extendedFileURL)
    }

    nonisolated static func extendedFileURL(for fileURL: URL) -> URL {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        return fileURL.deletingLastPathComponent().appendingPathComponent("\(stem)-more.json")
    }

    /// Reads what it can: one unreadable routine does not cost the rest.
    private static func read(_ url: URL) -> [MateRoutine] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(LossyArray<MateRoutine>.self, from: data) else { return [] }
        return decoded.elements
    }

    func loadAll() -> [MateRoutine] {
        routines.sorted { $0.nextRunAt < $1.nextRunAt }
    }

    func upsert(_ routine: MateRoutine) {
        routines.removeAll { $0.id == routine.id }
        routines.append(routine)
        persist()
    }

    func delete(id: UUID) {
        routines.removeAll { $0.id == id }
        persist()
    }

    func deleteAll(mateID: UUID) {
        routines.removeAll { $0.mateID == mateID }
        persist()
    }

    nonisolated static func appSupportFileURL() -> URL {
        let applicationSupportDirectory = HeyMateDataDirectory.applicationSupportURL
        let heymateDirectory = applicationSupportDirectory.appendingPathComponent("heymate", isDirectory: true)
        try? FileManager.default.createDirectory(at: heymateDirectory, withIntermediateDirectories: true)
        return heymateDirectory.appendingPathComponent("routines.json")
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let extended = routines.filter(\.schedule.isExtended)
            try encoder.encode(routines.filter { !$0.schedule.isExtended }).write(to: fileURL, options: .atomic)
            if extended.isEmpty {
                try? FileManager.default.removeItem(at: extendedFileURL)
            } else {
                try encoder.encode(extended).write(to: extendedFileURL, options: .atomic)
            }
        } catch {
            // Best-effort: an unwritable volume should not crash the app.
            UserDefaults.standard.set(error.localizedDescription, forKey: "heymate.lastPersistError")
            NotificationCenter.default.post(name: Notification.Name("heymate.persistFailed"), object: nil)
        }
    }
}
