//
//  SettingsShortcutsPane.swift
//  HeyMate
//
//  Settings › Shortcuts: the hold-to-talk keys and the double-tap keys,
//  with a warning when two roles share a combo and a way back to the
//  shipped defaults.
//

import SwiftUI

struct SettingsShortcutsPane: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var navigation: SettingsNavigationModel

    // The double-tap accessors are plain statics, so the pickers bind to
    // State and write back on change.
    @State private var isTextDoubleTapEnabled = ModifierDoubleTapPreferences.isTextShortcutEnabled
    @State private var textDoubleTapShortcut = ModifierDoubleTapPreferences.textShortcut
    @State private var isHandsFreeDoubleTapEnabled = ModifierDoubleTapPreferences.isHandsFreeShortcutEnabled
    @State private var handsFreeDoubleTapShortcut = ModifierDoubleTapPreferences.handsFreeShortcut

    @State private var isConfirmingRestore = false

    var body: some View {
        SettingsPage(tab: .shortcuts, navigation: navigation) {
            holdToTalkSection
            doubleTapSection
            restoreSection
        }
        .onChange(of: isTextDoubleTapEnabled) { _, newValue in
            ModifierDoubleTapPreferences.isTextShortcutEnabled = newValue
        }
        .onChange(of: textDoubleTapShortcut) { _, newValue in
            ModifierDoubleTapPreferences.textShortcut = newValue
        }
        .onChange(of: isHandsFreeDoubleTapEnabled) { _, newValue in
            ModifierDoubleTapPreferences.isHandsFreeShortcutEnabled = newValue
        }
        .onChange(of: handsFreeDoubleTapShortcut) { _, newValue in
            ModifierDoubleTapPreferences.handsFreeShortcut = newValue
        }
    }

    // MARK: Hold to talk

    private var assignments: [SettingsShortcutRole: PushToTalkShortcut.Option] {
        [
            .talk: companionManager.talkShortcutOption,
            .chat: companionManager.chatShortcutOption,
            .dictate: companionManager.dictateShortcutOption,
            .region: companionManager.spatialSelectShortcutOption
        ]
    }

    private func binding(for role: SettingsShortcutRole) -> Binding<PushToTalkShortcut.Option> {
        switch role {
        case .talk: return $companionManager.talkShortcutOption
        case .chat: return $companionManager.chatShortcutOption
        case .dictate: return $companionManager.dictateShortcutOption
        case .region: return $companionManager.spatialSelectShortcutOption
        }
    }

    private func subtitle(for role: SettingsShortcutRole) -> String {
        switch role {
        case .talk: return "Hold and ask about anything on your screen."
        case .chat: return "Press to drop the notch chat, ready for typing."
        case .dictate: return "Hold to type what you say into the field you're in."
        case .region: return "Hold and circle part of the screen to ask about just that."
        }
    }

    private static let shortcutOptions: [DSMenuOption<PushToTalkShortcut.Option>] =
        PushToTalkShortcut.Option.allOptions.map {
            DSMenuOption(value: $0, title: $0.displayText)
        }

    private var holdToTalkSection: some View {
        let conflicts = SettingsShortcutRole.conflictingRoles(in: assignments)
        return SettingsSection(
            "Hold to talk",
            footer: "Work from anywhere on your Mac."
        ) {
            ForEach(Array(SettingsShortcutRole.allCases.enumerated()), id: \.element) { index, role in
                if index > 0 {
                    SettingsDivider()
                }
                VStack(alignment: .leading, spacing: 0) {
                    SettingsPickerRow(
                        role.item.title,
                        subtitle: subtitle(for: role),
                        item: role.item,
                        selection: binding(for: role),
                        options: Self.shortcutOptions
                    )
                    if conflicts.contains(role) {
                        SettingsInlineHelp(conflictMessage(for: role), tone: .attention)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .settingsRowContentInsets()
                    }
                }
            }
        }
    }

    private func conflictMessage(for role: SettingsShortcutRole) -> String {
        let option = assignments[role]
        let others = SettingsShortcutRole.allCases
            .filter { $0 != role && assignments[$0] == option }
            .map { $0.item.title }
        let list = ListFormatter.localizedString(byJoining: others)
        return "Also used by \(list). Whichever you press first wins — pick a different combo for one of them."
    }

    // MARK: Double tap

    private static let doubleTapOptions: [DSMenuOption<ModifierDoubleTapShortcut>] =
        ModifierDoubleTapShortcut.allCases.map { DSMenuOption(value: $0, title: $0.displayText) }

    private var doubleTapSection: some View {
        SettingsSection(
            "Double-tap",
            footer: "A quick press and release with no other key. Holding the keys works as before."
        ) {
            SettingsToggleRow(
                SettingsItem.doubleTapText.title,
                subtitle: "Double-tap to open the typed ask box from anywhere.",
                item: .doubleTapText,
                isOn: $isTextDoubleTapEnabled
            )
            if isTextDoubleTapEnabled {
                SettingsPickerRow(
                    "Keys",
                    selection: $textDoubleTapShortcut,
                    options: Self.doubleTapOptions
                )
                .padding(.leading, DS.SettingsLayout.rowHorizontalPadding)
            }

            SettingsDivider()

            SettingsToggleRow(
                SettingsItem.doubleTapHandsFree.title,
                subtitle: "Talk without holding a key; it ends when you stop speaking.",
                item: .doubleTapHandsFree,
                isOn: $isHandsFreeDoubleTapEnabled
            )
            if isHandsFreeDoubleTapEnabled {
                SettingsPickerRow(
                    "Keys",
                    selection: $handsFreeDoubleTapShortcut,
                    options: Self.doubleTapOptions
                )
                .padding(.leading, DS.SettingsLayout.rowHorizontalPadding)
            }
        }
    }

    // MARK: Restore

    private var isEverythingDefault: Bool {
        SettingsShortcutRole.allCases.allSatisfy { assignments[$0] == $0.defaultOption }
            && isTextDoubleTapEnabled == SettingsDoubleTapDefaults.isTextEnabled
            && textDoubleTapShortcut == SettingsDoubleTapDefaults.textShortcut
            && isHandsFreeDoubleTapEnabled == SettingsDoubleTapDefaults.isHandsFreeEnabled
            && handsFreeDoubleTapShortcut == SettingsDoubleTapDefaults.handsFreeShortcut
    }

    private var restoreSection: some View {
        SettingsSection {
            SettingsRow(
                SettingsItem.restoreShortcuts.title,
                subtitle: isEverythingDefault
                    ? "You're using the shipped shortcuts."
                    : "Back to the shipped keys, with double-taps off.",
                item: .restoreShortcuts
            ) {
                Button("Restore defaults…") { isConfirmingRestore = true }
                    .dsCapsuleButtonStyle(.secondary)
                    .disabled(isEverythingDefault)
            }
        }
        .confirmationDialog(
            "Restore the default shortcuts?",
            isPresented: $isConfirmingRestore,
            titleVisibility: .visible
        ) {
            Button("Restore defaults", action: restoreDefaults)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every hold-to-talk key goes back to the shipped combo, and both double-taps turn off.")
        }
    }

    private func restoreDefaults() {
        for role in SettingsShortcutRole.allCases {
            binding(for: role).wrappedValue = role.defaultOption
        }
        isTextDoubleTapEnabled = SettingsDoubleTapDefaults.isTextEnabled
        textDoubleTapShortcut = SettingsDoubleTapDefaults.textShortcut
        isHandsFreeDoubleTapEnabled = SettingsDoubleTapDefaults.isHandsFreeEnabled
        handsFreeDoubleTapShortcut = SettingsDoubleTapDefaults.handsFreeShortcut
    }
}
