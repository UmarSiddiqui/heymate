//
//  SettingsGeneralPane.swift
//  HeyMate
//
//  Settings › General: how HeyMate looks, how it starts and shows up on the
//  Mac, updates, and help. Talking, shortcuts, and voices have their own
//  sections now.
//

import SwiftUI

struct SettingsGeneralPane: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var navigation: SettingsNavigationModel

    @ObservedObject private var presencePreferences = AppPresencePreferences.shared
    @ObservedObject private var updateController = AppUpdateController.shared

    @AppStorage(QuietPolicy.presentationModeKey) private var presentationMode = false
    @AppStorage(CompanionAppearancePreference.idleAnimationsKey) private var idleAnimations = true
    @AppStorage(CompanionAppearancePreference.floatingAgentsKey) private var floatingAgents = true

    var body: some View {
        SettingsPage(tab: .general, navigation: navigation) {
            appearanceSection
            presenceSection
            updatesSection
            helpSection
        }
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        SettingsSection("Appearance") {
            SettingsRow(
                SettingsItem.accentColor.title,
                subtitle: currentSwatchName,
                item: .accentColor
            ) {
                SettingsAccentSwatches(companionManager: companionManager)
            }
            SettingsDivider()
            SettingsToggleRow("Idle character animation", isOn: $idleAnimations)
            SettingsDivider()
            SettingsToggleRow("Floating agent cards", isOn: $floatingAgents)
        }
    }

    private var currentSwatchName: String {
        AppTheme.swatches.first {
            $0.hex.caseInsensitiveCompare(companionManager.themeColorHex) == .orderedSame
        }?.name ?? "Signal"
    }

    // MARK: Startup & presence

    private var presenceSection: some View {
        SettingsSection("Startup & presence") {
            SettingsToggleRow(
                SettingsItem.launchAtLogin.title,
                item: .launchAtLogin,
                isOn: $presencePreferences.launchesAtLogin
            )
            SettingsDivider()
            SettingsToggleRow(
                SettingsItem.showInDock.title,
                item: .showInDock,
                isOn: $presencePreferences.showsInDock
            )
            SettingsDivider()
            SettingsToggleRow("Presentation mode", subtitle: "Hides task notices and pauses announcements. Approvals wait in chat.", isOn: $presentationMode)
            SettingsDivider()
            SettingsRow(
                SettingsItem.noNotchPlacement.title,
                item: .noNotchPlacement
            ) {
                DSSegmentedControl(
                    accessibilityTitle: SettingsItem.noNotchPlacement.title,
                    selection: $presencePreferences.noNotchPlacement,
                    segments: NoNotchPlacement.allCases.map { DSSegment(value: $0, title: $0.title) }
                )
            }
            SettingsDivider()
            SettingsToggleRow(
                SettingsItem.cursorCompanion.title,
                item: .cursorCompanion,
                isOn: Binding(
                    get: { companionManager.isCursorCompanionEnabled },
                    set: { companionManager.setCursorCompanionEnabled($0) }
                )
            )
        }
    }

    // MARK: Updates

    private var updatesSection: some View {
        SettingsSection("Updates", footer: "Version \(updateController.displayedVersion).") {
            AppUpdateReminderView()
            SettingsRow(
                SettingsItem.softwareUpdates.title,
                subtitle: lastUpdateCheckDescription,
                item: .softwareUpdates
            ) {
                Button("Check now") { updateController.checkForUpdates() }
                    .dsCapsuleButtonStyle(.secondary)
                    .disabled(!updateController.canCheckForUpdates)
            }
            SettingsDivider()
            SettingsRow("What's new") {
                Button {
                    if let url = URL(string: SupportLinks.changelogURLString) { NSWorkspace.shared.open(url) }
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(DS.Glyph.small)
                }
                .dsToolbarIconButtonStyle(size: DS.ControlSize.small)
                .help("Open the changelog")
                .accessibilityLabel("Open the changelog")
            }
            SettingsDivider()
            if updateController.isReady {
                SettingsToggleRow(
                    "Check automatically",
                    isOn: $updateController.automaticallyChecksForUpdates
                )
                SettingsDivider()
                SettingsToggleRow(
                    "Automatically download and install updates",
                    subtitle: updateController.automaticallyChecksForUpdates
                        ? "Installs when HeyMate quits."
                        : "Turn on Check automatically to download and install updates.",
                    isOn: $updateController.automaticallyDownloadsUpdates
                )
                .disabled(!updateController.allowsAutomaticUpdates)
            } else {
                SettingsInlineHelp(updateAvailabilityDescription, tone: updateAvailabilityTone)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsRowInsets()
            }
        }
    }

    private var lastUpdateCheckDescription: String {
        switch updateController.availability {
        case .sourceBuild:
            return "Updates are off in this source build."
        case .notStarted, .starting:
            return "The update service is starting."
        case .failed:
            return "The update service didn't start."
        case .ready:
            break
        }
        guard let lastUpdateCheckDate = updateController.lastUpdateCheckDate else {
            return "Not checked yet."
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: lastUpdateCheckDate, relativeTo: Date()))."
    }

    private var updateAvailabilityDescription: String {
        switch updateController.availability {
        case .sourceBuild:
            return "Automatic updates turn on in signed release builds."
        case .notStarted, .starting:
            return "Automatic updates are starting."
        case .failed:
            return "Automatic updates are unavailable because the update service couldn't start. Restart HeyMate, or download the next release yourself."
        case .ready:
            return "Automatic updates are ready."
        }
    }

    private var updateAvailabilityTone: SettingsStatusTone {
        switch updateController.availability {
        case .failed: return .attention
        case .notStarted, .starting: return .progress
        case .sourceBuild, .ready: return .neutral
        }
    }

    // MARK: Help

    private var helpSection: some View {
        SettingsSection("Help") {
            SettingsRow(
                SettingsItem.replayIntroduction.title,
                item: .replayIntroduction
            ) {
                Button("Replay") { companionManager.replayOnboarding() }
                    .dsCapsuleButtonStyle(.secondary)
            }

            SettingsDivider()
            SettingsRow("Support diagnostics", subtitle: "Redacted, saved locally. Nothing uploads.") {
                SupportDiagnosticsExport(manager: companionManager)
                    .dsCapsuleButtonStyle(.quiet)
            }

            ForEach(SupportLinks.destinations) { destination in
                SettingsDivider()
                SettingsRow(
                    destination.title,
                    subtitle: destination.subtitle,
                    item: destination.id == SupportLinks.destinations.first?.id ? .helpAndFeedback : nil
                ) {
                    Button("Open") { SupportLinks.open(destination) }
                        .dsCapsuleButtonStyle(.quiet)
                        .accessibilityLabel("Open \(destination.title)")
                }
            }
        }
    }
}

/// The accent swatches. Onboarding's `ThemeColorPicker` uses the same row,
/// so there is one picker in the app.
struct SettingsAccentSwatches: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            ForEach(AppTheme.swatches) { swatch in
                let isSelected = companionManager.themeColorHex
                    .caseInsensitiveCompare(swatch.hex) == .orderedSame
                Button {
                    companionManager.setThemeColorHex(swatch.hex)
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .frame(width: DS.SettingsLayout.swatchSide, height: DS.SettingsLayout.swatchSide)
                        .padding(3)
                        .overlay(
                            Circle()
                                .stroke(isSelected ? DS.Colors.textPrimary : Color.clear, lineWidth: 2)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help(swatch.name)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(SettingsItem.accentColor.title)
    }
}


/// Shared by the notch and Settings so updates remain discoverable without
/// opening a separate window or requesting notification permission.
struct AppUpdateReminderView: View {
    @ObservedObject private var controller = AppUpdateController.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let reminder = controller.reminder,
               controller.reminderSnooze?.hides(reminder, at: context.date) != true {
                VStack(alignment: .leading, spacing: 8) {
                    Label(reminder.title, systemImage: "arrow.down.circle")
                        .font(DS.Fonts.caption.weight(.semibold))
                    Text(reminder.isReadyToInstall
                         ? "Restart to finish updating. HeyMate will briefly close."
                         : "Get the latest improvements and fixes.")
                        .font(DS.Fonts.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button(reminder.isReadyToInstall ? "Review and restart" : "Update now") {
                            controller.checkForUpdates()
                        }
                        .dsCapsuleButtonStyle(.secondary)
                        .disabled(!controller.canCheckForUpdates)
                        Button("Remind tomorrow") { controller.remindLater() }
                            .dsCapsuleButtonStyle(.quiet)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
            }
        }
    }
}
