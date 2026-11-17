//
//  MateSettingsProactivePane.swift
//  HeyMate
//
//  Agent settings › Proactive: check-ins (the heartbeat), quiet hours, what
//  makes it offer to help, its routines, and (for HeyMate itself) standing
//  orders. "Check now" is the only control in agent settings that spends a
//  model turn.
//

import SwiftUI

struct MateSettingsProactivePane: View {
    let context: MateSettingsContext
    @ObservedObject private var companionManager: CompanionManager
    @ObservedObject private var heartbeats = MateHeartbeatStore.shared
    @ObservedObject private var settings = MateAgentSettingsStore.shared
    @State private var heartbeatNotice: String?
    @State private var wakeKind: MateWakeKind?
    @State private var wakeMatch: String
    @State private var wakeProblem: String?
    @State private var wakeSaver = MateSettingsDebouncer()
    @State private var isShowingSchedules = false

    init(context: MateSettingsContext) {
        self.context = context
        self.companionManager = context.companionManager
        let wake = context.companionManager.wake(for: context.mateID)
        _wakeKind = State(initialValue: wake?.kind)
        _wakeMatch = State(initialValue: wake?.match ?? "")
    }

    private var mate: Mate { context.mate }
    private var quiet: MateQuietHours { settings.settings(for: mate.id).quietHours }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.SettingsLayout.sectionSpacing) {
            heartbeatSection
            quietSection
            wakeSection
            routinesSection
            if mate.conductsOthers && !companionManager.loadedStandingOrders.isEmpty {
                standingOrdersSection
            }
        }
        .onChange(of: wakeKind) { _, _ in wakeSaver.schedule(after: .milliseconds(10)) { saveWake() } }
        .onChange(of: wakeMatch) { _, _ in wakeSaver.schedule { saveWake() } }
        .onDisappear { wakeSaver.flush() }
        .sheet(isPresented: $isShowingSchedules) {
            MateSchedulesSheet(companionManager: companionManager)
        }
    }

    // MARK: Check-ins

    private var heartbeatSection: some View {
        let entry = heartbeats.mate(mate.id)
        return SettingsSection(
            "Check-ins",
            footer: "Each check-in is one short, read-only turn on your plan, at most \(MateHeartbeatSchedule.slotsPerDay) a day. It never reads your screen, clipboard or mail bodies."
        ) {
            SettingsToggleRow(
                "Propose work on its own",
                subtitle: heartbeats.state.globalEnabled ? "Ideas land in Waiting on You for a yes." : "Check-ins are off for every agent.",
                isOn: Binding(
                    get: { companionManager.isHeartbeatEnabled(for: mate) },
                    set: { companionManager.setHeartbeatEnabled($0, mateID: mate.id) }
                )
            )
            .disabled(!heartbeats.state.globalEnabled || mate.archived)
            .mateSettingsAnchor("proactive.heartbeat")
            SettingsDivider()
            SettingsRow("Last check-in", subtitle: summary(entry)) {
                HStack(spacing: DS.Spacing.sm) {
                    if heartbeats.runningMateID == mate.id { ProgressView().controlSize(.small) }
                    Button("Check now") { heartbeatNotice = companionManager.runMateHeartbeatNow(mateID: mate.id) }
                        .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                        .disabled(heartbeats.runningMateID != nil || mate.archived)
                        .accessibilityHint("Runs one short check-in now. Uses one turn on your plan.")
                }
            }
            if let heartbeatNotice {
                SettingsInlineHelp(heartbeatNotice, tone: .attention).settingsRowContentInsets()
            }
            SettingsDivider()
            SettingsToggleRow(
                "Allow check-ins for every agent",
                subtitle: "Turning this off stops check-ins for all agents.",
                isOn: Binding(
                    get: { heartbeats.state.globalEnabled },
                    set: { companionManager.setHeartbeatsEnabledGlobally($0) }
                )
            )
        }
    }

    private func summary(_ entry: MateHeartbeatMateState) -> String {
        guard let last = entry.lastRunAt else { return "No check-ins yet." }
        let count = entry.runCount == 1 ? "1 check-in" : "\(entry.runCount) check-ins"
        let when = last.formatted(.relative(presentation: .named))
        return "\(when.prefix(1).uppercased() + when.dropFirst()) · \(count) so far" + (entry.lastStatus.map { " · \($0)" } ?? "")
    }

    // MARK: Quiet hours

    private var quietSection: some View {
        SettingsSection(
            "Quiet hours",
            footer: "No check-ins or offers to help start in quiet hours. A routine still runs; its notice waits until they end."
        ) {
            SettingsToggleRow(
                "Quiet hours",
                subtitle: quiet.summary,
                isOn: Binding(
                    get: { quiet.enabled },
                    set: { value in settings.update(mate.id) { $0.quietHours.enabled = value } }
                )
            )
            .mateSettingsAnchor("proactive.quiet")
            if quiet.enabled {
                SettingsDivider()
                SettingsPickerRow(
                    "From",
                    selection: Binding(
                        get: { quiet.startMinute },
                        set: { value in settings.update(mate.id) { $0.quietHours.startMinute = MateQuietHours.clamped(value) } }
                    ),
                    options: MateSettingsClock.options(including: quiet.startMinute),
                    width: 140
                )
                SettingsDivider()
                SettingsPickerRow(
                    "Until",
                    selection: Binding(
                        get: { quiet.endMinute },
                        set: { value in settings.update(mate.id) { $0.quietHours.endMinute = MateQuietHours.clamped(value) } }
                    ),
                    options: MateSettingsClock.options(including: quiet.endMinute),
                    width: 140
                )
            }
        }
    }

    // MARK: Wakes

    private var wakeSection: some View {
        SettingsSection(
            "Offers to help when",
            footer: wakeKind == nil ? "Stays quiet until you ask." : "One tap in the notch to start. It asks first, every time."
        ) {
            MateWakeField(kind: $wakeKind, match: $wakeMatch)
                .settingsRowInsets()
                .mateSettingsAnchor("proactive.wake")
            if let wakeProblem {
                SettingsInlineHelp(wakeProblem, tone: .attention).settingsRowContentInsets()
            }
        }
    }

    private func saveWake() {
        if let wakeKind, wakeKind.requiresMatch, MateWakeMatcher.terms(wakeMatch).isEmpty {
            wakeProblem = "Name the app it should wait for. Nothing is saved until then."
            return
        }
        wakeProblem = nil
        let saved = companionManager.wake(for: mate.id)
        guard saved?.kind != wakeKind || (saved?.match ?? "") != MateWakeMatcher.cleanedMatch(wakeMatch) else { return }
        companionManager.setMateWake(mateID: mate.id, kind: wakeKind, match: wakeMatch)
    }

    // MARK: Routines

    private var routinesSection: some View {
        let routines = companionManager.routines.filter { $0.mateID == mate.id }
        return SettingsSection("Routines", headerAccessory: AnyView(
            Button("Every agent's schedule") { isShowingSchedules = true }
                .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
        )) {
            RoutineAddField(companionManager: companionManager, mateID: mate.id)
                .settingsRowInsets()
                .mateSettingsAnchor("proactive.routines")
            if routines.isEmpty {
                SettingsDivider()
                SettingsEmptyRow(text: "Nothing scheduled. Try “check my inbox every morning”.", systemImage: "calendar")
            }
            ForEach(routines) { routine in
                SettingsDivider()
                RoutineRow(routine: routine, showsMateName: false, mateName: mate.name, companionManager: companionManager)
                    .settingsRowInsets()
            }
        }
    }

    // MARK: Standing orders

    private var standingOrdersSection: some View {
        SettingsSection("Standing orders", footer: "Rules in your standing-orders folder. A match only offers work; it never starts it.") {
            ForEach(Array(companionManager.loadedStandingOrders.enumerated()), id: \.element.id) { index, order in
                if index > 0 { SettingsDivider() }
                SettingsToggleRow(
                    order.name,
                    subtitle: order.task,
                    isOn: Binding(
                        get: { order.enabled },
                        set: { _ = companionManager.setStandingOrderEnabled($0, order: order) }
                    )
                )
            }
        }
    }
}
