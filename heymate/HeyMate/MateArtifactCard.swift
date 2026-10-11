//
//  MateArtifactCard.swift
//  HeyMate
//
//  A file a mate made, shown as a small card with a real thumbnail of the
//  document, so a mate's profile reads as "what it has made for you"
//  rather than a list of file names.
//

import AppKit
import QuickLookThumbnailing
import SwiftUI

struct MateArtifactCard: View {
    let path: String
    let name: String
    let isDirectory: Bool
    var onOpen: () -> Void
    var onDelete: (() -> Void)?

    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    private static let thumbnailSize = CGSize(width: 108, height: 84)

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(DS.Colors.surface3.opacity(0.6))
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(6)
                    } else {
                        Image(systemName: isDirectory ? "folder" : "doc.text")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
                .frame(height: Self.thumbnailSize.height)

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(DS.Fonts.caption.weight(.semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(kindLabel)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isHovering ? DS.Colors.surface3 : DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
        .help(name)
        .accessibilityLabel("\(name), \(kindLabel)")
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            if let onDelete, !isDirectory {
                Divider()
                Button("Move to Trash", role: .destructive, action: onDelete)
            }
        }
        .task(id: path) { await loadThumbnail() }
    }

    private var kindLabel: String {
        if isDirectory { return "Folder" }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "File" : ext.uppercased()
    }

    private func loadThumbnail() async {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: Self.thumbnailSize,
            scale: scale,
            representationTypes: .thumbnail
        )
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            thumbnail = representation.nsImage
        } else {
            thumbnail = nil
        }
    }
}
