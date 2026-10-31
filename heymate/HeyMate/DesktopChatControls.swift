//
//  DesktopChatControls.swift
//  HeyMate
//
//  Desktop-only chat chrome. Compact notch chat keeps one-line controls.
//

import SwiftUI

/// The pill used for composer pickers (model): one height, one
/// shape, a hover fill, and the whole pill clickable.
struct ComposerChipLabel: View {
    let symbolName: String
    let title: String
    var isHighlighted = false
    /// An engine whose logo replaces `symbolName`.
    var brand: AgentBrain?

    @State private var isHovered = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let brand {
                AgentBrandMark(brain: brand, size: 14)
            } else {
                Image(systemName: symbolName)
                    .font(DS.Glyph.small)
            }
            if !title.isEmpty {
                Text(title)
                    .font(DS.Fonts.caption)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(DS.Glyph.micro)
                .foregroundColor(DS.Colors.textTertiary)
        }
        .foregroundColor(isHovered || isHighlighted ? DS.Colors.textPrimary : DS.Colors.textSecondary)
        .padding(.horizontal, 10)
        .frame(height: DS.ControlSize.regular)
        .background(shape.fill(isHovered ? DS.Colors.surface3 : DS.Colors.surface2))
        .contentShape(shape)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
    }
}

struct DesktopComposerModelButton: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var brain = MateAgentSetupController.shared
    @State private var isShowingModelPicker = false

    var body: some View {
        Button { isShowingModelPicker.toggle() } label: {
            ComposerChipLabel(
                symbolName: "cpu",
                title: brain.currentModel.isEmpty ? "Choose a brain"
                    : "\(brain.currentModelName) · \(MateAgentSetupPane.effortName(brain.currentEffort))",
                isHighlighted: isShowingModelPicker,
                brand: BrainQuickPicker.brand(for: brain.currentProvider)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Subscription, model and effort")
        .disclosureSound(isShowingModelPicker, .popover)
        .popover(isPresented: $isShowingModelPicker, arrowEdge: .bottom) {
            BrainQuickPicker(companionManager: companionManager)
                .frame(width: 340)
                .background(DS.Colors.background)
        }
    }
}

struct ChatAttachmentPreviewStrip: View {
    let attachments: [ChatImageAttachment]
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let image = attachment.thumbnail {
                                Image(nsImage: image).resizable().scaledToFill()
                            } else {
                                Image(systemName: "photo").foregroundColor(DS.Colors.textTertiary)
                            }
                        }
                        .frame(width: 72, height: 54)
                        .background(DS.Colors.surface3)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                        }

                        Button { remove(attachment.id) } label: {
                            Image(systemName: "xmark")
                                .font(DS.Glyph.micro)
                                .foregroundColor(.white)
                                .frame(width: 17, height: 17)
                                .background(Circle().fill(Color.black.opacity(0.72)))
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .offset(x: 5, y: -5)
                    }
                    .help(attachment.fileName)
                }
            }
            .padding(.top, 5)
            .padding(.trailing, 5)
        }
        .frame(height: 64)
    }
}

/// Sidebar fill: one step above the workspace so the split reads without
/// a hard divider.
struct CelestialSidebarBackground: View {
    let accent: Color

    var body: some View {
        DS.Colors.surface1
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// Workspace fill: the matte window background.
struct CelestialWorkspaceBackground: View {
    let accent: Color

    var body: some View {
        WorkspaceBackground().ignoresSafeArea()
    }
}
