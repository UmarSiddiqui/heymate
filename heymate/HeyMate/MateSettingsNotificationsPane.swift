//
//  MateSettingsNotificationsPane.swift
//  HeyMate
//
//  Agent settings › Notifications: which Mac notifications this agent may
//  send while you're in another app. All on by default; finished work never
//  notifies while HeyMate is in front, since you're already watching.
//

import SwiftUI

struct MateSettingsNotificationsPane: View {
    let context: MateSettingsContext
    @ObservedObject private var settings = MateAgentSettingsStore.shared

    private var mateID: UUID { context.mateID }
    private var preferences: MateNotificationPreferences { settings.settings(for: mateID).notifications }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.SettingsLayout.sectionSpacing) {
            SettingsSection(
                "Notify me",
                footer: "Only while you're in another app. During quiet hours, proposals, results and failures wait until they end."
            ) {
                toggle("Proposals", subtitle: "A check-in found something it could do.", keyPath: \.proposals,
                       anchor: "notifications.proposals")
                SettingsDivider()
                toggle("Finished work", subtitle: "A job or task you handed off is done. Skipped while you're watching the chat.",
                       keyPath: \.finishedWork, anchor: "notifications.finished")
                SettingsDivider()
                toggle("Needs your input", subtitle: "It's waiting on an approval, a plan or a question.",
                       keyPath: \.needsInput, anchor: "notifications.needsInput")
                SettingsDivider()
                toggle("Failed routine", subtitle: "A routine or job stopped and won't retry on its own.",
                       keyPath: \.failedRoutine, anchor: "notifications.failed")
            }
            SettingsSection {
                SettingsRow("macOS notification settings",
                            subtitle: "If nothing arrives, check that HeyMate may notify in System Settings › Notifications.",
                            systemImage: "bell.badge")
            }
        }
    }

    private func toggle(_ title: String, subtitle: String,
                        keyPath: WritableKeyPath<MateNotificationPreferences, Bool>, anchor: String) -> some View {
        SettingsToggleRow(title, subtitle: subtitle, isOn: Binding(
            get: { preferences[keyPath: keyPath] },
            set: { value in settings.update(mateID) { $0.notifications[keyPath: keyPath] = value } }
        ))
        .mateSettingsAnchor(anchor)
    }
}
