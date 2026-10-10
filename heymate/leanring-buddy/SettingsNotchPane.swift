//
//  SettingsNotchPane.swift
//  leanring-buddy
//
//  Settings › Notch: which micro-apps share the notch, how the notch opens,
//  and what the turned-on micro-apps are holding right now (shelf files,
//  clipboard history, a running timer, the next event).
//

import AppKit
import SwiftUI

struct SettingsNotchPane: View {
    @ObservedObject var activityCenter: NotchActivityCenter
    @ObservedObject var navigation: SettingsNavigationModel
    @ObservedObject private var shelfStore: NotchShelfStore
    @ObservedObject private var clipboardStore: ClipboardHistoryStore

    /// Bound through AppStorage rather than the controller's static so the
    /// switch re-renders when flipped. Same key, same default (on).
    @AppStorage(NotchCompanionController.hoverOpensCardPreferenceKey) private var hoverOpensCard = true

    @State private var timerDurationText = "25m"

    init(activityCenter: NotchActivityCenter, navigation: SettingsNavigationModel) {
        self.activityCenter = activityCenter
        self.navigation = navigation
        self.shelfStore = activityCenter.shelfStore
        self.clipboardStore = activityCenter.clipboardStore
    }

    private var hasLiveContent: Bool {
        activityCenter.isEnabled(.shelf)
            || activityCenter.isEnabled(.timer)
            || activityCenter.isEnabled(.clipboard)
            || activityCenter.isEnabled(.calendar)
    }

    var body: some View {
        SettingsPage(tab: .notch, navigation: navigation) {
            microAppsSection
            behaviorSection
            if hasLiveContent {
                liveContent
                    .settingsAnchor(.notchContent)
            }
        }
    }

    // MARK: Micro-apps

    private var microAppsSection: some View {
        SettingsSection(
            SettingsItem.microApps.title,
            footer: "The collapsed notch shows one micro-app at a time, starting with your latest activity."
        ) {
            ForEach(Array(NotchMicroApp.allCases.enumerated()), id: \.element) { index, microApp in
                if index > 0 {
                    SettingsDivider()
                }
                microAppRow(microApp)
            }
        }
        .settingsAnchor(.microApps)
    }

    private func microAppRow(_ microApp: NotchMicroApp) -> some View {
        let isEnabled = Binding(
            get: { activityCenter.isEnabled(microApp) },
            set: { activityCenter.setEnabled($0, for: microApp) }
        )
        let needsPermission = activityCenter.needsPermissionPrompt(for: microApp)

        return SettingsRow(
            microApp.displayName,
            subtitle: microApp.explanation,
            systemImage: microApp.symbolName
        ) {
            HStack(spacing: DS.Spacing.md) {
                if let permission = microApp.requiredPermissionDescription {
                    SettingsStatusBadge(
                        text: needsPermission ? "Needs permission" : "Allowed",
                        tone: needsPermission ? .attention : .positive
                    )
                    .help(permission)
                }
                DSSwitch(isOn: isEnabled)
                    .accessibilityLabel(microApp.displayName)
                    .accessibilityHint(microApp.explanation)
            }
        }
    }

    // MARK: Behavior

    private var behaviorSection: some View {
        SettingsSection(
            "Behavior",
            footer: "Opening the card with a click always works, whatever this is set to."
        ) {
            SettingsToggleRow(
                SettingsItem.hoverOpensCard.title,
                subtitle: "Rest the pointer on the notch for a moment to drop the full card. Off: hovering only highlights the notch.",
                item: .hoverOpensCard,
                isOn: $hoverOpensCard
            )
        }
    }

    // MARK: In the notch now

    /// One stack, so the search anchor lands on the group rather than on
    /// each section inside it.
    private var liveContent: some View {
        VStack(alignment: .leading, spacing: DS.SettingsLayout.sectionSpacing) {
            if activityCenter.isEnabled(.shelf) {
                shelfSection
            }
            if activityCenter.isEnabled(.timer) {
                timerSection
            }
            if activityCenter.isEnabled(.clipboard) {
                clipboardSection
            }
            if activityCenter.isEnabled(.calendar) {
                calendarSection
            }
        }
    }

    private var shelfSection: some View {
        SettingsSection(
            "File shelf",
            footer: "HeyMate keeps a bookmark, never a copy. Items clear themselves after a day."
        ) {
            if shelfStore.items.isEmpty {
                SettingsEmptyRow(text: "Drag files onto the notch to park them here.", systemImage: "tray")
            } else {
                ForEach(shelfStore.items) { item in
                    HStack(spacing: DS.Spacing.md) {
                        Group {
                            if let thumbnail = item.thumbnail {
                                Image(nsImage: thumbnail)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small / 2, style: .continuous))
                            } else {
                                Image(systemName: "doc")
                                    .font(DS.Glyph.regular)
                                    .foregroundColor(DS.Colors.textTertiary)
                            }
                        }
                        .frame(width: DS.ControlSize.regular - 2, height: DS.ControlSize.regular - 2)
                        .accessibilityHidden(true)

                        Text(item.displayName)
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button("Reveal") { shelfStore.reveal(itemID: item.id) }
                            .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                        Button("Remove") { shelfStore.remove(itemID: item.id) }
                            .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                            .accessibilityLabel("Remove \(item.displayName) from the shelf")
                    }
                    .padding(.horizontal, DS.SettingsLayout.rowHorizontalPadding)
                    .padding(.vertical, DS.Spacing.xs + 2)
                    SettingsDivider()
                }
                SettingsDestructiveRow(
                    title: "Clear shelf",
                    subtitle: "The files themselves stay where they are.",
                    buttonTitle: "Clear shelf",
                    confirmationTitle: "Clear the shelf?",
                    confirmationMessage: "This removes every item from the shelf. It does not delete the files.",
                    action: { shelfStore.removeAll() }
                )
            }
        }
    }

    private var timerSection: some View {
        SettingsSection("Timer", footer: "Accepts 25m, 1h30m, 90s, or a bare number of minutes.") {
            if let runningTimer = activityCenter.timerStore.runningTimer {
                SettingsRow("Running", subtitle: runningTimer.label, systemImage: "timer") {
                    Button("Cancel timer") { activityCenter.timerStore.cancel() }
                        .dsCapsuleButtonStyle(.secondary)
                }
            } else {
                SettingsRow("Start a timer", systemImage: "timer") {
                    HStack(spacing: DS.Spacing.sm) {
                        TextField("25m", text: $timerDurationText)
                            .settingsFieldChrome()
                            .frame(width: DS.SettingsLayout.fieldMinWidth / 2)
                            .onSubmit(startTimer)
                            .accessibilityLabel("Timer length")
                        Button("Start", action: startTimer)
                            .dsCapsuleButtonStyle(.primary)
                            .disabled(NotchTimerStore.parseDuration(from: timerDurationText) == nil)
                    }
                }
            }
        }
    }

    private func startTimer() {
        guard let duration = NotchTimerStore.parseDuration(from: timerDurationText) else { return }
        activityCenter.timerStore.start(duration: duration, label: timerDurationText)
    }

    private var clipboardSection: some View {
        SettingsSection(
            "Clipboard history",
            footer: "Kept in memory only — nothing is written to disk, and anything a password manager marks as concealed is skipped."
        ) {
            if clipboardStore.entries.isEmpty {
                SettingsEmptyRow(text: "Copy something and it appears here.", systemImage: "doc.on.clipboard")
            } else {
                ForEach(clipboardStore.entries) { entry in
                    HStack(spacing: DS.Spacing.md) {
                        Text(entry.preview)
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Copy") { clipboardStore.copyToPasteboard(entryID: entry.id) }
                            .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                        Button("Remove") { clipboardStore.remove(entryID: entry.id) }
                            .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                    }
                    .padding(.horizontal, DS.SettingsLayout.rowHorizontalPadding)
                    .padding(.vertical, DS.Spacing.xs + 2)
                    SettingsDivider()
                }
                SettingsDestructiveRow(
                    title: "Clear history",
                    buttonTitle: "Clear history",
                    confirmationTitle: "Clear clipboard history?",
                    confirmationMessage: "Every item HeyMate remembered from the clipboard is removed. What's on the clipboard now stays.",
                    action: { clipboardStore.clear() }
                )
            }
        }
    }

    private var calendarSection: some View {
        SettingsSection("Next event") {
            if activityCenter.calendarMonitor.authorizationDenied {
                SettingsNotice(
                    text: "Calendar access is off. Turn it on in System Settings › Privacy & Security › Calendars.",
                    tone: .attention,
                    actionTitle: "Open System Settings",
                    action: {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
                .padding(DS.Spacing.md)
            } else if let nextEvent = activityCenter.calendarMonitor.nextEvent {
                SettingsRow(
                    nextEvent.title,
                    subtitle: nextEvent.startDate.formatted(date: .omitted, time: .shortened),
                    systemImage: "calendar"
                ) {
                    if let joinURL = nextEvent.joinURL {
                        Button("Join") { NSWorkspace.shared.open(joinURL) }
                            .dsCapsuleButtonStyle(.primary)
                    }
                }
            } else {
                SettingsEmptyRow(text: "Nothing on the calendar in the next 12 hours.", systemImage: "calendar")
            }
        }
    }
}
