//
//  SettingsPermissionsPane.swift
//  HeyMate
//
//  Settings › Permissions: every permission in one place, and a way out
//  when the keyboard shortcuts go quiet. That happens most after an update,
//  when macOS keeps the switch for the old build and refuses the new one.
//

import AppKit
import SwiftUI

struct SettingsPermissionsPane: View {
    @ObservedObject var navigation: SettingsNavigationModel
    @ObservedObject private var guide = PermissionGuide.shared
    @ObservedObject private var chrome = BrowserBridge.shared

    @State private var repairNote: String?
    @AppStorage(ApprovalMode.preferenceKey) private var approvalMode = ApprovalMode.askMe.rawValue
    @State private var showsResetConfirmation = false

    private var shortcutsWork: Bool {
        guide.isGranted(.accessibility) && guide.isGranted(.inputMonitoring)
    }

    var body: some View {
        SettingsPage(tab: .permissions, navigation: navigation) {
            if !shortcutsWork {
                shortcutsOffSection
            }
            approvalsSection
            chromeSection
            SettingsSection(
                "All permissions",
                footer: "Each one says what HeyMate can do with it. You can turn any of them off again in System Settings › Privacy & Security."
            ) {
                PermissionChecklist()
                    .settingsRowInsets()
                    .settingsAnchor(.permissionList)
            }
            repairSection
        }
        .onAppear { guide.startWatching() }
        .onDisappear { guide.stopWatching() }
        .confirmationDialog("Reset HeyMate's Input Monitoring permission?", isPresented: $showsResetConfirmation) {
            Button("Reset Input Monitoring", role: .destructive, action: repair)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Use this only if enabling the installed HeyMate app still fails. Reset removes its current Input Monitoring entry; you must allow it again in System Settings.")
        }
    }

    // MARK: Approvals

    private var approvalsSection: some View {
        SettingsSection(
            footer: "Sending, deleting, paying, passwords and keys like ⌘Q always ask, in either mode."
        ) {
            SettingsRow(
                SettingsItem.approvalMode.title,
                subtitle: approvalMode == ApprovalMode.fullAccess.rawValue
                    ? "Clicks, typing, app edits and job plans run without asking."
                    : "HeyMate asks before it clicks, types, edits an app, or starts a job.",
                item: .approvalMode
            ) {
                DSSegmentedControl(
                    accessibilityTitle: SettingsItem.approvalMode.title,
                    selection: $approvalMode,
                    segments: ApprovalMode.allCases.map { DSSegment(value: $0.rawValue, title: $0.title) },
                    width: DS.SettingsLayout.segmentedWidth
                )
            }
        }
    }

    // MARK: Chrome

    private var chromeSection: some View {
        SettingsSection(
            footer: chrome.isConnected
                ? "HeyMate works in a HeyMate tab group in your Chrome. It reads any tab, but clicks and types only in its own tabs, and never into password or card fields."
                : "One-time setup: Set up opens Chrome's extensions page and the HeyMate folder (its path is copied). Turn on Developer mode, choose Load unpacked, and pick that folder."
        ) {
            SettingsRow(
                SettingsItem.chrome.title,
                subtitle: chrome.isConnected
                    ? "Connected" + (chrome.extensionVersion.map { ", extension \($0)" } ?? "")
                    : "Not connected",
                item: .chrome
            ) {
                Button(chrome.isConnected ? "Show folder" : "Set up…") { chrome.openSetup() }
                    .dsCapsuleButtonStyle(chrome.isConnected ? .secondary : .primary)
                    .help(BrowserBridge.extensionFolderPath)
            }
        }
    }

    // MARK: Shortcuts off

    private var shortcutsOffSection: some View {
        SettingsSection {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "keyboard.badge.exclamationmark")
                        .font(DS.Glyph.regular)
                        .foregroundColor(DS.Colors.warningText)
                    Text("Keyboard shortcuts are off")
                        .font(DS.Fonts.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                }
                Text("⌃⌥ and the other shortcuts only work while HeyMate is in front. To hear them in every app, HeyMate needs \(missingShortcutPermissions).")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    step(1, "Press Open System Settings below.")
                    step(2, "Enable /Applications/HeyMate.app in the list.")
                    step(3, "Not listed? Use + to add that app, or drag it from the card below.")
                    step(4, "If macOS asks, quit and reopen HeyMate to apply the grant.")
                }
                HStack(spacing: DS.Spacing.sm) {
                    if let first = firstMissingShortcutPermission {
                        Button("Open System Settings") {
                            Task { await guide.request(first) }
                        }
                        .dsCapsuleButtonStyle(.primary)
                    }
                    if !guide.isGranted(.inputMonitoring) {
                        Button("Reset Input Monitoring…") { showsResetConfirmation = true }
                            .dsCapsuleButtonStyle(.secondary)
                            .help("Last resort: remove HeyMate's Input Monitoring entry and ask again.")
                    }
                }
                if let repairNote {
                    Text(repairNote)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NotchAppDropTile(
                    missingAccessibility: !guide.isGranted(.accessibility),
                    missingScreenRecording: false,
                    missingInputMonitoring: !guide.isGranted(.inputMonitoring)
                )
                .padding(.top, 4)
            }
            .settingsRowInsets()
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).")
                .font(DS.Fonts.caption.weight(.semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 14, alignment: .trailing)
            Text(text)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    private var firstMissingShortcutPermission: HeyMatePermission? {
        [HeyMatePermission.inputMonitoring, .accessibility].first { !guide.isGranted($0) }
    }

    private var missingShortcutPermissions: String {
        let missing = [HeyMatePermission.inputMonitoring, .accessibility]
            .filter { !guide.isGranted($0) }
            .map(\.title)
        return missing.joined(separator: " and ")
    }

    // MARK: Repair

    private var repairSection: some View {
        SettingsSection(
            "Still not working?",
            footer: "Changing HeyMate's signing identity can require new macOS approval. Ordinary local updates keep the installed signer. Reset is a last resort if enabling the installed app still fails."
        ) {
            SettingsRow(
                SettingsItem.repairShortcuts.title,
                subtitle: "Clears HeyMate's Input Monitoring entry and asks again.",
                systemImage: "wrench.and.screwdriver",
                item: .repairShortcuts
            ) {
                Button("Reset Input Monitoring…") { showsResetConfirmation = true }
                    .dsCapsuleButtonStyle(.secondary)
            }
        }
    }

    private func repair() {
        let didReset = MacPermissions.resetAndRequestInputMonitoring()
        PermissionGuide.markAsked(.inputMonitoring)
        repairNote = didReset
            ? "Done. Allow HeyMate in the prompt, or switch it on in System Settings."
            : "Couldn't clear the old entry. In System Settings, select HeyMate, press −, then add it again with +."
        Task { await guide.refresh() }
    }
}
