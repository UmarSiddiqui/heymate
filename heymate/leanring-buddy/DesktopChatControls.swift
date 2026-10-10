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

/// The pill used for composer pickers (model, apps): one height, one
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

struct DesktopConnectorScopeMenu: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var connectorStore: ConnectorStore
    @ObservedObject private var composioConnections: ComposioConnectionsRuntime
    private let compact: Bool
    /// Narrow composers (the notch) drop the word and keep icon and count.
    private let isNarrow: Bool

    init(companionManager: CompanionManager, compact: Bool = false, isNarrow: Bool = false) {
        self.companionManager = companionManager
        self.connectorStore = companionManager.connectorStore
        self.composioConnections = companionManager.composioConnections
        self.compact = compact
        self.isNarrow = isNarrow
    }

    @State private var isShowingPicker = false

    var body: some View {
        if compact {
            compactPicker
        } else {
            menu
        }
    }

    /// A popover rather than a menu: a menu closes after every click, so
    /// turning three apps off took three trips.
    private var compactPicker: some View {
        Button { isShowingPicker.toggle() } label: {
            ComposerChipLabel(
                symbolName: "app.connected.to.app.below.fill",
                title: isNarrow ? (enabledCount > 0 ? "\(enabledCount)" : "") : compactTitle,
                isHighlighted: isShowingPicker || enabledCount > 0
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Choose which connected apps this chat can use")
        .accessibilityLabel("Apps for this chat: \(compactTitle)")
        .popover(isPresented: $isShowingPicker, arrowEdge: .top) {
            ConnectorScopePickerPanel(
                items: connectedItems,
                isEnabled: { companionManager.isChatConnectorEnabled($0) },
                setEnabled: { companionManager.setChatConnectorEnabled($1, selectionID: $0) },
                manage: {
                    isShowingPicker = false
                    companionManager.openDesktopWindow(section: .connectors)
                }
            )
        }
    }

    private var menu: some View {
        Menu {
            if connectedItems.isEmpty {
                Text("No connected apps")
            } else {
                Section("Use in this chat") {
                    // Toggles, so the menu shows a native checkmark for each
                    // app that's on; Label images don't render in macOS menus.
                    ForEach(connectedItems, id: \.id) { item in
                        Toggle(item.name, isOn: Binding(
                            get: { companionManager.isChatConnectorEnabled(item.id) },
                            set: { companionManager.setChatConnectorEnabled($0, selectionID: item.id) }
                        ))
                    }
                }
            }

            Divider()
            Button(connectedItems.isEmpty ? "Connect apps…" : "Manage apps…") {
                companionManager.openDesktopWindow(section: .connectors)
            }
        } label: {
            DesktopChatControlLabel(
                symbolName: "app.connected.to.app.below.fill",
                title: enabledCount == 1 ? "1 app" : "\(enabledCount) apps",
                detail: "Connectors"
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which connected apps this chat can use")
    }

    /// "Apps · 3" when some are on, "Apps" when none, so the chip always
    /// says what it is rather than only a count.
    private var compactTitle: String {
        if connectedItems.isEmpty { return "Connect apps" }
        return enabledCount == 0 ? "Apps" : "Apps · \(enabledCount)"
    }

    private var connectedItems: [(id: String, name: String, logoSlug: String)] {
        let catalogItems = connectorStore.activeConnectors
            .filter { $0.id != ComposioSessionStore.connectorID }
            .map {
                (
                    id: CompanionManager.chatConnectorSelectionID(forConnectorID: $0.id),
                    name: $0.displayName,
                    logoSlug: $0.id.lowercased()
                )
            }
        let composioItems = composioConnections.connectedSlugs.map { slug in
            let name = Self.readableName(composioConnections.records[slug]?.displayName ?? slug, slug: slug)
            return (
                id: CompanionManager.chatConnectorSelectionID(forComposioSlug: slug),
                name: name,
                logoSlug: slug
            )
        }
        return (catalogItems + composioItems).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Some connections were saved with their slug as the name
    /// ("googlecalendar"). Show those the way people write them.
    static func readableName(_ name: String, slug: String) -> String {
        guard name.caseInsensitiveCompare(slug) == .orderedSame else { return name }
        let known: [String: String] = [
            "github": "GitHub", "gitlab": "GitLab", "gmail": "Gmail",
            "googlecalendar": "Google Calendar", "googledrive": "Google Drive",
            "googledocs": "Google Docs", "googlesheets": "Google Sheets",
            "youtube": "YouTube", "linkedin": "LinkedIn", "hubspot": "HubSpot",
            "clickup": "ClickUp", "whatsapp": "WhatsApp"
        ]
        if let readable = known[slug.lowercased()] { return readable }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private var enabledCount: Int {
        connectedItems.filter { companionManager.isChatConnectorEnabled($0.id) }.count
    }
}

/// The list behind the composer's Apps chip: a switch per connected app,
/// and a way to connect more. Stays open while you flip several.
private struct ConnectorScopePickerPanel: View {
    let items: [(id: String, name: String, logoSlug: String)]
    let isEnabled: (String) -> Bool
    let setEnabled: (String, Bool) -> Void
    let manage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Apps in this chat")
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer(minLength: 12)
                if items.count > 1 {
                    let allOn = items.allSatisfy { isEnabled($0.id) }
                    Button(allOn ? "Turn all off" : "Turn all on") {
                        for item in items { setEnabled(item.id, !allOn) }
                    }
                    .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                    .focusEffectDisabled()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if items.isEmpty {
                Text("No apps connected yet. Connect Gmail, Slack, GitHub and more, then pick which ones each chat can use.")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(items, id: \.id) { item in
                            Toggle(isOn: Binding(
                                get: { isEnabled(item.id) },
                                set: { setEnabled(item.id, $0) }
                            )) {
                                HStack(spacing: 10) {
                                    ComposioToolkitLogoView(
                                        toolkit: .logoOnly(slug: item.logoSlug, name: item.name),
                                        compactSize: 22
                                    )
                                    Text(item.name)
                                        .font(DS.Fonts.bodyLarge)
                                        .foregroundColor(DS.Colors.textPrimary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                        }
                    }
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Button(items.isEmpty ? "Connect apps…" : "Manage apps…", action: manage)
                .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                .padding(10)
        }
        .frame(width: 280)
    }
}

struct DesktopComposerModelButton: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var isShowingModelPicker = false

    var body: some View {
        Button { isShowingModelPicker.toggle() } label: {
            ComposerChipLabel(
                symbolName: "cpu",
                title: companionManager.notchDockModelLabel,
                isHighlighted: isShowingModelPicker,
                brand: companionManager.selectedBrain
            )
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
