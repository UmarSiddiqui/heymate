//
//  MateRoutineStore.swift
//  HeyMate
//
//  Application Support/heymate/routines.json.
//

import Foundation

@MainActor
final class FileMateRoutineStore {

    private let fileURL: URL
    private var routines: [MateRoutine]

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let fileData = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([MateRoutine].self, from: fileData) {
            self.routines = decoded
        } else {
            self.routines = []
        }
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
            let fileData = try encoder.encode(routines)
            try fileData.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort: an unwritable volume should not crash the app.
            UserDefaults.standard.set(error.localizedDescription, forKey: "heymate.lastPersistError")
            NotificationCenter.default.post(name: Notification.Name("heymate.persistFailed"), object: nil)
        }
    }
}
