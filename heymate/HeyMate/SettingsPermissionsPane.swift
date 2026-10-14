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

    @State private var repairNote: String?

    private var shortcutsWork: Bool {
        guide.isGranted(.accessibility) && guide.isGranted(.inputMonitoring)
    }

    var body: some View {
        SettingsPage(tab: .permissions, navigation: navigation) {
            if !shortcutsWork {
                shortcutsOffSection
            }
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
                    step(2, "Find HeyMate in the list and switch it on.")
                    step(3, "Already on? Switch it off and on again, or press Repair.")
                    step(4, "HeyMate isn't listed? Drag it in from the card below.")
                }
                HStack(spacing: DS.Spacing.sm) {
                    if let first = firstMissingShortcutPermission {
                        Button("Open System Settings") {
                            Task { await guide.request(first) }
                        }
                        .dsCapsuleButtonStyle(.primary)
                    }
                    if !guide.isGranted(.inputMonitoring) {
                        Button("Repair", action: repair)
                            .dsCapsuleButtonStyle(.secondary)
                            .help("Clears HeyMate's old Input Monitoring entry and asks again.")
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
            footer: "macOS ties these switches to the exact copy of HeyMate. After an update the old switch can stay on while the new copy is refused."
        ) {
            SettingsRow(
                SettingsItem.repairShortcuts.title,
                subtitle: "Clears HeyMate's Input Monitoring entry and asks again.",
                systemImage: "wrench.and.screwdriver",
                item: .repairShortcuts
            ) {
                Button("Repair", action: repair)
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
