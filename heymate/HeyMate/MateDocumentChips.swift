//
//  MateDocumentChips.swift
//  HeyMate
//
//  Document attachments as chips: removable in the composer, read-only on a
//  sent message. The files themselves are already in the mate's inbox/.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MateDocumentChip: View {
    let name: String
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (name as NSString).pathExtension) ?? .data))
                .resizable()
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
            Text(name)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark").font(DS.Glyph.micro).dsIconHitArea(16)
                }
                .buttonStyle(.plain)
                .foregroundColor(DS.Colors.textTertiary)
                .help("Remove from message")
                .accessibilityLabel("Remove \(name) from message")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(DS.Colors.surface3))
        .overlay(Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attached file \(name)")
    }
}

struct MateDocumentChipStrip: View {
    let documents: [MateChatDocument]
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(documents) { document in
                    MateDocumentChip(name: document.name) { remove(document.id) }
                }
            }
        }
    }
}
