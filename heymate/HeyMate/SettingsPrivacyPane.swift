//
//  SettingsPrivacyPane.swift
//  HeyMate
//
//  Settings › Privacy & Data: what HeyMate never looks at, whether it shows
//  up in recordings, what it keeps, what leaves this Mac, and erasing it
//  all. Erase sits last, on its own, behind a confirmation.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsPrivacyPane: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var navigation: SettingsNavigationModel
    @ObservedObject private var presencePreferences = AppPresencePreferences.shared

    @State private var newBundleIdentifier = ""
    @State private var bundleIdentifierError: String?
    @State private var persistErrorMessage: String?
    @State private var localDataEraseNote: String?
    @State private var showsDataFlowDetails = false

    var body: some View {
        SettingsPage(tab: .privacy, navigation: navigation) {
            screenCaptureSection
            chatsAndMemorySection
            whatLeavesSection
            dangerZoneSection
        }
        .onAppear(perform: refreshPersistedError)
        .onReceive(NotificationCenter.default.publisher(for: LocalDataErase.persistFailedNotification)) { _ in
            refreshPersistedError()
        }
    }

    // MARK: Screen capture

    private var screenCaptureSection: some View {
        SettingsSection(
            "Screen capture",
            footer: "Listed apps are never captured, for any feature. Password managers and System Settings are always on the list."
        ) {
            SettingsRow(
                SettingsItem.excludedApps.title,
                subtitle: "\(companionManager.excludedAppBundleIds.count) apps",
                systemImage: "eye.slash",
                item: .excludedApps
            ) {
                Button("Choose app…", action: chooseAppToExclude)
                    .dsCapsuleButtonStyle(.secondary)
            }

            ForEach(companionManager.excludedAppBundleIds, id: \.self) { bundleIdentifier in
                excludedAppRow(bundleIdentifier)
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xs + 2) {
                HStack(spacing: DS.Spacing.sm) {
                    TextField("Or type a bundle ID, like com.example.app", text: $newBundleIdentifier)
                        .settingsFieldChrome(isMonospaced: true)
                        .onSubmit(addTypedExclusion)
                        .onChange(of: newBundleIdentifier) { _, _ in bundleIdentifierError = nil }
                        .accessibilityLabel("Bundle ID to never capture")
                    Button("Add", action: addTypedExclusion)
                        .dsCapsuleButtonStyle(.secondary)
                        .disabled(newBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let bundleIdentifierError {
                    SettingsInlineHelp(bundleIdentifierError, tone: .attention)
                }
            }
            .padding(.top, DS.Spacing.sm)
            .settingsRowContentInsets()

            SettingsDivider()

            SettingsToggleRow(
                SettingsItem.screenRecordings.title,
                subtitle: "Off hides HeyMate from screenshots, recordings, and shared screens.",
                item: .screenRecordings,
                isOn: $presencePreferences.appearsInScreenRecordings
            )
        }
    }

    private func excludedAppRow(_ bundleIdentifier: String) -> some View {
        let isBuiltIn = ExcludedApps.defaultExcludedBundleIds.contains(bundleIdentifier)
        return HStack(spacing: DS.Spacing.md) {
            Text(bundleIdentifier)
                .font(DS.Fonts.mono)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isBuiltIn {
                SettingsStatusBadge(text: "Built in", tone: .neutral)
            } else {
                Button("Remove") {
                    companionManager.removeUserAppExclusion(bundleIdentifier)
                }
                .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                .accessibilityLabel("Stop excluding \(bundleIdentifier)")
            }
        }
        .padding(.leading, DS.SettingsLayout.rowHorizontalPadding + DS.SettingsLayout.rowIconWidth + DS.Spacing.md)
        .padding(.trailing, DS.SettingsLayout.rowHorizontalPadding)
        .frame(minHeight: DS.ControlSize.large)
    }

    /// A bundle id is reverse-DNS: at least two dot-separated parts, no
    /// spaces. Anything else would never match a running app.
    static func isPlausibleBundleIdentifier(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, !text.contains(where: { $0.isWhitespace }) else { return false }
        return parts.allSatisfy { !$0.isEmpty }
    }

    private func addTypedExclusion() {
        let trimmed = newBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard Self.isPlausibleBundleIdentifier(trimmed) else {
            bundleIdentifierError = "That doesn't look like a bundle ID. They read like com.company.app — or use Choose app… instead."
            return
        }
        addExclusion(trimmed)
        newBundleIdentifier = ""
    }

    private func addExclusion(_ bundleIdentifier: String) {
        guard !companionManager.excludedAppBundleIds.contains(bundleIdentifier) else {
            bundleIdentifierError = "\(bundleIdentifier) is already on the list."
            return
        }
        bundleIdentifierError = nil
        companionManager.addUserAppExclusion(bundleIdentifier)
    }

    private func chooseAppToExclude() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Never Capture"
        panel.message = "Choose an app HeyMate should never capture."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else {
                bundleIdentifierError = "HeyMate couldn't read that app's bundle ID."
                return
            }
            addExclusion(bundleIdentifier)
        }
    }

    // MARK: Chats and memory

    private var chatsAndMemorySection: some View {
        SettingsSection(
            "Chats & memory",
            footer: "Text only, on this Mac. Screenshots are never kept."
        ) {
            SettingsToggleRow(
                SettingsItem.saveChats.title,
                subtitle: "Off stops new saves; stored chats stay until you delete them.",
                item: .saveChats,
                isOn: $companionManager.rememberConversationsEnabled
            )
            SettingsDivider()
            SettingsRow(
                SettingsItem.memories.title,
                subtitle: memoriesSubtitle,
                systemImage: "brain",
                item: .memories
            ) {
                Button("Manage…") {
                    companionManager.openDesktopWindow(section: .memory)
                }
                .dsCapsuleButtonStyle(.secondary)
            }
            SettingsDivider()
            SettingsDestructiveRow(
                title: "Delete saved chats",
                subtitle: "Removes every chat stored on this Mac. Memories stay.",
                buttonTitle: "Delete chats…",
                confirmationTitle: "Delete saved chats?",
                confirmationMessage: "Chats stored on this Mac are removed. This can't be undone. Memories stay.",
                confirmButtonTitle: "Delete chats",
                action: { companionManager.clearAllChats() }
            )
        }
    }

    private var memoriesSubtitle: String {
        switch companionManager.memoryItems.count {
        case 0: return "Nothing remembered yet."
        case 1: return "1 thing HeyMate remembers between conversations."
        default: return "\(companionManager.memoryItems.count) things HeyMate remembers between conversations."
        }
    }

    // MARK: What leaves this Mac

    private var whatLeavesSection: some View {
        SettingsSection {
            SettingsDisclosureRow(
                SettingsItem.whatLeavesThisMac.title,
                subtitle: "Only the screenshot and words for a turn, and only to the AI you chose.",
                isExpanded: $showsDataFlowDetails
            ) {
            SettingsDivider()
            privacyFact("Screenshots", "Sent for the turn that needs them, never stored.", systemImage: "camera.viewfinder")
            SettingsDivider()
            privacyFact("Transcripts", "On this Mac by default. Cloud speech is opt-in.", systemImage: "text.quote")
            SettingsDivider()
            privacyFact("Memory", "A local file. Text only, by construction.", systemImage: "brain")
            SettingsDivider()
            privacyFact("Clipboard history", "In memory only, cleared when HeyMate quits.", systemImage: "doc.on.clipboard")
            SettingsDivider()
            privacyFact("Keys", "A private file on this Mac, readable only by your account.", systemImage: "key")
            }
        }
        .settingsAnchor(.whatLeavesThisMac)
    }

    private func privacyFact(_ title: String, _ detail: String, systemImage _: String) -> some View {
        SettingsRow(title, subtitle: detail)
    }

    // MARK: Danger zone

    private var dangerZoneSection: some View {
        SettingsSection(
            "Danger zone",
            footer: "Project folders under ~/Projects are not deleted."
        ) {
            if let persistErrorMessage {
                SettingsNotice(
                    text: persistErrorMessage,
                    tone: .critical,
                    actionTitle: "Dismiss",
                    action: dismissPersistedError
                )
                .padding(DS.Spacing.md)
            }

            if let localDataEraseNote {
                SettingsNotice(text: localDataEraseNote, tone: .attention)
                    .padding(DS.Spacing.md)
            }

            SettingsDestructiveRow(
                title: SettingsItem.eraseData.title,
                subtitle: "Removes everything HeyMate keeps here. You'll see the full list first.",
                item: .eraseData,
                buttonTitle: "Erase…",
                confirmationTitle: "Erase HeyMate data?",
                confirmationMessage: LocalDataErase.confirmationMessage,
                confirmButtonTitle: "Erase HeyMate data",
                action: {
                    localDataEraseNote = LocalDataErase.erase(companionManager: companionManager)
                }
            )
        }
    }

    private func refreshPersistedError() {
        let stored = UserDefaults.standard.string(forKey: LocalDataErase.persistErrorDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        persistErrorMessage = (stored?.isEmpty == false) ? stored : nil
    }

    private func dismissPersistedError() {
        UserDefaults.standard.removeObject(forKey: LocalDataErase.persistErrorDefaultsKey)
        persistErrorMessage = nil
    }
}
