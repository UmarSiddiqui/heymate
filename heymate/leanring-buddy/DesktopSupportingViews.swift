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
import UniformTypeIdentifiers

// MARK: - Notch micro-apps

struct DesktopNotchView: View {
    @ObservedObject var activityCenter: NotchActivityCenter
    @ObservedObject private var shelfStore: NotchShelfStore
    @ObservedObject private var clipboardStore: ClipboardHistoryStore

    @State private var timerDurationText = "25m"
    @State private var isConfirmingShelfClear = false
    @State private var isConfirmingClipboardClear = false

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
        VStack(alignment: .leading, spacing: 10) {
            Text("Micro-apps")
                .font(DS.Fonts.sectionLabel)
                .foregroundColor(DS.Colors.textSecondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 10)],
                spacing: 10
            ) {
                ForEach(NotchMicroApp.allCases) { microApp in
                    MicroAppSettingsCard(
                        microApp: microApp,
                        isEnabled: Binding(
                            get: { activityCenter.isEnabled(microApp) },
                            set: { activityCenter.setEnabled($0, for: microApp) }
                        ),
                        needsPermission: activityCenter.needsPermissionPrompt(for: microApp)
                    )
                }
            }

            Label(
                "Collapsed notch shows one app at a time, prioritizing your latest activity.",
                systemImage: "info.circle"
            )
            .font(DS.Fonts.caption)
            .foregroundColor(DS.Colors.textTertiary)
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
                        Button("Clear shelf") { isConfirmingShelfClear = true }
                            .buttonStyle(DSTertiaryButtonStyle())
                    }
                    .padding(.top, 6)
                }
            }
        }
        .confirmationDialog(
            "Clear the shelf? This does not delete the files.",
            isPresented: $isConfirmingShelfClear,
            titleVisibility: .visible
        ) {
            Button("Clear the shelf", role: .destructive) {
                shelfStore.removeAll()
            }
            Button("Cancel", role: .cancel) {}
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
                    ForEach(clipboardStore.entries) { entry in
                        HStack(spacing: 10) {
                            Text(entry.preview)
                                .font(DS.Fonts.body)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Button("Copy") { clipboardStore.copyToPasteboard(entryID: entry.id) }
                                .buttonStyle(DSTertiaryButtonStyle())
                            Button("Remove") { clipboardStore.remove(entryID: entry.id) }
                                .buttonStyle(DSTertiaryButtonStyle())
                        }
                        .padding(.vertical, 5)
                        Divider().opacity(0.2)
                    }
                    HStack {
                        Spacer()
                        Button("Clear history") { isConfirmingClipboardClear = true }
                            .buttonStyle(DSTertiaryButtonStyle())
                    }
                    .padding(.top, 6)
                }
            }
        }
        .confirmationDialog(
            "Clear clipboard history?",
            isPresented: $isConfirmingClipboardClear,
            titleVisibility: .visible
        ) {
            Button("Clear clipboard history", role: .destructive) {
                clipboardStore.clear()
            }
            Button("Cancel", role: .cancel) {}
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
                    Text("Off: hovering highlights the notch. On: resting for a moment drops the full card.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .toggleStyle(.switch)
        }
    }
}

private struct MicroAppSettingsCard: View {
    let microApp: NotchMicroApp
    @Binding var isEnabled: Bool
    let needsPermission: Bool

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                Image(systemName: microApp.symbolName)
                    .font(DS.Glyph.large)
                    .foregroundColor(isEnabled ? DS.Colors.accentText : DS.Colors.textSecondary)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .fill(isEnabled ? DS.Colors.accentSubtle : DS.Colors.surface3)
                    )

                Text(microApp.displayName)
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel("Enable \(microApp.displayName)")
            }

            Text(microApp.explanation)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let permission = microApp.requiredPermissionDescription {
                Label(
                    needsPermission ? permission : "Permission granted",
                    systemImage: needsPermission ? "lock.fill" : "checkmark.circle.fill"
                )
                .font(DS.Fonts.micro)
                .foregroundColor(needsPermission ? DS.Colors.warningText : DS.Colors.success)
                .lineLimit(1)
            } else {
                Label("No extra permission", systemImage: "checkmark.circle")
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(isHovered ? DS.Colors.surface2 : DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(
                    isEnabled ? DS.Colors.accent.opacity(0.35) : DS.Colors.borderSubtle,
                    lineWidth: 1
                )
        )
        .shadow(color: isEnabled ? DS.Colors.accent.opacity(0.08) : .clear, radius: 12, y: 5)
        .offset(y: isHovered && !accessibilityReduceMotion ? -1 : 0)
        .animation(accessibilityReduceMotion ? nil : DS.Animation.controlSpring, value: isHovered)
        .animation(.easeOut(duration: DS.Animation.fast), value: isEnabled)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Memory

struct DesktopMemoryView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var editingMemoryID: UUID?
    @State private var editingDraft = ""
    @State private var memoryIDPendingForget: UUID?
    @State private var isConfirmingForgetOne = false
    @State private var isConfirmingForgetEverything = false
    @State private var isConfirmingDeleteSavedChats = false

    var body: some View {
        DesktopPage(
            title: "Memory",
            subtitle: "Text only, stored on this Mac. Screenshots are never retained — the store has no field to put them in."
        ) {
            DesktopCard(title: "Behavior") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $companionManager.rememberConversationsEnabled) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Save chats on this Mac")
                                .font(DS.Fonts.headline)
                            Text("Turning this off stops new saves but does not delete chats already stored.")
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                    }
                    .toggleStyle(.switch)

                    Button("Delete saved chats") {
                        isConfirmingDeleteSavedChats = true
                    }
                    .buttonStyle(DSDestructiveButtonStyle())
                }
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
                            memoryRow(item)
                            Divider().opacity(0.2)
                        }
                        HStack {
                            Button("Export") { exportMemories() }
                                .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
                            Spacer()
                            Button("Forget everything") { isConfirmingForgetEverything = true }
                                .buttonStyle(DSDestructiveButtonStyle())
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete saved chats?",
            isPresented: $isConfirmingDeleteSavedChats,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                companionManager.clearAllChats()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Chats already stored on this Mac are removed. Memories stay.")
        }
        .confirmationDialog(
            "Delete everything HeyMate remembers?",
            isPresented: $isConfirmingForgetEverything,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                editingMemoryID = nil
                editingDraft = ""
                companionManager.clearAllMemory()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Forget this memory?",
            isPresented: $isConfirmingForgetOne,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = memoryIDPendingForget {
                    if editingMemoryID == id {
                        editingMemoryID = nil
                        editingDraft = ""
                    }
                    companionManager.deleteMemory(id: id)
                }
                memoryIDPendingForget = nil
            }
            Button("Cancel", role: .cancel) { memoryIDPendingForget = nil }
        }
    }

    @ViewBuilder
    private func memoryRow(_ item: MemoryItem) -> some View {
        if editingMemoryID == item.id {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Memory", text: $editingDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(DS.Fonts.body)
                HStack(spacing: 8) {
                    Button("Save") { saveEditingMemory(id: item.id) }
                        .buttonStyle(DSSecondaryButtonStyle(isFullWidth: false))
                        .disabled(editingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") {
                        editingMemoryID = nil
                        editingDraft = ""
                    }
                    .buttonStyle(.plain)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .pointerCursor()
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, 6)
        } else {
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
                Button("Edit") {
                    editingMemoryID = item.id
                    editingDraft = item.text
                }
                .buttonStyle(.plain)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .pointerCursor()
                Button {
                    memoryIDPendingForget = item.id
                    isConfirmingForgetOne = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(DS.Colors.destructiveText)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Forget this")
            }
            .padding(.vertical, 6)
        }
    }

    private func saveEditingMemory(id: UUID) {
        let trimmed = editingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        companionManager.updateMemory(id: id, text: trimmed)
        editingMemoryID = nil
        editingDraft = ""
    }

    private func exportMemories() {
        let exported = memoryExportText(companionManager.memoryItems)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(exported, forType: .string)
        presentMemoryExportSavePanel(exported)
    }

    private func memoryExportText(_ items: [MemoryItem]) -> String {
        items.map { item in
            let stamp = item.createdAt.formatted(date: .abbreviated, time: .shortened)
            return "\(stamp)\n\(item.text)"
        }
        .joined(separator: "\n\n")
    }

    private func presentMemoryExportSavePanel(_ exported: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "HeyMate-memories.txt"
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            try? exported.write(to: destination, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Privacy

struct DesktopPrivacyView: View {
    @ObservedObject var companionManager: CompanionManager
    /// Extra cards appended below the privacy facts. Settings › Privacy uses
    /// it for the erase-local-data card; the sidebar page passes nothing.
    var trailingContent: AnyView? = nil
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
                    privacyFact("Connector keys", "A private file on this Mac, readable only by your account.")
                }
            }

            if let trailingContent {
                trailingContent
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
