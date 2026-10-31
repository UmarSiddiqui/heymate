//
//  NoteDashboardView.swift
//  HeyMate
//
//  Dashboard board (sections + overall status) and the routine editor.
//  Routines are HeyMate's real `MateRoutine`s seen through `RoutineControl`;
//  edits go back through the same CompanionManager calls the mate pages use.
//

import SwiftUI

extension StatusState {
    var color: Color {
        switch self {
        case .idle: return DS.Colors.textTertiary
        case .running: return DS.Colors.info
        case .ok: return DS.Colors.success
        case .warning: return DS.Colors.warning
        case .failed: return DS.Colors.destructive
        }
    }
}

struct StatusPill: View {
    let state: StatusState
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(state.color).frame(width: 7, height: 7)
            Text(state.label).font(DS.Fonts.statusWord).foregroundColor(DS.Colors.textPrimary)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(DS.Colors.surface2))
    }
}

struct DashboardBoardView: View {
    let board: DashboardBoard

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                HStack {
                    Text(board.title).font(DS.Fonts.pageTitle).foregroundColor(DS.Colors.textPrimary)
                    Spacer()
                    StatusPill(state: board.overall)
                }
                if board.sections.isEmpty {
                    Text("Nothing here yet.").font(DS.Fonts.body).foregroundColor(DS.Colors.textTertiary)
                }
                ForEach(board.sections) { section in
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        HStack(spacing: 6) {
                            Circle().fill(section.status.color).frame(width: 7, height: 7)
                            Text(section.title.uppercased()).font(DS.Fonts.sectionLabel).foregroundColor(DS.Colors.textSecondary)
                            Text("\(section.items.count)").font(DS.Fonts.numeric).foregroundColor(DS.Colors.textTertiary)
                        }
                        ForEach(section.items) { item in
                            HStack {
                                Text(item.text).font(DS.Fonts.body).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                                Spacer()
                                if let every = item.attributes["every"] {
                                    Text(every).font(DS.Fonts.caption).foregroundColor(DS.Colors.textTertiary)
                                }
                                if let runs = item.attributes["runs"] {
                                    Text("\(runs) runs").font(DS.Fonts.numeric).foregroundColor(DS.Colors.textTertiary)
                                }
                            }
                            .padding(DS.Spacing.md)
                            .background(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous).fill(DS.Colors.surface1))
                        }
                    }
                }
                if !board.changes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WHAT CHANGED").font(DS.Fonts.sectionLabel).foregroundColor(DS.Colors.textSecondary)
                        ForEach(board.changes, id: \.self) { change in
                            Text("• \(change)").font(DS.Fonts.body).foregroundColor(DS.Colors.textSecondary)
                        }
                    }
                }
            }
            .padding(DS.Spacing.lg)
        }
        .background(DS.Colors.background)
    }
}

/// What the editor can do to a routine. Wired to CompanionManager in DesktopRootView.
struct RoutineActions {
    var pause: (UUID) -> Void = { _ in }
    var resume: (UUID) -> Void = { _ in }
    var runNow: (UUID) -> Void = { _ in }
    /// Returns an inline error message, or nil when saved.
    var save: (UUID, String, String) -> String? = { _, _, _ in nil }
}

struct RoutineEditorView: View {
    let routines: [MateRoutine]
    var runningID: UUID?
    var actions = RoutineActions()
    @State private var selected: UUID?
    @State private var task = ""
    @State private var daily = false
    @State private var hours = 1
    @State private var time = Date()
    @State private var error: String?

    private var controls: [RoutineControl] { routines.map { RoutineControl($0, isRunning: $0.id == runningID) } }
    private var current: (MateRoutine, RoutineControl)? {
        routines.first { $0.id == selected }.map { ($0, RoutineControl($0, isRunning: $0.id == runningID)) }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(controls, selection: $selected) { control in
                VStack(alignment: .leading, spacing: 2) {
                    Text(control.title).font(DS.Fonts.body).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                    Text(control.isPaused ? "Paused" : control.intervalLabel).font(DS.Fonts.caption)
                        .foregroundColor(control.isPaused ? DS.Colors.warningText : DS.Colors.textTertiary)
                }.tag(control.id)
            }
            .listStyle(.sidebar).frame(width: 220)
            Divider()
            if let (routine, control) = current { editor(routine, control).id(routine.id) }
            else {
                Text(routines.isEmpty ? "No routines yet. Ask a mate to run something on a schedule." : "Select a routine")
                    .font(DS.Fonts.body).foregroundColor(DS.Colors.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DS.Colors.background)
        .onAppear { if selected == nil { selected = routines.first?.id } }
        .onChange(of: selected) { _, _ in error = nil }
    }

    private func editor(_ routine: MateRoutine, _ control: RoutineControl) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                Text("Routine").font(DS.Fonts.title).foregroundColor(DS.Colors.textPrimary)
                Spacer()
                if control.isRunning { StatusPill(state: .running) }
                else if control.isPausedAfterFailures { StatusPill(state: .failed) }
                else if control.isPaused { StatusPill(state: .warning) }
            }
            TextField("What should it do?", text: $task, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
            Picker("", selection: $daily) {
                Text("Every N hours").tag(false); Text("Daily").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
            if daily {
                DatePicker("At", selection: $time, displayedComponents: .hourAndMinute).frame(width: 200)
            } else {
                Stepper("Every \(hours) hour\(hours == 1 ? "" : "s")", value: $hours, in: 1...168).frame(width: 220)
            }
            HStack(spacing: DS.Spacing.xl) {
                fact("Interval", control.intervalLabel)
                fact("Next run", control.isPaused ? "—" : control.nextRunAt.formatted(date: .abbreviated, time: .shortened))
                fact("Runs", "\(control.runCount)")
            }
            if let reason = routine.pausedReason {
                Text(reason).font(DS.Fonts.caption).foregroundColor(DS.Colors.warningText)
            }
            if let error { Text(error).font(DS.Fonts.caption).foregroundColor(DS.Colors.destructiveText) }
            HStack {
                Button("Save") { error = actions.save(routine.id, task, phrase) }.buttonStyle(.borderedProminent)
                if control.isPaused { Button("Resume") { actions.resume(routine.id) } }
                else { Button("Pause") { actions.pause(routine.id) } }
                Button("Run now") { actions.runNow(routine.id) }.disabled(control.isRunning)
            }
            Text("Intervals are set in whole hours or a daily time; the list shows the stored interval in minutes.")
                .font(DS.Fonts.caption).foregroundColor(DS.Colors.textTertiary)
            Spacer()
        }
        .padding(DS.Spacing.lg).frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear { load(routine) }
    }

    private var phrase: String {
        if daily {
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            return RoutineSchedule.daily(hour: c.hour ?? 9, minute: c.minute ?? 0).instructionPhrase
        }
        return RoutineSchedule.everyHours(hours).instructionPhrase
    }

    private func load(_ routine: MateRoutine) {
        task = routine.task
        switch routine.schedule {
        case .everyHours(let h): daily = false; hours = max(1, h)
        case .daily(let h, let m):
            daily = true
            time = Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(DS.Fonts.micro).foregroundColor(DS.Colors.textTertiary)
            Text(value).font(DS.Fonts.numeric).foregroundColor(DS.Colors.textPrimary)
        }
    }
}
