//
//  CompanionManager+MateSettings.swift
//  HeyMate
//
//  The actions agent settings needs that didn't exist before the redesign:
//  a per-mate model, changing a mate's folder, file history size and clear,
//  and deep links that open one mate's settings on one section.
//

import AppKit
import Combine
import Foundation

/// "Open this mate's settings on that section" from anywhere in the app: the
/// approval card's Always allow, a heartbeat proposal, the browser panel.
/// The chat view that owns the settings sheet consumes the request.
@MainActor
final class MateSettingsRouter: ObservableObject {
    static let shared = MateSettingsRouter()

    struct Request: Equatable, Identifiable {
        let id = UUID()
        let mateID: UUID
        let section: MateSettingsSection
    }

    @Published private(set) var pending: Request?
    /// A mate whose Files view should open once the settings sheet has closed.
    @Published private(set) var filesMateID: UUID?

    func open(mateID: UUID, section: MateSettingsSection) {
        pending = Request(mateID: mateID, section: section)
        // Brings the desktop window back to chat, where the sheet lives.
        NotificationCenter.default.post(
            name: .heyMateDesktopSelectSection, object: nil,
            userInfo: ["section": DesktopSection.chat.rawValue]
        )
    }

    /// Takes the pending request so it opens once.
    func take() -> Request? {
        defer { pending = nil }
        return pending
    }

    func openFiles(mateID: UUID) { filesMateID = mateID }

    func takeFiles() -> UUID? {
        defer { filesMateID = nil }
        return filesMateID
    }
}

extension CompanionManager {
    var mateAgentSettings: MateAgentSettingsStore { .shared }

    /// Opens the desktop window on chat and that mate's settings on `section`.
    func openMateSettings(mateID: UUID, section: MateSettingsSection) {
        openDesktopWindow(section: .chat)
        MateSettingsRouter.shared.open(mateID: mateID, section: section)
    }

    // MARK: Brain

    /// Changes the mate's brain; a model chosen for another provider is dropped.
    func setMateBrainChoice(id: UUID, brain: AgentBrain?) {
        let before = mateDirectory.mates.first { $0.id == id }?.brainRawValue
        setMatePrimaryBrain(id: id, brain: brain)
        guard before != brain?.rawValue else { return }
        setMateModel(id: id, model: nil)
    }

    /// Nil follows the provider's model (HeyMate's when the provider matches).
    func setMateModel(id: UUID, model: String?) {
        guard var mate = mateDirectory.mates.first(where: { $0.id == id }) else { return }
        let cleaned = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = (cleaned?.isEmpty == false) ? cleaned : nil
        guard mate.modelID != next else { return }
        mate.modelID = next
        mate.updatedAt = Date()
        guard mateDirectory.upsertMate(mate) else { return }
        syncMatePublications()
    }

    // MARK: Folder

    /// Points the mate at another folder. Nil when done, else why not.
    @discardableResult
    func changeMateFolder(id: UUID, to folder: URL) -> String? {
        guard let mate = mateDirectory.mates.first(where: { $0.id == id }), !mate.conductsOthers else {
            return "This agent doesn't keep a folder."
        }
        if let refusal = MateFolderChoice.refusal(for: folder) { return refusal }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "That folder isn't there any more."
        }
        mateDirectory.updateFolderPath(id: id, path: folder.standardizedFileURL.path)
        // Writes AGENTS.md and CLAUDE.md into the new folder, keeping any there.
        ensureMateFolder(id: id)
        return nil
    }

    // MARK: Limits and quiet hours

    func mateQuietHours(_ mateID: UUID) -> MateQuietHours {
        mateAgentSettings.settings(for: mateID).quietHours
    }

    func mateLimits(_ mateID: UUID) -> MateAgentLimits {
        mateAgentSettings.settings(for: mateID).limits
    }

    func recordMateActivity(_ counter: MateActivityDay.Counter, mateID: UUID?) {
        guard let mateID, !HeyMateDataDirectory.isUnitTestHost else { return }
        mateAgentSettings.record(counter, mateID: mateID)
    }
}

// MARK: - File history storage

extension MateFileStore {
    /// Bytes kept for earlier versions of this folder's files.
    func historyBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: versionsURL, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    /// Removes every earlier version. The files themselves and where they came from stay.
    func clearHistory() throws {
        guard FileManager.default.fileExists(atPath: versionsURL.path) else { return }
        try FileManager.default.removeItem(at: versionsURL)
    }
}
