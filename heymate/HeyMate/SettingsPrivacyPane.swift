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

    @ObservedObject private var analytics = HeyMateAnalytics.shared
    @ObservedObject private var crashDiagnostics = HeyMateAnalytics.crashes
    @State private var diagnosticsPreview: String?
    @State private var diagnosticsError: String?

    @State private var newBundleIdentifier = ""
    @State private var bundleIdentifierError: String?
    @State private var persistErrorMessage: String?
    @State private var localDataEraseNote: String?
    @State private var showsDataFlowDetails = false

    var body: some View {
        SettingsPage(tab: .privacy, navigation: navigation) {
            SettingsSection("HeyMate account") {
                AccountPreferencesView(account: HeyMateAccount.shared)
            }
            screenCaptureSection
            chatsAndMemorySection
            analyticsSection
            whatLeavesSection
            dangerZoneSection
        }
        .onAppear(perform: refreshPersistedError)
        .sheet(isPresented: Binding(get: { diagnosticsPreview != nil }, set: { if !$0 { diagnosticsPreview = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Diagnostics preview").font(.headline)
                Text("Local only. Shows the most recent sanitized event, or a labeled example. Previewing never sends data.")
                ScrollView {
                    Text(diagnosticsPreview ?? "").font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let diagnosticsError { Text(diagnosticsError).foregroundStyle(.red) }
                HStack {
                    Button("Export JSON…", action: exportDiagnosticsPreview)
                    Spacer()
                    Button("Done") { diagnosticsPreview = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 680, height: 500)
        }
        .onReceive(NotificationCenter.default.publisher(for: LocalDataErase.persistFailedNotification)) { _ in
            refreshPersistedError()
        }
    }

    // MARK: Screen capture

    private var screenCaptureSection: some View {
        SettingsSection(
            "Screen capture",
            footer: "Password managers and System Settings are always excluded."
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

    private var analyticsSection: some View {
        SettingsSection("Help improve HeyMate", footer: "Both choices are off by default and independent. Turning either off cancels its pending sends, clears its queue and deletes its local ID. Delivered data cannot be recalled here. Configured destinations retain diagnostics for up to 30 days. Preview and export stay on this Mac.") {
            SettingsToggleRow(
                SettingsItem.usageAnalytics.title,
                subtitle: analytics.isAvailable ? UsageAnalytics.disclosure : "Unavailable in this build. Nothing is sent. " + UsageAnalytics.disclosure,
                item: .usageAnalytics,
                isOn: Binding(get: { analytics.isOptedIn }, set: { analytics.setOptedIn($0) })
            )
            .disabled(!analytics.isAvailable && !analytics.isOptedIn)
            SettingsDivider()
            SettingsToggleRow(
                SettingsItem.crashReports.title,
                subtitle: crashDiagnostics.isAvailable ? UsageAnalytics.crashDisclosure : "Unavailable in this build. Nothing is sent. " + UsageAnalytics.crashDisclosure,
                item: .crashReports,
                isOn: Binding(get: { crashDiagnostics.isOptedIn }, set: { crashDiagnostics.setOptedIn($0) })
            )
            .disabled(!crashDiagnostics.isAvailable && !crashDiagnostics.isOptedIn)
            SettingsDivider()
            SettingsRow("What diagnostics contain", subtitle: "Inspect or export sanitized JSON locally, including when sending is disabled.") {
                Button("Product preview") { showDiagnosticsPreview(analytics) }
                Button("Crash preview") { showDiagnosticsPreview(crashDiagnostics) }
            }
        }
    }

    private func showDiagnosticsPreview(_ diagnostics: UsageAnalytics) {
        diagnosticsError = nil
        do { diagnosticsPreview = String(decoding: try diagnostics.previewData(), as: UTF8.self) }
        catch { diagnosticsPreview = ""; diagnosticsError = "Couldn't create the diagnostics preview." }
    }

    private func exportDiagnosticsPreview() {
        guard let diagnosticsPreview else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "heymate-diagnostics.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try Data(diagnosticsPreview.utf8).write(to: url, options: .atomic) }
            catch { diagnosticsError = "Couldn't export the diagnostics preview." }
        }
    }

    // MARK: What leaves this Mac

    private var whatLeavesSection: some View {
        SettingsSection {
            SettingsDisclosureRow(
                SettingsItem.whatLeavesThisMac.title,
                subtitle: "AI requests go to your chosen provider. Product diagnostics and crash summaries each need separate consent and a configured destination.",
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
