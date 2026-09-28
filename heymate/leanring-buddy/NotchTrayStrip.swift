//
//  NotchTrayStrip.swift
//  leanring-buddy
//
//  The "Right now" strip inside the expanded notch card: one horizontal
//  row of ambient chips — the track that is playing, the timer counting
//  down, the files on the shelf, the next event. Each chip carries the one
//  control that belongs to it (pause, stop, join). When nothing is live
//  the strip collapses to a single quiet invitation instead of an empty
//  box, because a notch card that is mostly blank space reads as broken
//  rather than calm.
//
//  Anything that needs configuring lives in the HeyMate window. The rule
//  this file follows: the notch is for the current moment, the window is
//  for everything else.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotchTrayStrip: View {
    @ObservedObject var activityCenter: NotchActivityCenter
    @ObservedObject var shelfStore: NotchShelfStore
    @ObservedObject var nowPlayingMonitor: NowPlayingMonitor
    @ObservedObject var timerStore: NotchTimerStore
    @ObservedObject var calendarMonitor: CalendarPeekMonitor
    @ObservedObject var downloadsMonitor: DownloadsActivityMonitor
    @ObservedObject var volumeHUDInterceptor: VolumeHUDInterceptor
    @ObservedObject var brightnessHUDInterceptor: BrightnessHUDInterceptor
    @ObservedObject var bluetoothMonitor: BluetoothActivityMonitor
    @ObservedObject var reminderMonitor: ReminderPeekMonitor

    /// Opens the matching page of the HeyMate window.
    var onOpenDesktop: (DesktopSection) -> Void

    init(activityCenter: NotchActivityCenter, onOpenDesktop: @escaping (DesktopSection) -> Void) {
        self.activityCenter = activityCenter
        self.shelfStore = activityCenter.shelfStore
        self.nowPlayingMonitor = activityCenter.nowPlayingMonitor
        self.timerStore = activityCenter.timerStore
        self.calendarMonitor = activityCenter.calendarMonitor
        self.downloadsMonitor = activityCenter.downloadsMonitor
        self.volumeHUDInterceptor = activityCenter.volumeHUDInterceptor
        self.brightnessHUDInterceptor = activityCenter.brightnessHUDInterceptor
        self.bluetoothMonitor = activityCenter.bluetoothMonitor
        self.reminderMonitor = activityCenter.reminderMonitor
        self.onOpenDesktop = onOpenDesktop
    }

    var body: some View {
        // Nothing live: drop the section entirely rather than spending a
        // header on one placeholder chip. An empty labeled section reads as
        // broken; no section reads as calm.
        if isTrayEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 7) {
                DSSectionLabel(title: "Right now")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        if let nowPlaying = nowPlayingMonitor.nowPlaying, activityCenter.isEnabled(.media) {
                            nowPlayingChip(nowPlaying)
                        }
                        if let runningTimer = timerStore.runningTimer, activityCenter.isEnabled(.timer) {
                            timerChip(runningTimer)
                        }
                        if activityCenter.isEnabled(.shelf), !shelfStore.items.isEmpty {
                            shelfChip
                        }
                        if activityCenter.isEnabled(.calendar), let nextEvent = calendarMonitor.nextEvent {
                            calendarChip(nextEvent)
                        }
                        if activityCenter.isEnabled(.downloads), let download = downloadsMonitor.activity {
                            downloadChip(download)
                        }
                        if activityCenter.isEnabled(.volumeHUD), let volume = volumeHUDInterceptor.activity {
                            volumeChip(volume)
                        }
                        if activityCenter.isEnabled(.brightnessHUD), let brightness = brightnessHUDInterceptor.activity {
                            levelChip(brightness)
                        }
                        if activityCenter.isEnabled(.bluetooth), let deviceEvent = bluetoothMonitor.lastEvent {
                            bluetoothChip(deviceEvent)
                        }
                        if activityCenter.isEnabled(.reminders), let reminder = reminderMonitor.nextReminder {
                            reminderChip(reminder)
                        }
                    }
                }
            }
        }
    }

    private var isTrayEmpty: Bool {
        let hasMedia = activityCenter.isEnabled(.media) && nowPlayingMonitor.nowPlaying != nil
        let hasTimer = activityCenter.isEnabled(.timer) && timerStore.runningTimer != nil
        let hasShelf = activityCenter.isEnabled(.shelf) && !shelfStore.items.isEmpty
        let hasEvent = activityCenter.isEnabled(.calendar) && calendarMonitor.nextEvent != nil
        let hasDownload = activityCenter.isEnabled(.downloads) && downloadsMonitor.activity != nil
        let hasVolume = activityCenter.isEnabled(.volumeHUD) && volumeHUDInterceptor.activity != nil
        let hasBrightness = activityCenter.isEnabled(.brightnessHUD) && brightnessHUDInterceptor.activity != nil
        let hasBluetooth = activityCenter.isEnabled(.bluetooth) && bluetoothMonitor.lastEvent != nil
        let hasReminder = activityCenter.isEnabled(.reminders) && reminderMonitor.nextReminder != nil
        return !(hasMedia || hasTimer || hasShelf || hasEvent || hasDownload || hasVolume
            || hasBrightness || hasBluetooth || hasReminder)
    }

    // MARK: Chips

    private func nowPlayingChip(_ nowPlaying: NowPlayingMonitor.NowPlayingSnapshot) -> some View {
        trayChip {
            HStack(spacing: 8) {
                if let artwork = nowPlayingMonitor.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .accessibilityHidden(true)
                }
                Button(action: { nowPlayingMonitor.togglePlayPause() }) {
                    Image(systemName: "playpause.fill")
                        .font(DS.Glyph.micro)
                        .foregroundColor(DS.Colors.textPrimary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(DS.Colors.surface4))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Play or pause")

                VStack(alignment: .leading, spacing: 1) {
                    Text(nowPlaying.title)
                        .font(DS.Fonts.caption.weight(.semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(nowPlaying.artist.isEmpty ? nowPlaying.appName : nowPlaying.artist)
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
                .fixedSize()

                transportButton("backward.fill", action: { nowPlayingMonitor.skipToPreviousTrack() })
                transportButton("forward.fill", action: { nowPlayingMonitor.skipToNextTrack() })
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height),
                          abs(value.translation.width) >= 46 else { return }
                    if value.translation.width < 0 {
                        nowPlayingMonitor.skipToNextTrack()
                    } else {
                        nowPlayingMonitor.skipToPreviousTrack()
                    }
                }
        )
        .help("Swipe horizontally to change track")
    }

    private func timerChip(_ runningTimer: NotchTimerStore.RunningTimer) -> some View {
        // Re-reads the deadline once a second, and only while a timer is
        // actually on screen. TimelineView is the right tool here precisely
        // because it stops existing when this chip does.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            trayChip {
                HStack(spacing: 7) {
                    Image(systemName: "timer")
                        .font(DS.Glyph.small)
                        .foregroundColor(DS.Colors.accentText)
                    Text(NotchTimerStore.formatted(
                        remainingSeconds: runningTimer.remaining(asOf: context.date)
                    ))
                    .font(DS.Fonts.numeric)
                    .foregroundColor(DS.Colors.textPrimary)
                    Button("Stop") { timerStore.cancel() }
                        .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                }
            }
        }
    }

    private var shelfChip: some View {
        trayChip {
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                    .font(DS.Glyph.small)
                    .foregroundColor(DS.Colors.accentText)
                HStack(spacing: 4) {
                    ForEach(shelfStore.items.prefix(4)) { item in
                        shelfThumbnail(item)
                    }
                }
                if shelfStore.items.count > 4 {
                    Text("+\(shelfStore.items.count - 4)")
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Button {
                    shareShelfViaAirDrop()
                } label: {
                    Image(systemName: "airplayaudio")
                        .font(DS.Glyph.small)
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Share shelf with AirDrop")
                Button("Clear") { shelfStore.removeAll() }
                    .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
            }
        }
    }

    private func shareShelfViaAirDrop() {
        let fileURLs = shelfStore.items.map(\.fileURL)
        guard !fileURLs.isEmpty else { return }
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: fileURLs)
    }

    /// Draggable back out: the shelf is only half a feature if files can go
    /// in but not come back out into another app.
    private func shelfThumbnail(_ item: NotchShelfStore.ShelfItem) -> some View {
        Group {
            if let thumbnail = item.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "doc")
                    .font(DS.Glyph.small)
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
        .frame(width: 24, height: 24)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(DS.Colors.surface3))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .help(item.displayName)
        .pointerCursor()
        .onTapGesture { shelfStore.open(itemID: item.id) }
        .onDrag { NSItemProvider(contentsOf: item.fileURL) ?? NSItemProvider() }
    }

    private func calendarChip(_ nextEvent: CalendarPeekMonitor.UpcomingEvent) -> some View {
        trayChip {
            HStack(spacing: 7) {
                Image(systemName: "calendar")
                    .font(DS.Glyph.small)
                    .foregroundColor(DS.Colors.accentText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(nextEvent.title)
                        .font(DS.Fonts.caption.weight(.semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(nextEvent.startDate.formatted(date: .omitted, time: .shortened))
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .fixedSize()
                if let joinURL = nextEvent.joinURL {
                    Button("Join") { NSWorkspace.shared.open(joinURL) }
                        .dsCapsuleButtonStyle(.primary, height: DS.ControlSize.small)
                }
            }
        }
    }

    private func downloadChip(_ download: NotchActivity) -> some View {
        trayChip {
            HStack(spacing: 7) {
                Image(systemName: download.progress == 1 ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(DS.Glyph.small)
                    .foregroundColor(download.progress == 1 ? DS.Colors.success : DS.Colors.accentText)
                Text(download.trailingText)
                    .font(DS.Fonts.caption.weight(.semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Button("Show") {
                    NSWorkspace.shared.open(
                        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                            ?? FileManager.default.homeDirectoryForCurrentUser
                    )
                }
                .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
            }
        }
    }

    private func volumeChip(_ volume: NotchActivity) -> some View {
        trayChip {
            HStack(spacing: 7) {
                Image(systemName: volume.progress == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(DS.Glyph.small)
                    .foregroundColor(DS.Colors.accentText)
                Text(volume.trailingText)
                    .font(DS.Fonts.numeric)
                    .foregroundColor(DS.Colors.textPrimary)
            }
        }
    }

    /// Display brightness or keyboard backlight, whichever key was pressed.
    private func levelChip(_ level: NotchActivity) -> some View {
        trayChip {
            HStack(spacing: 7) {
                Image(systemName: level.symbolName)
                    .font(DS.Glyph.small)
                    .foregroundColor(DS.Colors.accentText)
                Text(level.trailingText)
                    .font(DS.Fonts.numeric)
                    .foregroundColor(DS.Colors.textPrimary)
            }
        }
    }

    private func bluetoothChip(_ deviceEvent: BluetoothActivityMonitor.DeviceEvent) -> some View {
        trayChip {
            HStack(spacing: 7) {
                Image(systemName: deviceEvent.symbolName)
                    .font(DS.Glyph.small)
                    .foregroundColor(deviceEvent.isConnected ? DS.Colors.accentText : DS.Colors.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(deviceEvent.deviceName)
                        .font(DS.Fonts.caption.weight(.semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(deviceEvent.isConnected ? "Connected" : "Disconnected")
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .fixedSize()
            }
        }
    }

    private func reminderChip(_ reminder: ReminderPeekMonitor.DueReminder) -> some View {
        trayChip {
            HStack(spacing: 7) {
                Image(systemName: reminder.isOverdue ? "exclamationmark.circle.fill" : "checklist")
                    .font(DS.Glyph.small)
                    .foregroundColor(reminder.isOverdue ? DS.Colors.warning : DS.Colors.accentText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(reminder.title)
                        .font(DS.Fonts.caption.weight(.semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(reminder.isOverdue ? "Overdue" : reminder.dueDate.formatted(date: .omitted, time: .shortened))
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .fixedSize()
                Button("Done") { reminderMonitor.completeNextReminder() }
                    .dsCapsuleButtonStyle(.primary, height: DS.ControlSize.small)
            }
        }
    }

    // MARK: Chip scaffold

    private func trayChip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: 34)
            .background(
                Capsule(style: .continuous)
                    .fill(DS.Colors.surface2.opacity(0.72))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
            .fixedSize()
    }

    private func transportButton(_ symbolName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(DS.Glyph.micro)
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(DS.Colors.surface4))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
