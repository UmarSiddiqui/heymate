//
//  MateAgentSettingsStore.swift
//  HeyMate
//
//  Saves MateAgentSettings and today's activity counts in one small JSON file
//  under HeyMateDataDirectory (`mate-agent-settings.json`). Writes happen as
//  each control changes; nothing here starts a model call.
//

import Combine
import Foundation

@MainActor
final class MateAgentSettingsStore: ObservableObject {
    static let shared = MateAgentSettingsStore()
    static let fileName = "mate-agent-settings.json"

    @Published private(set) var file = MateAgentSettingsFile()
    private let fileURL: URL
    private let now: () -> Date

    init(fileURL: URL = HeyMateDataDirectory.url.appendingPathComponent(MateAgentSettingsStore.fileName),
         now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        if let data = try? Data(contentsOf: fileURL), data.count < 4 * 1_024 * 1_024,
           let decoded = try? JSONDecoder().decode(MateAgentSettingsFile.self, from: data) {
            file = decoded
        }
    }

    func settings(for mateID: UUID) -> MateAgentSettings {
        file.mates[mateID.uuidString] ?? MateAgentSettings()
    }

    func update(_ mateID: UUID, _ change: (inout MateAgentSettings) -> Void) {
        var entry = settings(for: mateID)
        change(&entry)
        guard entry != settings(for: mateID) else { return }
        file.mates[mateID.uuidString] = entry
        save()
    }

    /// Drops a deleted mate's settings and counts.
    func remove(_ mateID: UUID) {
        let key = mateID.uuidString
        guard file.mates[key] != nil || file.activity[key] != nil else { return }
        file.mates[key] = nil
        file.activity[key] = nil
        save()
    }

    // MARK: Activity

    func record(_ counter: MateActivityDay.Counter, mateID: UUID) {
        let key = mateID.uuidString
        file.activity[key] = MateActivityDay.incremented(file.activity[key], counter, now: now())
        save()
    }

    func today(for mateID: UUID) -> MateActivityDay {
        MateActivityDay.today(file.activity[mateID.uuidString], now: now())
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: fileURL, options: [.atomic])
        } catch {
            HeyMateLog.log("⚠️ Could not save agent settings: \(error.localizedDescription)")
        }
    }
}

extension ApprovalMode {
    /// HeyMate's approval mode as it applies to one mate: never looser than global.
    @MainActor
    static func current(forMateID mateID: UUID?, defaults: UserDefaults = .standard,
                        store: MateAgentSettingsStore = .shared) -> ApprovalMode {
        let global = current(defaults)
        guard let mateID else { return global }
        return MatePermissionResolver.effectiveMode(global: global, override: store.settings(for: mateID).approval)
    }
}
