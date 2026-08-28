//
//  DesktopSupportingViews.swift
//  leanring-buddy
//
//  The remaining desktop sections: the notch's micro-apps, skills, memory,
//  and privacy. Each is small enough that a file per section would be
//  filing for its own sake; they share the `DesktopPage` / `DesktopCard`
//  scaffold from DesktopRootView.
//

import AppKit
import SwiftUI

// MARK: - Notch micro-apps

struct DesktopNotchView: View {
    @ObservedObject var activityCenter: NotchActivityCenter
    @ObservedObject private var shelfStore: NotchShelfStore
    @ObservedObject private var clipboardStore: ClipboardHistoryStore

    @State private var timerDurationText = "25m"

    init(activityCenter: NotchActivityCenter) {
        self.activityCenter = activityCenter
        self.shelfStore = activityCenter.shelfStore
        self.clipboardStore = activityCenter.clipboardStore
    }

    var body: some View {
        DesktopPage(
            title: "Notch",
            subtitle: "Small things that live around the camera. Everything here is off until you turn it on."
        ) {
            microAppGrid

            if activityCenter.isEnabled(.shelf) {
                shelfCard
            }
            if activityCenter.isEnabled(.timer) {
                timerCard
            }
            if activityCenter.isEnabled(.clipboard) {
                clipboardCard
            }
            if activityCenter.isEnabled(.calendar) {
                calendarCard
            }

            hoverBehaviorCard
        }
    }

    private var microAppGrid: some View {
        DesktopCard(
            title: "Micro-apps",
            footnote: "Only one shows in the collapsed notch at a time. Something you just did beats something ambient."
        ) {
            VStack(spacing: 0) {
                ForEach(Array(NotchMicroApp.allCases.enumerated()), id: \.element) { index, microApp in
                    if index > 0 { Divider().opacity(0.25).padding(.vertical, 2) }
                    Toggle(isOn: Binding(
                        get: { activityCenter.isEnabled(microApp) },
                        set: { activityCenter.setEnabled($0, for: microApp) }
                    )) {
                        HStack(spacing: 10) {
                            Image(systemName: microApp.symbolName)
                                .font(DS.Fonts.body)
                                .frame(width: 20)
                                .foregroundColor(DS.Colors.textSecondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(microApp.displayName)
                                    .font(DS.Fonts.headline)
                                HStack(spacing: 5) {
                                    Text(microApp.explanation)
                                        .font(DS.Fonts.caption)
                                        .foregroundColor(DS.Colors.textTertiary)
                                    if let permission = microApp.requiredPermissionDescription {
                                        Text("· asks for \(permission)")
                                            .font(DS.Fonts.caption)
                                            .foregroundColor(DS.Colors.warningText)
                                    }
                                }
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(.vertical, 5)
                }
            }
        }
    }

    private var shelfCard: some View {
        DesktopCard(
            title: "File shelf",
            footnote: "HeyMate keeps a bookmark, never a copy. Items clear themselves after a day."
        ) {
            if shelfStore.items.isEmpty {
                Text("Drag files onto the notch to park them here.")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(shelfStore.items) { item in
                        HStack(spacing: 10) {
                            if let thumbnail = item.thumbnail {
                                Image(nsImage: thumbnail)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 26, height: 26)
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            } else {
                                Image(systemName: "doc")
                                    .frame(width: 26, height: 26)
                                    .foregroundColor(DS.Colors.textTertiary)
                            }
                            Text(item.displayName)
                                .font(DS.Fonts.body)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Button("Reveal") { shelfStore.reveal(itemID: item.id) }
                                .buttonStyle(DSTertiaryButtonStyle())
                            Button {
                                shelfStore.remove(itemID: item.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(DS.Colors.destructiveText)
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                        }
                        .padding(.vertical, 5)
                        Divider().opacity(0.2)
                    }
                    HStack {
                        Spacer()
                        Button("Clear shelf") { shelfStore.removeAll() }
                            .buttonStyle(DSTertiaryButtonStyle())
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    private var timerCard: some View {
        DesktopCard(title: "Timer") {
            HStack(spacing: 10) {
                TextField("25m", text: $timerDurationText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit(startTimer)
                Button("Start", action: startTimer)
                    .buttonStyle(DSPrimaryButtonStyle())
                    .disabled(NotchTimerStore.parseDuration(from: timerDurationText) == nil)

                if let runningTimer = activityCenter.timerStore.runningTimer {
                    Spacer(minLength: 0)
                    Text(runningTimer.label)
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textSecondary)
                    Button("Cancel") { activityCenter.timerStore.cancel() }
                        .buttonStyle(DSSecondaryButtonStyle())
                } else {
                    Spacer(minLength: 0)
                    Text("Accepts 25m, 1h30m, 90s, or a bare number of minutes.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
        }
    }

    private func startTimer() {
        guard let duration = NotchTimerStore.parseDuration(from: timerDurationText) else { return }
        activityCenter.timerStore.start(duration: duration, label: timerDurationText)
    }

    private var clipboardCard: some View {
        DesktopCard(
            title: "Clipboard",
            footnote: "Memory only — nothing is written to disk, and anything a password manager marks as concealed is skipped."
        ) {
            if clipboardStore.entries.isEmpty {
                Text("Copy something and it will appear here.")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(clipboardStore.entries.prefix(12)) { entry in
                        HStack(spacing: 10) {
                            Text(entry.preview)
                                .font(DS.Fonts.body)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Button("Copy") { clipboardStore.copyToPasteboard(entryID: entry.id) }
                                .buttonStyle(DSTertiaryButtonStyle())
                        }
                        .padding(.vertical, 5)
                        Divider().opacity(0.2)
                    }
                    HStack {
                        Spacer()
                        Button("Clear history") { clipboardStore.clear() }
                            .buttonStyle(DSTertiaryButtonStyle())
                    }
                    .padding(.top, 6)
                }
            }
        }
    }

    @ViewBuilder
    private var calendarCard: some View {
        DesktopCard(title: "Next event") {
            if activityCenter.calendarMonitor.authorizationDenied {
                Text("Calendar access was declined. Turn it on in System Settings › Privacy & Security › Calendars.")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.warningText)
            } else if let nextEvent = activityCenter.calendarMonitor.nextEvent {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nextEvent.title)
                            .font(DS.Fonts.headline)
                        Text(nextEvent.startDate.formatted(date: .omitted, time: .shortened))
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    Spacer(minLength: 0)
                    if let joinURL = nextEvent.joinURL {
                        Button("Join") { NSWorkspace.shared.open(joinURL) }
                            .buttonStyle(DSPrimaryButtonStyle())
                    }
                }
            } else {
                Text("Nothing on the calendar in the next 12 hours.")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    private var hoverBehaviorCard: some View {
        DesktopCard(
            title: "Behavior",
            footnote: "Hovering peeks by default. Opening the whole card stays a deliberate click."
        ) {
            Toggle(isOn: Binding(
                get: { NotchCompanionController.hoverOpensCard },
                set: { NotchCompanionController.hoverOpensCard = $0 }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Open the card on hover")
                        .font(DS.Fonts.headline)
                    Text("Off: hovering widens the notch and shows a peek. On: resting for a moment drops the full card.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .toggleStyle(.switch)
        }
    }
}

// MARK: - Memory

struct DesktopMemoryView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        DesktopPage(
            title: "Memory",
            subtitle: "Text only, stored on this Mac. Screenshots are never retained — the store has no field to put them in."
        ) {
            DesktopCard(title: "Behavior") {
                Toggle(isOn: $companionManager.rememberConversationsEnabled) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Remember conversations")
                            .font(DS.Fonts.headline)
                        Text("Keeps a rolling summary so HeyMate can refer back to earlier turns.")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
                .toggleStyle(.switch)
            }

            if companionManager.memoryItems.isEmpty {
                DesktopEmptyState(
                    symbolName: "brain",
                    title: "Nothing remembered yet",
                    message: "HeyMate writes a memory when something is worth carrying between conversations."
                )
            } else {
                DesktopCard(title: "Stored memories") {
                    VStack(spacing: 0) {
                        ForEach(companionManager.memoryItems) { item in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.text)
                                        .font(DS.Fonts.body)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(DS.Fonts.micro)
                                        .foregroundColor(DS.Colors.textTertiary)
                                }
                                Spacer(minLength: 0)
                                Button {
                                    companionManager.deleteMemory(id: item.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundColor(DS.Colors.destructiveText)
                                }
                                .buttonStyle(.plain)
                                .pointerCursor()
                                .help("Forget this")
                            }
                            .padding(.vertical, 6)
                            Divider().opacity(0.2)
                        }
                        HStack {
                            Spacer()
                            Button("Forget everything") { companionManager.clearAllMemory() }
                                .buttonStyle(DSDestructiveButtonStyle())
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }
    }
}

// MARK: - Privacy

struct DesktopPrivacyView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var newBundleIdentifier = ""

    var body: some View {
        DesktopPage(
            title: "Privacy",
            subtitle: "Apps on this list are never captured for screen context — not for Talk, not for smart dictation, not for demos."
        ) {
            DesktopCard(
                title: "Never capture these apps",
                footnote: "Password managers and System Settings are excluded by default and cannot be removed."
            ) {
                VStack(spacing: 0) {
                    ForEach(companionManager.excludedAppBundleIds, id: \.self) { bundleIdentifier in
                        HStack(spacing: 10) {
                            Image(systemName: "hand.raised.fill")
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.success)
                            Text(bundleIdentifier)
                                .font(.system(size: 12, design: .monospaced))
                            Spacer(minLength: 0)
                            if !ExcludedApps.defaultExcludedBundleIds.contains(bundleIdentifier) {
                                Button {
                                    companionManager.removeUserAppExclusion(bundleIdentifier)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(DS.Colors.destructiveText)
                                }
                                .buttonStyle(.plain)
                                .pointerCursor()
                            } else {
                                Text("Built in")
                                    .font(DS.Fonts.micro)
                                    .foregroundColor(DS.Colors.textTertiary)
                            }
                        }
                        .padding(.vertical, 5)
                        Divider().opacity(0.2)
                    }

                    HStack(spacing: 8) {
                        TextField("com.example.app", text: $newBundleIdentifier)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit(addExclusion)
                        Button("Add", action: addExclusion)
                            .buttonStyle(DSSecondaryButtonStyle())
                            .disabled(newBundleIdentifier.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.top, 8)
                }
            }

            DesktopCard(
                title: "What leaves this Mac",
                footnote: "Local engines keep everything on-device. The cloud engine sends the screenshot and transcript for the turn, and nothing else."
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    privacyFact("Screenshots", "Sent for the turn that needs them, never stored.")
                    privacyFact("Transcripts", "On-device by default (Apple Speech). Cloud providers are opt-in.")
                    privacyFact("Memory", "A local JSON file. Text only, by construction.")
                    privacyFact("Clipboard history", "In memory only, cleared when HeyMate quits.")
                    privacyFact("Connector keys", "macOS Keychain, this device only.")
                }
            }
        }
    }

    private func privacyFact(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(DS.Fonts.body)
                .frame(width: 130, alignment: .leading)
            Text(detail)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func addExclusion() {
        let trimmed = newBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        companionManager.addUserAppExclusion(trimmed)
        newBundleIdentifier = ""
    }
}
