//
//  NotchMicroAppsView.swift
//  HeyMate
//
//  Compact launcher and live surface for notch micro-apps. Configuration
//  stays one click away; active tools remain useful without opening the
//  full desktop window.
//

import AppKit
import SwiftUI

struct NotchMicroAppsView: View {
    @ObservedObject private var activityCenter: NotchActivityCenter
    @ObservedObject private var shelfStore: NotchShelfStore
    @ObservedObject private var timerStore: NotchTimerStore
    @ObservedObject private var clipboardStore: ClipboardHistoryStore

    private let companionManager: CompanionManager

    @State private var isConfirmingShelfClear = false
    @State private var isConfirmingClipboardClear = false

    /// Height of every live section's body (the row under its label), so
    /// the timer, shelf, clipboard and mirror line up across the card.
    static let liveBodyHeight: CGFloat = 44

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        let center = companionManager.notchActivityCenter
        self.activityCenter = center
        self.shelfStore = center.shelfStore
        self.timerStore = center.timerStore
        self.clipboardStore = center.clipboardStore
    }

    /// Two horizontal bands that match the card's wide, short shape: one
    /// row of tool switches across the full width, and under it the live
    /// tools side by side. Either band scrolls sideways, with soft edge
    /// fades, when there is more than fits; nothing is clipped vertically.
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm + 2) {
            launcherRow
            liveRow
        }
        .padding(.vertical, DS.Spacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Launcher

    /// Every micro app as a borderless icon + label switch, then Manage.
    /// Spread evenly when they fit; otherwise a sideways scroll that fades
    /// out under Manage instead of wrapping into rows.
    private var launcherRow: some View {
        HStack(spacing: DS.Spacing.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(NotchMicroApp.allCases.enumerated()), id: \.element) { index, microApp in
                        launcherItem(microApp)
                        if index < NotchMicroApp.allCases.count - 1 {
                            Spacer(minLength: 2)
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.lg)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(NotchMicroApp.allCases) { microApp in
                            launcherItem(microApp)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                }
                .notchHorizontalEdgeFade()
            }

            NotchLinkButton(title: "Manage", systemImage: "slider.horizontal.3") {
                companionManager.openDesktopWindow(section: .notch)
            }
            .help("Choose micro apps in the HeyMate window")
            .padding(.trailing, DS.Spacing.lg - 8)
        }
        .frame(height: DS.ControlSize.regular)
    }

    private func launcherItem(_ microApp: NotchMicroApp) -> some View {
        let isEnabled = activityCenter.isEnabled(microApp)
        let needsPermission = activityCenter.needsPermissionPrompt(for: microApp)
        return Button {
            // An on-but-unpermitted switch is one tap from working, so
            // that tap asks macOS rather than turning the app off.
            if needsPermission {
                activityCenter.grantPendingPermission(for: microApp)
            } else {
                activityCenter.setEnabled(!isEnabled, for: microApp)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: needsPermission ? "lock.fill" : microApp.symbolName)
                    .font(DS.Glyph.small)
                    .foregroundColor(
                        needsPermission ? DS.Colors.warningText
                            : isEnabled ? DS.Colors.accentText : DS.Colors.textTertiary
                    )
                    .frame(width: 14)
                Text(microApp.compactDisplayName)
                    .font(DS.Fonts.caption.weight(isEnabled ? .semibold : .regular))
                    .foregroundColor(isEnabled ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(height: DS.ControlSize.regular)
        }
        .notchSoftButtonStyle(.capsule)
        .accessibilityLabel(microApp.displayName)
        .accessibilityValue(isEnabled ? "On" : "Off")
        .help(
            needsPermission
                ? "\(microApp.displayName) needs your permission — click to allow"
                : "Turn \(microApp.displayName) \(isEnabled ? "off" : "on")"
        )
    }

    // MARK: Live tools

    private var hasLiveSection: Bool {
        activityCenter.isEnabled(.timer) || activityCenter.isEnabled(.shelf)
            || activityCenter.isEnabled(.clipboard) || activityCenter.isEnabled(.mirror)
    }

    /// The tools that are on, side by side. Each is a quiet label over one
    /// row of controls; no section boxes.
    private var liveRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: DS.Spacing.xxl) {
                NotchTrayStrip(
                    activityCenter: activityCenter,
                    scrollsHorizontally: false,
                    onOpenDesktop: companionManager.openDesktopWindow
                )
                if activityCenter.isEnabled(.timer) {
                    timerSection
                }
                if activityCenter.isEnabled(.shelf) {
                    shelfSection
                }
                if activityCenter.isEnabled(.clipboard) {
                    clipboardSection
                }
                if activityCenter.isEnabled(.mirror) {
                    NotchCameraMirrorView(compactHeight: Self.liveBodyHeight)
                }
                if !hasLiveSection {
                    Text("Turn a tool on above and its controls show up here.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(height: Self.liveBodyHeight)
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
        }
        .notchHorizontalEdgeFade()
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sectionHeader<Trailing: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            DSSectionLabel(title: title)
            trailing()
        }
        .frame(height: 16)
    }

    private var timerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Focus timer")
            HStack(spacing: 6) {
                if let runningTimer = timerStore.runningTimer {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(NotchTimerStore.formatted(
                            remainingSeconds: runningTimer.remaining(asOf: context.date)
                        ))
                        .font(DS.Fonts.numericLarge)
                        .foregroundColor(DS.Colors.textPrimary)
                    }
                    microButton("Stop") { timerStore.cancel() }
                } else {
                    ForEach([5, 25, 45], id: \.self) { minutes in
                        microButton("\(minutes)m") {
                            timerStore.start(
                                duration: TimeInterval(minutes * 60),
                                label: minutes == 25 ? "Focus" : "Timer"
                            )
                        }
                    }
                }
            }
            .frame(height: Self.liveBodyHeight, alignment: .center)
        }
        .fixedSize()
    }

    private var shelfSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("File shelf") {
                if !shelfStore.items.isEmpty {
                    NotchLinkButton(title: "AirDrop", systemImage: "airplayaudio", color: DS.Colors.textSecondary) {
                        shareShelfViaAirDrop()
                    }
                    .help("Share shelf with AirDrop")

                    NotchLinkButton(title: "Clear", color: DS.Colors.textSecondary) {
                        isConfirmingShelfClear = true
                    }
                }
            }

            Group {
                if shelfStore.items.isEmpty {
                    Label("Drop files on the notch", systemImage: "arrow.down.doc")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                } else {
                    HStack(spacing: 6) {
                        ForEach(shelfStore.items) { item in
                            shelfItem(item)
                        }
                    }
                }
            }
            .frame(height: Self.liveBodyHeight, alignment: .leading)
        }
        .fixedSize()
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

    private func shareShelfViaAirDrop() {
        let fileURLs = shelfStore.items.map(\.fileURL)
        guard !fileURLs.isEmpty else { return }
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: fileURLs)
    }

    private func shelfItem(_ item: NotchShelfStore.ShelfItem) -> some View {
        VStack(spacing: 3) {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "doc")
                        .font(DS.Glyph.regular)
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
            .frame(width: 34, height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Colors.notchWellFill))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(item.displayName)
                .font(DS.Fonts.micro)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
                .frame(width: 48)
        }
        .contentShape(Rectangle())
        .onTapGesture { shelfStore.open(itemID: item.id) }
        .onDrag { NSItemProvider(contentsOf: item.fileURL) ?? NSItemProvider() }
        .contextMenu {
            Button("Reveal in Finder") { shelfStore.reveal(itemID: item.id) }
            Button("Remove") { shelfStore.remove(itemID: item.id) }
        }
        .pointerCursor()
        .help(item.displayName)
    }

    /// Recent copies as one row of soft chips. Click copies again; the
    /// context menu (and the chip's tooltip) carries Remove.
    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Clipboard") {
                if !clipboardStore.entries.isEmpty {
                    NotchLinkButton(title: "Clear", color: DS.Colors.textSecondary) {
                        isConfirmingClipboardClear = true
                    }
                }
            }

            Group {
                if clipboardStore.entries.isEmpty {
                    Text("Recent text copies show here")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                } else {
                    HStack(spacing: 6) {
                        ForEach(clipboardStore.entries) { entry in
                            Button {
                                clipboardStore.copyToPasteboard(entryID: entry.id)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.on.doc")
                                        .font(DS.Glyph.micro)
                                        .foregroundColor(DS.Colors.accentText)
                                    Text(entry.preview)
                                        .font(DS.Fonts.caption)
                                        .foregroundColor(DS.Colors.textSecondary)
                                        .lineLimit(1)
                                        .frame(maxWidth: 140, alignment: .leading)
                                }
                                .padding(.horizontal, 10)
                                .frame(height: DS.ControlSize.regular)
                                .fixedSize()
                            }
                            .notchSoftButtonStyle(.capsule, restFill: DS.Colors.notchWellFill)
                            .help("Copy again. Right-click to remove.")
                            .contextMenu {
                                Button("Copy again") { clipboardStore.copyToPasteboard(entryID: entry.id) }
                                Button("Remove") { clipboardStore.remove(entryID: entry.id) }
                            }
                            .accessibilityAction(named: "Remove") { clipboardStore.remove(entryID: entry.id) }
                        }
                    }
                }
            }
            .frame(height: Self.liveBodyHeight, alignment: .leading)
        }
        .fixedSize()
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

    private func microButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.Fonts.control)
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: DS.ControlSize.regular)
        }
        .notchSoftButtonStyle(.capsule, restFill: DS.Colors.notchWellFill)
    }
}
