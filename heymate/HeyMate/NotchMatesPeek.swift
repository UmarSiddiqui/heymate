//
//  NotchMatesPeek.swift
//  HeyMate
//
//  The notch's quick look at your mates: who said something last, what
//  they said, and the newest files they made, so a hover answers "what did
//  my mates do?" without opening the window.
//

import AppKit
import QuickLookThumbnailing
import SwiftUI

/// The newest files in a mate's folder, newest first.
nonisolated enum MateRecentFiles {
    static func newest(in folderPath: String?, limit: Int = 2) -> [String] {
        guard let folderPath else { return [] }
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .compactMap { url -> (String, Date)? in
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true else { return nil }
                return (url.path, values?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}

/// Which mates the peek shows: the ones waiting on the person first, in
/// the order given, then the ones with the newest messages.
nonisolated enum NotchMatesPeekOrder {
    static func mates(
        _ mates: [Mate],
        sessions: [ChatSession],
        defaultMateID: UUID,
        waitingFirst: [UUID] = [],
        limit: Int = 4
    ) -> [(mate: Mate, preview: MateRailPreview)] {
        func rank(_ id: UUID) -> Int { waitingFirst.firstIndex(of: id) ?? Int.max }
        return mates
            .filter { !$0.archived }
            .map { ($0, MateRailPreview.make(for: $0, sessions: sessions, defaultMateID: defaultMateID)) }
            .sorted { left, right in
                let leftRank = rank(left.0.id), rightRank = rank(right.0.id)
                if leftRank != rightRank { return leftRank < rightRank }
                return (left.1.date ?? left.0.updatedAt) > (right.1.date ?? right.0.updatedAt)
            }
            .prefix(limit)
            .map { (mate: $0.0, preview: $0.1) }
    }
}

struct NotchMatesPeek: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var inbox = MateInboxStore.shared
    /// The notch only shows rows that fit in full. "All" opens the rest.
    var availableHeight: CGFloat = .infinity

    private static let headerHeight: CGFloat = 20
    private static let rowHeight: CGFloat = 36

    private var rowLimit: Int {
        (0...2).last { count in
            Self.headerHeight + 2 + CGFloat(count) * Self.rowHeight + CGFloat(max(0, count - 1)) <= availableHeight
        } ?? 0
    }

    /// Jobs to approve, stopped routines and heartbeat proposals. Unread replies already read as
    /// bright text in the row, so they do not reorder the peek.
    private var waiting: [MateDigestItem] {
        MateDigest.make(
            mates: companionManager.mates,
            routines: companionManager.routines,
            runs: companionManager.agentRuns,
            owners: companionManager.mateRunOwners,
            sessions: companionManager.savedChats,
            defaultMateID: companionManager.mateDirectory.defaultMateID,
            activeMateID: nil,
            includesUnread: false,
            proposals: inbox.pendingItems.filter { $0.proposal != nil },
            inboxItems: inbox.pendingItems
        ).items
    }

    private func rows(waiting: [MateDigestItem]) -> [(mate: Mate, preview: MateRailPreview)] {
        NotchMatesPeekOrder.mates(
            companionManager.mates,
            sessions: companionManager.savedChats,
            defaultMateID: companionManager.mateDirectory.defaultMateID,
            waitingFirst: waiting.map(\.mateID),
            limit: rowLimit
        )
    }

    var body: some View {
        let waiting = waiting
        let rows = rows(waiting: waiting)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                DSSectionLabel(title: "Mates")
                Spacer()
                Button("All") {
                    UserDefaults.standard.set(MateRailTab.mates.rawValue, forKey: MateRailTab.storageKey)
                    companionManager.openDesktopWindow(section: .chat)
                }
                .buttonStyle(.plain)
                .font(DS.Fonts.caption.weight(.semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .pointerCursor()
                .help("Open all mates")
            }
            .frame(height: Self.headerHeight)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.mate.id) { index, row in
                    let attention = waiting.first { $0.mateID == row.mate.id }
                    NotchMatePeekRow(mate: row.mate, preview: row.preview, waiting: attention) {
                        let activeID = companionManager.activeMateID ?? companionManager.mateDirectory.defaultMateID
                        if activeID != row.mate.id {
                            companionManager.openMate(id: row.mate.id)
                        }
                        companionManager.requestedMateAttention = attention
                        companionManager.openDesktopWindow(section: .chat)
                    }
                    .frame(height: Self.rowHeight)
                    if index < rows.count - 1 {
                        Rectangle()
                            .fill(DS.Colors.borderSubtle)
                            .frame(height: 1)
                            .padding(.leading, DS.ControlSize.regular + DS.Spacing.lg)
                    }
                }
            }
        }
    }
}

private struct NotchMatePeekRow: View {
    let mate: Mate
    let preview: MateRailPreview
    /// Set when this agent is blocked on the person.
    var waiting: MateDigestItem? = nil
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.sm + 2) {
                MateFaceView(mate: mate, size: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(mate.name)
                            .font(DS.Fonts.control)
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let waiting {
                            Text("Needs you")
                                .font(DS.Fonts.caption.weight(.semibold))
                                .foregroundColor(
                                    waiting.kind == .routineStopped ? DS.Colors.destructiveText : DS.Colors.warningText
                                )
                                .lineLimit(1)
                                .layoutPriority(1)
                        } else if let date = preview.date {
                            Text(MateRailPreview.timestamp(date))
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Text(waiting?.detail ?? preview.text)
                        .font(DS.Fonts.caption)
                        .foregroundColor(
                            waiting != nil || mate.unreadCount > 0 ? DS.Colors.textPrimary : DS.Colors.textSecondary
                        )
                        .lineLimit(1)
                }
                if waiting == nil {
                    NotchFileStack(paths: MateRecentFiles.newest(in: mate.folderPath))
                }
            }
            .padding(.horizontal, DS.Spacing.xs + 2)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isHovering ? DS.Colors.surface2 : Color.clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                    .strokeBorder(isFocused ? DS.Colors.focusRing : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($isFocused)
        .pointerCursor()
        .onHover { isHovering = $0 }
        .accessibilityLabel(waiting == nil ? "Open \(mate.name)" : "Review what \(mate.name) needs")
        .accessibilityHint(waiting?.detail ?? preview.text)
    }
}

/// Up to two document thumbnails, fanned like a small stack of pages.
private struct NotchFileStack: View {
    let paths: [String]

    var body: some View {
        ZStack {
            ForEach(Array(paths.enumerated().reversed()), id: \.element) { index, path in
                NotchFileThumbnail(path: path)
                    .rotationEffect(.degrees(index == 0 ? 0 : -8))
                    .offset(x: index == 0 ? 0 : -7)
            }
        }
        .frame(width: paths.isEmpty ? 0 : 34, height: 32)
        .accessibilityHidden(true)
    }
}

private struct NotchFileThumbnail: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.white)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "doc.text")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5))
            .frame(width: 24, height: 29)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .task(id: path) {
                let request = QLThumbnailGenerator.Request(
                    fileAt: URL(fileURLWithPath: path),
                    size: CGSize(width: 24, height: 29),
                    scale: NSScreen.main?.backingScaleFactor ?? 2,
                    representationTypes: .thumbnail
                )
                image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            }
    }
}
