//
//  SettingsGeneralPane.swift
//  leanring-buddy
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
        SettingsSection(
            "Appearance",
            footer: "The accent tints the cursor companion and the main action buttons. The notch stays black, and Settings follows your Mac's light or dark appearance."
        ) {
            SettingsRow(
                SettingsItem.accentColor.title,
                subtitle: currentSwatchName,
                item: .accentColor
            ) {
                SettingsAccentSwatches(companionManager: companionManager)
            }
        }
    }

    private var currentSwatchName: String {
        AppTheme.swatches.first {
            $0.hex.caseInsensitiveCompare(companionManager.themeColorHex) == .orderedSame
        }?.name ?? "Signal"
    }

    // MARK: Startup & presence

    private var presenceSection: some View {
        SettingsSection(
            "Startup & presence",
            footer: "HeyMate normally has no Dock icon — the notch is its home."
        ) {
            SettingsToggleRow(
                SettingsItem.launchAtLogin.title,
                subtitle: "Start HeyMate when you log in to your Mac.",
                item: .launchAtLogin,
                isOn: $presencePreferences.launchesAtLogin
            )
            SettingsDivider()
            SettingsToggleRow(
                SettingsItem.showInDock.title,
                subtitle: "Keep a Dock icon and a menu bar for the whole session, not only while this window is open.",
                item: .showInDock,
                isOn: $presencePreferences.showsInDock
            )
            SettingsDivider()
            SettingsRow(
                SettingsItem.noNotchPlacement.title,
                subtitle: "On a Mac or display with no notch, draw a stand-in notch at the top of the screen, or live in the menu bar.",
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
                subtitle: "Keep HeyMate beside your pointer. When off, it comes out only while you use it, then returns to the notch.",
                item: .cursorCompanion,
                isOn: Binding(
                    get: { companionManager.isClickyCursorEnabled },
                    set: { companionManager.setClickyCursorEnabled($0) }
                )
            )
        }
    }

    // MARK: Updates

    private var updatesSection: some View {
        SettingsSection("Updates", footer: "Version \(updateController.displayedVersion).") {
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
            if updateController.isReady {
                SettingsToggleRow(
                    "Check automatically",
                    subtitle: "Look for a new version in the background and offer it when it's ready.",
                    isOn: $updateController.automaticallyChecksForUpdates
                )
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
                subtitle: "Watch the introduction again.",
                systemImage: "play.circle",
                item: .replayIntroduction
            ) {
                Button("Replay") { companionManager.replayOnboarding() }
                    .dsCapsuleButtonStyle(.secondary)
            }

            ForEach(SupportLinks.destinations) { destination in
                SettingsDivider()
                SettingsRow(
                    destination.title,
                    subtitle: destination.subtitle,
                    systemImage: destination.symbolName,
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
