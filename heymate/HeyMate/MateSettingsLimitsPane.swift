//
//  MateSettingsLimitsPane.swift
//  HeyMate
//
//  Agent settings › Limits: caps the app enforces for this agent, and today's
//  activity as plain counts kept on this Mac. No token or price figures.
//

import SwiftUI

struct MateSettingsLimitsPane: View {
    let context: MateSettingsContext
    @ObservedObject private var settings = MateAgentSettingsStore.shared

    private var mateID: UUID { context.mateID }
    private var limits: MateAgentLimits { settings.settings(for: mateID).limits }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.SettingsLayout.sectionSpacing) {
            SettingsSection("Caps", footer: "Stopping at a cap never loses work: the chat says where it stopped.") {
                SettingsPickerRow(
                    "Continuations per task",
                    subtitle: "How many more turns a long task may take after its first, one turn's time and steps each.",
                    selection: Binding(
                        get: { limits.maxContinuations ?? -1 },
                        set: { value in settings.update(mateID) { $0.limits.maxContinuations = value < 0 ? nil : value } }
                    ),
                    options: continuationOptions,
                    width: 160
                )
                .mateSettingsAnchor("limits.continuations")
                SettingsDivider()
                SettingsPickerRow(
                    "Routine time limit",
                    subtitle: "For routines without their own limit. A routine that runs past it stops and tries the next slot.",
                    selection: Binding(
                        get: { limits.routineMinutes ?? -1 },
                        set: { value in settings.update(mateID) { $0.limits.routineMinutes = value < 0 ? nil : value } }
                    ),
                    options: routineOptions,
                    width: 160
                )
                .mateSettingsAnchor("limits.routine")
                SettingsDivider()
                SettingsPickerRow(
                    "Check-ins per day",
                    subtitle: "Automatic check-ins only. Check now isn't counted.",
                    selection: Binding(
                        get: { limits.heartbeatsPerDay ?? -1 },
                        set: { value in settings.update(mateID) { $0.limits.heartbeatsPerDay = value < 0 ? nil : value } }
                    ),
                    options: heartbeatOptions,
                    width: 160
                )
                .mateSettingsAnchor("limits.heartbeats")
            }

            let today = settings.today(for: mateID)
            SettingsSection("Today", footer: "Counted on this Mac since midnight. Resets each day.") {
                countRow("Turns", today.turns, systemImage: "bubble.left")
                SettingsDivider()
                countRow("Check-ins", today.heartbeats, systemImage: "clock.arrow.circlepath")
                SettingsDivider()
                countRow("Routine runs", today.routineRuns, systemImage: "calendar")
            }
            .mateSettingsAnchor("limits.today")
        }
    }

    private func countRow(_ title: String, _ count: Int, systemImage: String) -> some View {
        SettingsRow(title, systemImage: systemImage) {
            Text("\(count)")
                .font(DS.Fonts.bodyLarge)
                .monospacedDigit()
                .foregroundColor(DS.Colors.textPrimary)
                .accessibilityLabel("\(count) \(title.lowercased())")
        }
    }

    private var continuationOptions: [DSMenuOption<Int>] {
        [DSMenuOption(value: -1, title: "Default (\(MateAgentContinuation.maxContinuations))")]
            + [0, 3, 6, 12, 24, 48].enumerated().map { index, value in
                DSMenuOption(value: value, title: value == 0 ? "None" : "\(value)", startsGroup: index == 0)
            }
    }

    private var routineOptions: [DSMenuOption<Int>] {
        [DSMenuOption(value: -1, title: "No limit")]
            + [5, 15, 30, 60, 120, 240].enumerated().map { index, value in
                DSMenuOption(value: value, title: value < 60 ? "\(value) min" : "\(value / 60) h", startsGroup: index == 0)
            }
    }

    private var heartbeatOptions: [DSMenuOption<Int>] {
        [DSMenuOption(value: -1, title: "Default (\(MateAgentLimits.defaultHeartbeatsPerDay))")]
            + Array(MateAgentLimits.heartbeatRange).enumerated().map { index, value in
                DSMenuOption(value: value, title: value == 0 ? "None" : "\(value)", startsGroup: index == 0)
            }
    }
}
