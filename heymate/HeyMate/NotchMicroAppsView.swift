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
    private let columns = [
        GridItem(.flexible(), spacing: 5),
        GridItem(.flexible(), spacing: 5)
    ]

    @State private var isConfirmingShelfClear = false
    @State private var isConfirmingClipboardClear = false

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        let center = companionManager.notchActivityCenter
        self.activityCenter = center
        self.shelfStore = center.shelfStore
        self.timerStore = center.timerStore
        self.clipboardStore = center.clipboardStore
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    titleRow
                    launcherGrid
                }
            }
            .frame(width: 220)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    NotchTrayStrip(
                        activityCenter: activityCenter,
                        onOpenDesktop: companionManager.openDesktopWindow
                    )

                    if activityCenter.isEnabled(.timer) {
                        timerSection
                    }
                }
            }
            .frame(width: 196)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if activityCenter.isEnabled(.mirror) {
                        NotchCameraMirrorView()
                    }
                    if activityCenter.isEnabled(.shelf) {
                        shelfSection
                    }
                    if activityCenter.isEnabled(.clipboard) {
                        clipboardSection
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var titleRow: some View {
        HStack {
            DSSectionLabel(title: "Micro apps")
            Spacer()
            NotchLinkButton(title: "Manage", systemImage: "arrow.up.forward.app") {
                companionManager.openDesktopWindow(section: .notch)
            }
            .help("Choose micro apps in the HeyMate window")
        }
    }

    private var launcherGrid: some View {
        LazyVGrid(columns: columns, spacing: 5) {
            ForEach(NotchMicroApp.allCases) { microApp in
                let isEnabled = activityCenter.isEnabled(microApp)
                let needsPermission = activityCenter.needsPermissionPrompt(for: microApp)
                Button {
                    // An on-but-unpermitted tile is one tap from working, so
                    // that tap asks macOS rather than turning the app off.
                    if needsPermission {
                        activityCenter.grantPendingPermission(for: microApp)
                    } else {
                        activityCenter.setEnabled(!isEnabled, for: microApp)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: microApp.symbolName)
                            .font(DS.Glyph.small)
                            .foregroundColor(isEnabled ? DS.Colors.accentText : DS.Colors.textTertiary)
                            .frame(width: 16)
                        Text(microApp.compactDisplayName)
                            .font(DS.Fonts.caption)
                            .foregroundColor(isEnabled ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        // The tinted tile already says "on"; the only
                        // extra mark worth its space is "needs permission".
                        if needsPermission {
                            Image(systemName: "lock.fill")
                                .font(DS.Glyph.micro)
                                .foregroundColor(DS.Colors.warningText)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: DS.ControlSize.regular)
                    .dsSurface(
                        isEnabled ? .tinted(DS.Colors.accent) : .row,
                        cornerRadius: DS.CornerRadius.medium
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(microApp.displayName)
                .pointerCursor()
                .help(
                    needsPermission
                        ? "\(microApp.displayName) needs your permission — click to allow"
                        : "Turn \(microApp.displayName) \(isEnabled ? "off" : "on")"
                )
            }
        }
    }

    private var timerSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            DSSectionLabel(title: "Focus timer")
            HStack(spacing: 7) {
                if let runningTimer = timerStore.runningTimer {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(NotchTimerStore.formatted(
                            remainingSeconds: runningTimer.remaining(asOf: context.date)
                        ))
                        .font(DS.Fonts.numericLarge)
                        .foregroundColor(DS.Colors.textPrimary)
                    }
                    Spacer()
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
                    Spacer()
                }
            }
            .padding(10)
            .background(sectionBackground)
        }
    }

    private var shelfSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                DSSectionLabel(title: "File shelf")
                Spacer()
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

            if shelfStore.items.isEmpty {
                Label("Drop files on collapsed notch", systemImage: "arrow.down.doc")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(sectionBackground)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shelfStore.items) { item in
                            shelfItem(item)
                        }
                    }
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

    private func shareShelfViaAirDrop() {
        let fileURLs = shelfStore.items.map(\.fileURL)
        guard !fileURLs.isEmpty else { return }
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: fileURLs)
    }

    private func shelfItem(_ item: NotchShelfStore.ShelfItem) -> some View {
        VStack(spacing: 5) {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "doc")
                        .font(.system(size: 18))
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
            .frame(width: 46, height: 42)
            .background(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous).fill(DS.Colors.surface3))
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))

            Text(item.displayName)
                .font(DS.Fonts.micro)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
                .frame(width: 58)
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

    @ViewBuilder
    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                DSSectionLabel(title: "Clipboard")
                Spacer()
                if !clipboardStore.entries.isEmpty {
                    NotchLinkButton(title: "Clear", color: DS.Colors.textSecondary) {
                        isConfirmingClipboardClear = true
                    }
                }
            }

            if clipboardStore.entries.isEmpty {
                Text("Recent text copies appear here. Concealed and transient items stay excluded.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sectionBackground)
            } else {
                ForEach(clipboardStore.entries) { entry in
                    HStack(spacing: 6) {
                        Button {
                            clipboardStore.copyToPasteboard(entryID: entry.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.on.doc")
                                    .font(DS.Glyph.small)
                                    .foregroundColor(DS.Colors.accentText)
                                Text(entry.preview)
                                    .font(DS.Fonts.caption)
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(minHeight: 24)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .help("Copy again")

                        NotchLinkButton(title: "Remove", color: DS.Colors.textTertiary) {
                            clipboardStore.remove(entryID: entry.id)
                        }
                        .help("Remove from clipboard history")
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 30)
                    .background(sectionBackground)
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

    private func microButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .dsCapsuleButtonStyle(.secondary)
    }

    private var sectionBackground: some View {
        RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
            .fill(DSSurface.row.fill(isHighlighted: false))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .stroke(DSSurface.row.stroke(isHighlighted: false), lineWidth: DSSurface.row.strokeWidth)
            )
    }
}
