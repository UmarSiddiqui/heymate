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

    /// Opens the matching page of the HeyMate window.
    var onOpenDesktop: (DesktopSection) -> Void

    init(activityCenter: NotchActivityCenter, onOpenDesktop: @escaping (DesktopSection) -> Void) {
        self.activityCenter = activityCenter
        self.shelfStore = activityCenter.shelfStore
        self.nowPlayingMonitor = activityCenter.nowPlayingMonitor
        self.timerStore = activityCenter.timerStore
        self.calendarMonitor = activityCenter.calendarMonitor
        self.onOpenDesktop = onOpenDesktop
    }

    var body: some View {
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
                    if isTrayEmpty {
                        emptyChip
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
        return !(hasMedia || hasTimer || hasShelf || hasEvent)
    }

    // MARK: Chips

    private func nowPlayingChip(_ nowPlaying: NowPlayingMonitor.NowPlayingSnapshot) -> some View {
        trayChip {
            HStack(spacing: 8) {
                Button(action: { nowPlayingMonitor.togglePlayPause() }) {
                    Image(systemName: "playpause.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(DS.Colors.surface4))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Play or pause")

                VStack(alignment: .leading, spacing: 1) {
                    Text(nowPlaying.title)
                        .font(.system(size: 11, weight: .semibold))
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
    }

    private func timerChip(_ runningTimer: NotchTimerStore.RunningTimer) -> some View {
        // Re-reads the deadline once a second, and only while a timer is
        // actually on screen. TimelineView is the right tool here precisely
        // because it stops existing when this chip does.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            trayChip {
                HStack(spacing: 7) {
                    Image(systemName: "timer")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.accentText)
                    Text(NotchTimerStore.formatted(
                        remainingSeconds: runningTimer.remaining(asOf: context.date)
                    ))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(DS.Colors.textPrimary)
                    Button("Stop") { timerStore.cancel() }
                        .buttonStyle(.plain)
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textSecondary)
                        .pointerCursor()
                }
            }
        }
    }

    private var shelfChip: some View {
        trayChip {
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                    .font(.system(size: 11, weight: .medium))
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
                Button("Clear") { shelfStore.removeAll() }
                    .buttonStyle(.plain)
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textSecondary)
                    .pointerCursor()
            }
        }
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
                    .font(.system(size: 9))
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
        .frame(width: 18, height: 18)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(DS.Colors.surface3))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .help(item.displayName)
        .pointerCursor()
        .onTapGesture { shelfStore.open(itemID: item.id) }
        .onDrag { NSItemProvider(contentsOf: item.fileURL) ?? NSItemProvider() }
    }

    private func calendarChip(_ nextEvent: CalendarPeekMonitor.UpcomingEvent) -> some View {
        trayChip {
            HStack(spacing: 7) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.accentText)
                VStack(alignment: .leading, spacing: 1) {
                    Text(nextEvent.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(nextEvent.startDate.formatted(date: .omitted, time: .shortened))
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .fixedSize()
                if let joinURL = nextEvent.joinURL {
                    Button("Join") { NSWorkspace.shared.open(joinURL) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(DS.Colors.accent))
                        .pointerCursor()
                }
            }
        }
    }

    private var emptyChip: some View {
        Button(action: { onOpenDesktop(.notch) }) {
            HStack(spacing: 7) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                Text("Drag a file onto the notch, or set up the tray")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(DS.Colors.surface2.opacity(0.72))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Choose which micro-apps live in the notch")
    }

    // MARK: Chip scaffold

    private func trayChip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
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
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(DS.Colors.surface4))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
