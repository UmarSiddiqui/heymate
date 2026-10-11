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

/// Which mates the peek shows: the ones with the newest messages.
nonisolated enum NotchMatesPeekOrder {
    static func mates(
        _ mates: [Mate],
        sessions: [ChatSession],
        defaultMateID: UUID,
        limit: Int = 4
    ) -> [(mate: Mate, preview: MateRailPreview)] {
        mates
            .filter { !$0.archived }
            .map { ($0, MateRailPreview.make(for: $0, sessions: sessions, defaultMateID: defaultMateID)) }
            .sorted { ($0.1.date ?? $0.0.updatedAt) > ($1.1.date ?? $1.0.updatedAt) }
            .prefix(limit)
            .map { (mate: $0.0, preview: $0.1) }
    }
}

struct NotchMatesPeek: View {
    @ObservedObject var companionManager: CompanionManager

    private var rows: [(mate: Mate, preview: MateRailPreview)] {
        NotchMatesPeekOrder.mates(
            companionManager.mates,
            sessions: companionManager.savedChats,
            defaultMateID: companionManager.mateDirectory.defaultMateID
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                DSSectionLabel(title: "Mates")
                Spacer()
                Button("All") {
                    companionManager.openDesktopWindow(section: .chat)
                }
                .buttonStyle(.plain)
                .font(DS.Fonts.caption.weight(.semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .pointerCursor()
                .help("Open all mates")
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.mate.id) { index, row in
                    NotchMatePeekRow(mate: row.mate, preview: row.preview) {
                        companionManager.openMate(id: row.mate.id)
                        companionManager.openDesktopWindow(section: .chat)
                    }
                    if index < rows.count - 1 {
                        Rectangle()
                            .fill(DS.Colors.borderSubtle)
                            .frame(height: 1)
                            .padding(.leading, 46)
                    }
                }
            }
        }
    }
}

private struct NotchMatePeekRow: View {
    let mate: Mate
    let preview: MateRailPreview
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                MateFaceView(mate: mate, size: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(mate.name)
                            .font(DS.Fonts.control)
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let date = preview.date {
                            Text(MateRailPreview.timestamp(date))
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Text(preview.text)
                        .font(DS.Fonts.caption)
                        .foregroundColor(mate.unreadCount > 0 ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        .lineLimit(1)
                }
                NotchFileStack(paths: MateRecentFiles.newest(in: mate.folderPath))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isHovering ? DS.Colors.surface2 : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
        .accessibilityLabel("Open \(mate.name)")
        .accessibilityHint(preview.text)
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
                    .offset(x: index == 0 ? 0 : -8)
            }
        }
        .frame(width: paths.isEmpty ? 0 : 40, height: 38)
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
            .frame(width: 30, height: 36)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .task(id: path) {
                let request = QLThumbnailGenerator.Request(
                    fileAt: URL(fileURLWithPath: path),
                    size: CGSize(width: 30, height: 36),
                    scale: NSScreen.main?.backingScaleFactor ?? 2,
                    representationTypes: .thumbnail
                )
                image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
            }
    }
}
