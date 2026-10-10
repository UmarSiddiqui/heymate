//
//  SettingsAgentsPane.swift
//  leanring-buddy
//
//  Settings › Agents & Control: the account that runs agent jobs and where
//  their folders live, whether HeyMate may operate this Mac, and the
//  honesty and safety rules it answers by.
//

import AppKit
import HeyMateComputerUse
import SwiftUI

struct SettingsAgentsPane: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var navigation: SettingsNavigationModel

    /// Observed directly so toggling computer control re-renders the
    /// permission warning under it without waiting for some other change on
    /// the manager.
    @ObservedObject private var computerUseCoordinator: ComputerUseCoordinator
    @ObservedObject private var cuaDriverSetup = CuaDriverSetup.shared

    @State private var showsBehaviorContractEditor = false

    init(companionManager: CompanionManager, navigation: SettingsNavigationModel) {
        self.companionManager = companionManager
        self.navigation = navigation
        self.computerUseCoordinator = companionManager.computerUseCoordinator
    }

    var body: some View {
        SettingsPage(tab: .agents, navigation: navigation) {
            SettingsSection(
                "Agent jobs",
                footer: "Signing in opens Terminal with the AI app's own sign-in. HeyMate never sees your password."
            ) {
                AgentSignInRows(companionManager: companionManager)
            }

            computerControlSection
            behaviorContractSection
        }
        .sheet(isPresented: $showsBehaviorContractEditor) {
            BehaviorContractEditorSheet()
        }
    }

    // MARK: Computer control

    private var computerControlSection: some View {
        SettingsSection(
            "Computer control",
            footer: "Anything that clicks, types, or sends asks for your approval first. No setting removes that step."
        ) {
            SettingsToggleRow(
                SettingsItem.computerControl.title,
                subtitle: "Press buttons by their on-screen name, type into the field you're in, and switch apps. Needs Accessibility permission.",
                item: .computerControl,
                isOn: Binding(
                    get: { computerUseCoordinator.isEnabled },
                    set: { computerUseCoordinator.isEnabled = $0 }
                )
            )

            if computerUseCoordinator.isEnabled,
               !AccessibilityElementFinder.isAccessibilityTrusted {
                SettingsNotice(
                    text: "Accessibility permission is off, so HeyMate can only read the screen.",
                    tone: .attention,
                    actionTitle: "Open System Settings",
                    action: openAccessibilitySettings
                )
                .settingsRowContentInsets()
            }

            if computerUseCoordinator.isEnabled {
                SettingsDivider()
                cuaDriverRow
            }

            SettingsDivider()

            VStack(alignment: .leading, spacing: DS.Spacing.xs + 2) {
                Text("Always true, whatever you choose")
                    .font(DS.Fonts.sectionLabel)
                    .foregroundColor(DS.Colors.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                ruleLine("Passwords, API keys, and tokens are refused outright — not asked about, refused.")
                ruleLine("Shortcuts that quit, close, or delete count as destructive and always ask.")
                ruleLine("Buttons are pressed by name when possible, so your pointer never moves.")
                ruleLine("When a real click can't be avoided, the companion cursor flies there first so you see it.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsRowInsets()
        }
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Cua's background driver, for approved jobs that operate apps.
    private var cuaDriverRow: some View {
        SettingsRow(
            SettingsItem.backgroundAppControl.title,
            subtitle: cuaDriverStatusText,
            systemImage: "macwindow.on.rectangle",
            item: .backgroundAppControl
        ) {
            if cuaDriverSetup.phase == .installing {
                SettingsStatusBadge(text: "Installing…", tone: .progress)
            } else if let action = cuaDriverActionTitle {
                Button(action) {
                    Task { await cuaDriverSetup.install() }
                }
                .dsCapsuleButtonStyle(.secondary)
            } else {
                SettingsStatusBadge(text: "Ready", tone: .positive)
            }
        }
        .task { await cuaDriverSetup.refresh() }
    }

    private var cuaDriverStatusText: String {
        if case .failed(let message) = cuaDriverSetup.phase { return message }
        if cuaDriverSetup.phase == .installing { return "Installing Cua's driver. macOS will ask for permissions for CuaDriver." }
        switch cuaDriverSetup.installation {
        case .missing:
            return "Lets approved jobs operate other apps in the background without taking your cursor. Uses Cua's open-source driver."
        case .outdated(_, let version):
            return "Cua driver \(version) is too old for HeyMate. Update to keep background app control."
        case .ready(_, let version):
            return "Cua driver \(version). Approved jobs can operate apps in the background."
        }
    }

    private var cuaDriverActionTitle: String? {
        switch cuaDriverSetup.installation {
        case .missing: return "Install"
        case .outdated: return "Update"
        case .ready: return nil
        }
    }

    private func ruleLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark")
                .font(DS.Glyph.micro)
                .foregroundColor(DS.Colors.success)
                .accessibilityHidden(true)
            Text(text)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Honesty and safety rules

    private var behaviorContractSection: some View {
        SettingsSection(
            footer: "Kept as a plain text file you can edit. Reset puts back the rules HeyMate shipped with."
        ) {
            SettingsRow(
                SettingsItem.behaviorContract.title,
                subtitle: "The rules HeyMate follows in every reply.",
                systemImage: "checkmark.shield",
                item: .behaviorContract
            ) {
                HStack(spacing: DS.Spacing.sm) {
                    Button("Show in Finder") { companionManager.revealBehaviorContractFile() }
                        .dsCapsuleButtonStyle(.quiet)
                    Button("Edit…") { showsBehaviorContractEditor = true }
                        .dsCapsuleButtonStyle(.secondary)
                }
            }
        }
    }
}

/// Edits `behavior-contract.md`. Save writes the draft. Reset rewrites the
/// file from the shipped rules and does not change those rules.
private struct BehaviorContractEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var savedText: String
    @State private var showsResetConfirmation = false
    @State private var saveError: String?

    init() {
        let existing = (try? String(contentsOf: BehaviorContract.fileURL(), encoding: .utf8))
            ?? BehaviorContract.resetContractText()
        _draft = State(initialValue: existing)
        _savedText = State(initialValue: existing)
    }

    private var hasChanges: Bool { draft != savedText }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md + 2) {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(SettingsItem.behaviorContract.title)
                    .font(DS.Fonts.title)
                    .foregroundColor(DS.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Bound to every reply HeyMate gives.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
            }

            TextEditor(text: $draft)
                .font(DS.Fonts.editor)
                .foregroundColor(DS.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
                .accessibilityLabel("Behavior contract text")

            HStack(spacing: DS.Spacing.sm) {
                Button("Reset to shipped rules…") { showsResetConfirmation = true }
                    .dsCapsuleButtonStyle(.destructive)
                Spacer(minLength: DS.Spacing.sm)
                Button("Cancel") { dismiss() }
                    .dsCapsuleButtonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { saveDraft() }
                    .dsCapsuleButtonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges)
            }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 640, height: 520)
        .background(DS.Colors.surface1)
        .presentationBackground(DS.Colors.surface1)
        .confirmationDialog(
            "Reset to the shipped honesty and safety rules?",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { resetToShippedText() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your edits to this file are replaced with the rules HeyMate shipped with.")
        }
        .alert("Couldn't update the rules", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "Unknown error")
        }
    }

    private func saveDraft() {
        do {
            try BehaviorContract.writeContractText(draft, to: BehaviorContract.fileURL())
            savedText = draft
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func resetToShippedText() {
        let shipped = BehaviorContract.resetContractText()
        do {
            try BehaviorContract.writeContractText(shipped, to: BehaviorContract.fileURL())
            draft = shipped
            savedText = shipped
        } catch {
            saveError = error.localizedDescription
        }
    }
}
