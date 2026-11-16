//
//  MateSettingsFilesPane.swift
//  HeyMate
//
//  Agent settings › Files & Browser: the agent's folder (reveal, change, the
//  Files view), the space its file history uses with Clear history, and its
//  browser: a persistent signed-in profile, Sign out of everything, and
//  whether the live browser view starts open. HeyMate itself keeps no
//  folder, so only the browser part shows for it.
//

import AppKit
import SwiftUI

struct MateSettingsFilesPane: View {
    let context: MateSettingsContext
    @ObservedObject private var companionManager: CompanionManager
    @ObservedObject private var browsers = IsolatedBrowserWorkers.shared
    @ObservedObject private var settings = MateAgentSettingsStore.shared
    @State private var historyBytes: Int64?
    @State private var folderNotice: (text: String, tone: SettingsStatusTone)?
    @State private var browserNotice: (text: String, tone: SettingsStatusTone)?

    init(context: MateSettingsContext) {
        self.context = context
        self.companionManager = context.companionManager
    }

    private var mate: Mate { context.mate }
    private var folderURL: URL? {
        guard let path = mate.folderPath, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.SettingsLayout.sectionSpacing) {
            if !mate.conductsOthers {
                folderSection
                historySection
            }
            browserSection
        }
        .task(id: mate.folderPath) { await measureHistory() }
    }

    // MARK: Folder

    private var folderSection: some View {
        SettingsSection("Folder", footer: "Its memory (AGENTS.md), its files, and what it makes live here.") {
            SettingsRow("Folder", subtitle: folderURL.map { ($0.path as NSString).abbreviatingWithTildeInPath }
                        ?? "No folder yet. One is made the first time it works with files.", systemImage: "folder") {
                HStack(spacing: DS.Spacing.sm) {
                    if let folderURL {
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([folderURL]) }
                            .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                            .accessibilityLabel("Reveal folder in Finder")
                    }
                    Button(folderURL == nil ? "Choose…" : "Change…") { chooseFolder() }
                        .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                        .accessibilityLabel(folderURL == nil ? "Choose a folder" : "Change folder")
                }
            }
            .mateSettingsAnchor("files.folder")
            if let folderNotice {
                SettingsInlineHelp(folderNotice.text, tone: folderNotice.tone).settingsRowContentInsets()
            }
            if folderURL != nil {
                SettingsDivider()
                MateSettingsLinkRow(title: "Open Files", subtitle: "Where each file came from, and its earlier versions.",
                                    systemImage: "doc.on.doc") {
                    context.close()
                    MateSettingsRouter.shared.openFiles(mateID: mate.id)
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for \(mate.name)"
        panel.message = "\(mate.name) can read and write files here. Its AGENTS.md is added if missing."
        panel.prompt = "Use folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let refusal = companionManager.changeMateFolder(id: mate.id, to: url) {
            folderNotice = (refusal, .attention)
        } else {
            folderNotice = ("Now using \((url.path as NSString).abbreviatingWithTildeInPath).", .positive)
        }
    }

    // MARK: History

    private var historySection: some View {
        SettingsSection("File history", footer: "Earlier versions are kept for files HeyMate or the agent changed, up to \(MateFileVersionPolicy.maximumPerFile) per file.") {
            SettingsDestructiveRow(
                title: "Earlier versions",
                subtitle: historyBytes.map { $0 == 0 ? "Nothing saved yet." : "\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) on this Mac." }
                    ?? "Measuring…",
                buttonTitle: "Clear history…",
                confirmationTitle: "Clear \(mate.name)'s file history?",
                confirmationMessage: "Earlier versions of its files are deleted for good and can't be restored. The files themselves stay.",
                confirmButtonTitle: "Clear history",
                isEnabled: folderURL != nil && (historyBytes ?? 0) > 0
            ) {
                clearHistory()
            }
            .mateSettingsAnchor("files.history")
        }
    }

    private func measureHistory() async {
        guard let folderURL else { historyBytes = 0; return }
        let store = MateFileStore(folder: folderURL)
        historyBytes = await Task.detached(priority: .utility) { store.historyBytes() }.value
    }

    private func clearHistory() {
        guard let folderURL else { return }
        do {
            try MateFileStore(folder: folderURL).clearHistory()
            historyBytes = 0
        } catch {
            folderNotice = ("Couldn't clear history: \(error.localizedDescription)", .critical)
        }
    }

    // MARK: Browser

    private var browserSection: some View {
        let persistent = browsers.isPersistent(mate.id)
        return SettingsSection("Browser", footer: "Its browser is a separate Chrome profile: never your own Chrome, never another agent's.") {
            SettingsToggleRow(
                "Keep its sign-ins",
                subtitle: persistent
                    ? "Uses its own persistent profile. Sites stay signed in between tasks."
                    : "Each chat gets a temporary profile that's deleted when it closes.",
                isOn: Binding(
                    get: { browsers.isPersistent(mate.id) },
                    set: { value in
                        if !browsers.setPersistentBrowser(value, for: mate.id) {
                            browserNotice = ("Another agent already has a private browser.", .attention)
                        } else {
                            browserNotice = nil
                        }
                    }
                )
            )
            .disabled(mate.archived)
            .mateSettingsAnchor("files.browser")
            if let state = browsers.live[mate.id] {
                SettingsDivider()
                SettingsRow("Now", subtitle: [state.title, state.url].filter { !$0.isEmpty }.joined(separator: " · "),
                            systemImage: "globe") {
                    SettingsStatusBadge(text: state.isWorking ? "Working" : "Idle", tone: state.isWorking ? .progress : .neutral)
                }
            }
            SettingsDivider()
            SettingsDestructiveRow(
                title: "Sign out of everything",
                subtitle: "Closes its browser and moves its saved profile (cookies, sign-ins, history) to the Trash.",
                buttonTitle: "Sign out…",
                confirmationTitle: "Sign \(mate.name) out of every site?",
                confirmationMessage: "Its browser closes now and its profile goes to the Trash. Your own Chrome isn't touched.",
                confirmButtonTitle: "Sign out"
            ) {
                signOutEverywhere()
            }
            if let browserNotice {
                SettingsInlineHelp(browserNotice.text, tone: browserNotice.tone).settingsRowContentInsets()
            }
            SettingsDivider()
            SettingsToggleRow(
                "Show the live view open",
                subtitle: "In its chat, the picture of what its browser is on starts open. You can still fold it.",
                isOn: Binding(
                    get: { settings.settings(for: mate.id).browserPanelStartsOpen },
                    set: { value in settings.update(mate.id) { $0.browserPanelStartsOpen = value } }
                )
            )
            .mateSettingsAnchor("files.livePanel")
        }
    }

    /// Where the browser driver keeps a named profile.
    static func profileDirectory(for mateID: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CuaDriver/BrowserProfiles", isDirectory: true)
            .appendingPathComponent(IsolatedBrowserProfiles.profileName(for: mateID), isDirectory: true)
    }

    private func signOutEverywhere() {
        let wasPersistent = browsers.isPersistent(mate.id)
        // Turning the profile off retires its open browser first.
        if wasPersistent {
            browsers.setPersistentBrowser(false, for: mate.id)
        }
        let directory = Self.profileDirectory(for: mate.id)
        var trashed = false
        if FileManager.default.fileExists(atPath: directory.path) {
            trashed = (try? FileManager.default.trashItem(at: directory, resultingItemURL: nil)) != nil
        }
        if wasPersistent {
            browsers.setPersistentBrowser(true, for: mate.id)
        }
        if trashed {
            browserNotice = ("Signed out. The old profile is in the Trash.", .positive)
        } else if FileManager.default.fileExists(atPath: directory.path) {
            browserNotice = ("Couldn't move its profile to the Trash. Try again when its browser has closed.", .attention)
        } else {
            browserNotice = ("No saved sign-ins to remove.", .neutral)
        }
    }
}
