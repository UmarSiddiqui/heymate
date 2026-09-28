//
//  DesktopChatControls.swift
//  leanring-buddy
//
//  Desktop-only chat chrome. Compact notch chat keeps one-line controls.
//

import SwiftUI

struct DesktopChatHeader: View {
    @ObservedObject var companionManager: CompanionManager
    @Binding var isShowingHistory: Bool
    @Binding var isShowingInspector: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isShowingHistory ? "History" : companionManager.currentChat.title)
                    .font(DS.Fonts.title)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text("\(companionManager.selectedBrain.displayName) · \(companionManager.notchDockModelLabel)")
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isShowingHistory.toggle() }
            } label: {
                Image(systemName: isShowingHistory ? "bubble.left.and.bubble.right" : "clock.arrow.circlepath")
                    .font(DS.Glyph.regular)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 5).fill(DS.Colors.surface2.opacity(0.56)))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointerCursor()
            .help(isShowingHistory ? "Back to chat" : "Past chats")

            Button {
                companionManager.startNewChat()
                isShowingHistory = false
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(DS.Glyph.regular)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 5).fill(DS.Colors.surface2.opacity(0.56)))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointerCursor()
            .help("New chat")
            .keyboardShortcut("n", modifiers: .command)

            Button {
                withAnimation(.easeInOut(duration: 0.16)) { isShowingInspector.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(DS.Glyph.regular)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isShowingInspector ? DS.Colors.surface3 : DS.Colors.surface2.opacity(0.56))
                    )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointerCursor()
            .help(isShowingInspector ? "Hide context pane" : "Show context pane")
        }
        .foregroundColor(DS.Colors.textSecondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(DS.Colors.surface1.opacity(0.38))
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1)
        }
    }
}

struct DesktopChatControlLabel: View {
    let symbolName: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .font(DS.Glyph.small)
                .foregroundColor(DS.Colors.accentText)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(DS.Glyph.micro)
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 31)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DS.Colors.surface2.opacity(0.72))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.7)
                }
        }
    }
}

struct DesktopConnectorScopeMenu: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var connectorStore: ConnectorStore
    @ObservedObject private var composioConnections: ComposioConnectionsRuntime
    private let compact: Bool

    init(companionManager: CompanionManager, compact: Bool = false) {
        self.companionManager = companionManager
        self.connectorStore = companionManager.connectorStore
        self.composioConnections = companionManager.composioConnections
        self.compact = compact
    }

    var body: some View {
        Menu {
            if connectedItems.isEmpty {
                Text("No connected apps")
            } else {
                Section("Use in this chat") {
                    ForEach(connectedItems, id: \.id) { item in
                        Button {
                            companionManager.setChatConnectorEnabled(
                                !companionManager.isChatConnectorEnabled(item.id),
                                selectionID: item.id
                            )
                        } label: {
                            Label(
                                item.name,
                                systemImage: companionManager.isChatConnectorEnabled(item.id)
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                        }
                    }
                }
            }

            Divider()
            Button("Manage tools…") {
                companionManager.openDesktopWindow(section: .connectors)
            }
        } label: {
            if compact {
                HStack(spacing: 5) {
                    Image(systemName: "app.connected.to.app.below.fill")
                        .font(DS.Glyph.small)
                    Text(enabledCount == 1 ? "1 connector" : "\(enabledCount) connectors")
                        .font(DS.Fonts.micro)
                    Image(systemName: "chevron.down")
                        .font(DS.Glyph.micro)
                }
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(DS.Colors.surface2.opacity(0.62)))
            } else {
                DesktopChatControlLabel(
                    symbolName: "app.connected.to.app.below.fill",
                    title: enabledCount == 1 ? "1 app" : "\(enabledCount) apps",
                    detail: "Connectors"
                )
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose connected apps available to this chat")
    }

    private var connectedItems: [(id: String, name: String)] {
        let catalogItems = connectorStore.activeConnectors
            .filter { $0.id != ComposioSessionStore.connectorID }
            .map {
                (
                    id: CompanionManager.chatConnectorSelectionID(forConnectorID: $0.id),
                    name: $0.displayName
                )
            }
        let composioItems = composioConnections.connectedSlugs.map { slug in
            let name = composioConnections.records[slug]?.displayName ?? slug
            return (
                id: CompanionManager.chatConnectorSelectionID(forComposioSlug: slug),
                name: name
            )
        }
        return (catalogItems + composioItems).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var enabledCount: Int {
        connectedItems.filter { companionManager.isChatConnectorEnabled($0.id) }.count
    }
}

struct DesktopComposerModelButton: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var isShowingModelPicker = false

    var body: some View {
        Button { isShowingModelPicker.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                    .font(DS.Glyph.small)
                Text(companionManager.notchDockModelLabel)
                    .font(DS.Fonts.micro)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(DS.Glyph.micro)
            }
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(DS.Colors.surface2.opacity(0.62)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Choose engine, model, and reasoning effort")
        .popover(isPresented: $isShowingModelPicker, arrowEdge: .bottom) {
            NotchModelPickerPanel(companionManager: companionManager)
                .frame(width: 430, height: 390)
                .padding(10)
                .background(DS.Colors.background)
        }
    }
}

struct DesktopChatInspector: View {
    @ObservedObject var companionManager: CompanionManager
    let attachmentCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CONTEXT")
                    .font(DS.Fonts.keycap)
                    .tracking(1.2)
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                Image(systemName: "sidebar.right")
                    .font(DS.Glyph.small)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 13)
            .frame(height: 38)

            Divider().overlay(DS.Colors.borderSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    inspectorSection("MODEL") {
                        Label(companionManager.notchDockModelLabel, systemImage: "cpu")
                        Text(companionManager.selectedBrain.displayName)
                            .foregroundColor(DS.Colors.textTertiary)
                    }

                    inspectorSection("TOOLS") {
                        let active = companionManager.composioConnections.connectedSlugs
                        if active.isEmpty {
                            Text("No connected apps")
                                .foregroundColor(DS.Colors.textTertiary)
                        } else {
                            ForEach(active.prefix(6), id: \.self) { slug in
                                Label(
                                    companionManager.composioConnections.records[slug]?.displayName ?? slug,
                                    systemImage: slug == "youtube" ? "play.rectangle.fill" : "link"
                                )
                            }
                        }
                    }

                    inspectorSection("ATTACHMENTS") {
                        Label(
                            attachmentCount == 1 ? "1 image ready" : "\(attachmentCount) images ready",
                            systemImage: "photo.on.rectangle"
                        )
                        .foregroundColor(attachmentCount == 0 ? DS.Colors.textTertiary : DS.Colors.textSecondary)
                    }

                    Button("Manage tools…") {
                        companionManager.openDesktopWindow(section: .connectors)
                    }
                    .buttonStyle(.plain)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.accentText)
                    .pointerCursor()
                }
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 220)
        .background(DS.Colors.surface1.opacity(0.50))
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(DS.Fonts.keycap)
                .tracking(1.0)
                .foregroundColor(DS.Colors.textTertiary)
            VStack(alignment: .leading, spacing: 6) { content() }
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
        CelestialAtmosphere()
    }
}
