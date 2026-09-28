//
//  LocalDataErase.swift
//  leanring-buddy
//
//  Settings → "Erase HeyMate data". Removes HeyMate's Application Support
//  files and the keychain secrets that belong to them. Project folders
//  under ~/Projects are never touched.
//

import Foundation

enum LocalDataErase {

    static let persistErrorDefaultsKey = "heymate.lastPersistError"
    static let persistFailedNotification = Notification.Name("heymate.persistFailed")

    /// Shown after erase. Mate and agent stores keep their lists in memory
    /// and have no safe rebuild from the UI, so a restart finishes the job.
    static let restartNote = "Quit and reopen HeyMate to finish erasing mates and agents."

    static let confirmationMessage = """
    This erases mates, chats, routines, memories, agent run history, standing order markdown files in the app's standing-orders folder, behavior contract edits (the file will be re-seeded), connector connection records and their keychain secrets, Composio API key, and custom API key. Project folders under ~/Projects are not deleted.
    """

    /// Deletes the on-disk data and the in-memory pieces that are safe to
    /// clear from the UI. Returns the restart note.
    @MainActor
    static func erase(
        companionManager: CompanionManager,
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard
    ) -> String {
        removeHeyMateSupportFile(FileMateStore.appSupportFileURL(), fileManager: fileManager)
        removeHeyMateSupportFile(FileChatHistoryStore.appSupportFileURL(), fileManager: fileManager)
        removeHeyMateSupportFile(FileMateRoutineStore.appSupportFileURL(), fileManager: fileManager)
        removeHeyMateSupportFile(FileMemoryRepository.appSupportFileURL(), fileManager: fileManager)
        removeHeyMateSupportFile(FileAgentRunStore.appSupportFileURL(), fileManager: fileManager)
        removeStandingOrderMarkdown(fileManager: fileManager)

        let contractURL = BehaviorContract.fileURL()
        removeHeyMateSupportFile(contractURL, fileManager: fileManager)
        BehaviorContract.seedIfNeeded(fileManager: fileManager)

        eraseSecretsAndConnectionRecords(userDefaults: userDefaults)

        companionManager.clearAllChats()
        companionManager.clearAllMemory()
        companionManager.notchActivityCenter.clipboardStore.clear()
        companionManager.reloadStandingOrders()

        return restartNote
    }

    // MARK: - Files

    private static func heymateSupportRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("heymate", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    /// True only for a file or folder strictly inside Application Support/heymate.
    /// The heymate directory itself, and anything that resolves outside it, is refused.
    private static func isInsideHeyMateSupport(_ url: URL) -> Bool {
        let rootPath = heymateSupportRoot().path
        guard rootPath.contains("/heymate") else { return false }
        let candidatePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private static func removeHeyMateSupportFile(_ url: URL, fileManager: FileManager) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard isInsideHeyMateSupport(resolved) else { return }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        guard !isDirectory.boolValue else { return }
        try? fileManager.removeItem(at: url)
    }

    private static func removeStandingOrderMarkdown(fileManager: FileManager) {
        let directoryURL = FileStandingOrderRepository.appSupportDirectoryURL()
        guard isInsideHeyMateSupport(directoryURL) else { return }
        let fileURLs = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for fileURL in fileURLs where fileURL.pathExtension.lowercased() == "md" {
            removeHeyMateSupportFile(fileURL, fileManager: fileManager)
        }
    }

    // MARK: - Secrets and connection records

    /// Keychain accounts that are not connector credentials and must survive erase.
    private static var preservedKeychainAccounts: Set<String> {
        [
            HeyMateExternalControlAuth.mintedTokenConnectorID,
            CompanionManager.openCodeBasicAuthPasswordKeychainIdentifier
        ]
    }

    private static func eraseSecretsAndConnectionRecords(userDefaults: UserDefaults) {
        var identifiers = Set(ConnectorCatalog.all.map(\.id))
        identifiers.insert(ComposioSessionStore.connectorID)
        if let data = userDefaults.data(forKey: ConnectorStore.recordsPreferenceKey),
           let records = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            identifiers.formUnion(records.keys)
        }
        identifiers.subtract(preservedKeychainAccounts)
        identifiers.remove(CustomAPIConfiguration.keychainIdentifier)

        for identifier in identifiers where !identifier.isEmpty {
            ConnectorSecretStore.deleteSecret(forConnectorID: identifier)
        }
        CustomAPIConfiguration.setAPIKey("")

        userDefaults.removeObject(forKey: ConnectorStore.recordsPreferenceKey)
        userDefaults.removeObject(forKey: ComposioConnectionsRuntime.recordsPreferenceKey)
        ComposioSessionStore.clear(userDefaults: userDefaults)
    }
}
