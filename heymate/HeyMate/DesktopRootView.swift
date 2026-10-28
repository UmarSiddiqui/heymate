//
//  DesktopRootView.swift
//  HeyMate
//
//  The HeyMate desktop window's content: a standard macOS sidebar app.
//
//  Division of labor between the two surfaces:
//    • the notch handles what should be glanceable and ambient — state,
//      one live activity, a quick chat, a running job;
//    • this window handles what needs room and attention — chat with the
//      mates, the apps HeyMate can reach, and settings.
//
//  The sidebar is deliberately three items: Chat, Apps, Settings. Jobs are
//  reached from the chat (each mate's own work), skills and memory from a
//  mate's sheet, and Notch Apps and Privacy are Settings sections. The
//  other `DesktopSection` cases stay so deep links keep working.
//
//  Outside chat the sidebar is always the Settings section rail (with Back
//  to chat and Integrations on top), so Integrations and Settings read as
//  one place and there is never a second sidebar inside the page.
//
//  Everything here is a view onto the same `CompanionManager`. There is no
//  second state store and no syncing, which is why changing a setting in
//  the window is reflected in the notch before the sheet finishes closing.
//

import AppKit
import SwiftUI

// MARK: - Sections

enum DesktopSection: String, CaseIterable, Identifiable, Hashable {
    case chat
    case connectors
    case notes
    case notch
    case skills
    case memory
    case privacy
    case settings

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chat: return "Chat"
        case .connectors: return "Integrations"
        case .notes: return "Notes"
        case .notch: return "Notch Apps"
        case .skills: return "Skills"
        case .memory: return "Memory"
        case .privacy: return "Privacy"
        case .settings: return "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .connectors: return "puzzlepiece.extension"
        case .notes: return "doc.on.doc"
        case .notch: return "rectangle.topthird.inset.filled"
        case .skills: return "wand.and.stars"
        case .memory: return "brain"
        case .privacy: return "hand.raised"
        case .settings: return "gearshape"
        }
    }

    /// What the sidebar lists under "Back to chat". Everything else is
    /// reached from inside chat or Settings.
    static let sidebarSections: [DesktopSection] = [.connectors, .notes, .settings]

    /// The `@AppStorage` key Settings reads to pick its section.
    static let settingsTabDefaultsKey = DesktopSettingsTab.storageKey

    /// Notch Apps and Privacy live inside Settings now. A deep link to one
    /// of them lands on Settings, on that tab.
    var settingsTab: String? {
        switch self {
        case .notch: return DesktopSettingsTab.notch.rawValue
        case .privacy: return DesktopSettingsTab.privacy.rawValue
        default: return nil
        }
    }

    /// Where a request for this section actually lands in the window.
    var landingSection: DesktopSection {
        settingsTab == nil ? self : .settings
    }

    /// Pages that still open by deep link but aren't in the sidebar, so
    /// they carry their own way back to chat.
    var isOffSidebarPage: Bool {
        self != .chat && !Self.sidebarSections.contains(landingSection)
    }

    /// Opens Settings on one tab from anywhere inside the desktop window.
    static func openSettings(tab: String) {
        // Integrations used to have a Settings page too; it is one page now.
        if DesktopSettingsTab.movedToIntegrations.contains(tab) {
            NotificationCenter.default.post(
                name: .heyMateDesktopSelectSection,
                object: nil,
                userInfo: ["section": DesktopSection.connectors.rawValue]
            )
            return
        }
        UserDefaults.standard.set(tab, forKey: settingsTabDefaultsKey)
        NotificationCenter.default.post(
            name: .heyMateDesktopSelectSection,
            object: nil,
            userInfo: ["section": DesktopSection.settings.rawValue]
        )
    }
}

// MARK: - Root

struct DesktopRootView: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var selectedSection: DesktopSection
    @AppStorage(QuietPolicy.presentationModeKey) private var presentationMode = false
    @StateObject private var suggestionMemory = WorkSuggestionMemory()
    @State private var showsSuggestions = false
    @State private var showsAppHandoff = false
    @State private var lastCompletedWork = ""
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    /// Search and scroll-to-row state shared by the Settings rail and page.
    @StateObject private var settingsNavigation = SettingsNavigationModel()
    /// Collapses the notch it is hosted in. Nil in a window.
    var onClose: (() -> Void)?
    var onDetach: ((DesktopSection) -> Void)?

    init(
        companionManager: CompanionManager,
        initialSection: DesktopSection,
        onClose: (() -> Void)? = nil,
        onDetach: ((DesktopSection) -> Void)? = nil
    ) {
        self.companionManager = companionManager
        self.onClose = onClose
        self.onDetach = onDetach
        Self.rememberSettingsTab(for: initialSection)
        _selectedSection = State(initialValue: initialSection.landingSection)
    }

    /// Every way into a section goes through here, so a link to a page that
    /// became a Settings tab still lands somewhere real.
    private func select(_ section: DesktopSection) {
        Self.rememberSettingsTab(for: section)
        selectedSection = section.landingSection
    }

    private static func rememberSettingsTab(for section: DesktopSection) {
        guard let tab = section.settingsTab else { return }
        UserDefaults.standard.set(tab, forKey: DesktopSection.settingsTabDefaultsKey)
    }

    var body: some View {
        workspaceContent
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 18) {
                Button { showsAppHandoff = true } label: {
                    Label("Hand off images", systemImage: "square.and.arrow.up")
                }
                Button { showsSuggestions.toggle() } label: {
                    Label("Ideas & updates", systemImage: suggestionMemory.newSkillIDs.isEmpty || presentationMode ? "lightbulb" : "sparkles")
                }
                .popover(isPresented: $showsSuggestions) {
                    WorkSuggestionDeck(manager: companionManager, memory: suggestionMemory)
                }
                Spacer()
                if presentationMode {
                    Button("End presentation mode") { presentationMode = false }
                }
            }
            .buttonStyle(.plain)
            .font(DS.Fonts.caption)
            .foregroundStyle(DS.Colors.textSecondary)
            .padding(.horizontal, 20).padding(.vertical, 8)
            .background(WorkspaceBackground())
            .overlay(alignment: .top) { Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1) }
        }
        .sheet(isPresented: $showsAppHandoff) { SelectedAppHandoffView() }
        .onAppear { suggestionMemory.observeSkills(companionManager.discoveredSkills) }
        .onChange(of: companionManager.discoveredSkills) { _, skills in suggestionMemory.observeSkills(skills) }
        .onChange(of: companionManager.agentRuns.filter { $0.status.isTerminal }.map(\.resultDeliveryKey).joined(separator: "|")) { _, value in
            guard value != lastCompletedWork else { return }
            lastCompletedWork = value
            companionManager.reloadSkills()
        }
        .tint(DS.Colors.accent)
        .onReceive(NotificationCenter.default.publisher(for: .heyMateDesktopSelectSection)) { notification in
            guard let rawValue = notification.userInfo?["section"] as? String,
                  let section = DesktopSection(rawValue: rawValue) else { return }
            select(section)
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        if selectedSection == .chat {
            MateHomeView(
                companionManager: companionManager,
                isCompactLayout: false,
                onOpenSection: { select($0) },
                onClose: onClose,
                onDetach: onDetach.map { detach in { detach(.chat) } },
                shouldFocusComposerOnAppear: onClose != nil
            )
            .navigationTitle("")
        } else {
            NavigationSplitView(columnVisibility: $sidebarVisibility) {
                settingsSidebar
                    .navigationSplitViewColumnWidth(min: 220, ideal: 237, max: 260)
            } detail: {
                detail
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if selectedSection.isOffSidebarPage || onDetach != nil {
                            backToChatBar
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CelestialWorkspaceBackground(accent: companionManager.themeColor))
            }
            .navigationTitle(selectedSection.displayName)
        }
    }

    // MARK: Sidebar

    /// The one sidebar for every page outside chat: the Settings rail, with
    /// Back to chat and Integrations on top. Integrations used to get its own
    /// short sidebar, which made opening it feel like leaving Settings.
    private var settingsSidebar: some View {
        SettingsSidebar(
            navigation: settingsNavigation,
            header: AnyView(
                VStack(alignment: .leading, spacing: 2) {
                    SettingsSidebarItem(title: "Back to chat", symbolName: "chevron.left") {
                        select(.chat)
                    }
                    .keyboardShortcut("[", modifiers: .command)
                    SettingsSidebarItem(
                        title: DesktopSection.connectors.displayName,
                        symbolName: DesktopSection.connectors.symbolName,
                        isSelected: selectedSection == .connectors,
                        badge: badgeCount(for: .connectors)
                    ) {
                        select(.connectors)
                    }
                    Rectangle()
                        .fill(DS.Colors.hairline)
                        .frame(height: 1)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.top, DS.Spacing.sm)
                        .accessibilityHidden(true)
                }
            ),
            isShowingSettingsPage: selectedSection == .settings,
            onOpenSettingsPage: {
                if selectedSection != .settings { selectedSection = .settings }
            }
        )
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarStatusBar
        }
    }

    /// Jobs, Skills, and Memory open from chat and from a mate's sheet, not
    /// the sidebar, so their pages say how to get back.
    private var backToChatBar: some View {
        HStack(spacing: 0) {
            if selectedSection.isOffSidebarPage {
                Button {
                    select(.chat)
                } label: {
                    Label("Back to chat", systemImage: "chevron.left")
                        .font(DS.Fonts.control)
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Capsule().fill(DS.Colors.surface2))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .keyboardShortcut("[", modifiers: .command)
            }
            Spacer(minLength: 0)
            if let onDetach {
                HStack(spacing: 10) {
                    Button { onDetach(selectedSection) } label: {
                        Image(systemName: "macwindow.on.rectangle")
                            .font(DS.Glyph.regular)
                    }
                    .dsToolbarIconButtonStyle()
                    .help("Detach into a window")
                    .accessibilityLabel("Detach into a window")
                    if let onClose {
                        Button(action: onClose) {
                            Image(systemName: "chevron.up")
                                .font(DS.Glyph.small)
                        }
                        .dsToolbarIconButtonStyle()
                        .help("Collapse to notch")
                        .accessibilityLabel("Collapse to notch")
                        .keyboardShortcut("w", modifiers: .command)
                    }
                }
                .foregroundStyle(DS.Colors.textSecondary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .background(WorkspaceBackground())
    }

    private var sidebarStatusBar: some View {
        HStack(spacing: 8) {
            BrandAppIcon(size: 22, state: companionManager.voiceState)
            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)
            Text(statusWord)
                .font(DS.Fonts.micro)
                .foregroundColor(DS.Colors.textSecondary)
            Spacer(minLength: 0)
            Button { select(.settings) } label: {
                Image(systemName: "gearshape")
                    .font(DS.Glyph.small)
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Settings")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(DS.Colors.surface1.opacity(0.90))
        .overlay(alignment: .top) {
            Rectangle().fill(DS.Colors.borderSubtle).frame(height: 1)
        }
    }

    private var statusColor: Color {
        switch companionManager.voiceState {
        case .idle: return DS.Colors.success
        case .listening: return companionManager.themeColor
        case .processing: return DS.Colors.warning
        case .responding: return companionManager.themeColor
        }
    }

    private var statusWord: String {
        if companionManager.isForegroundAgentActive { return "An agent is working" }
        switch companionManager.voiceState {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .processing: return "Thinking"
        case .responding: return "Speaking"
        }
    }

    /// Only counts that mean "something needs you" earn a badge. A badge
    /// on a section the user has nothing to do in is noise.
    private func badgeCount(for section: DesktopSection) -> Int {
        switch section {
        case .connectors:
            return companionManager.connectorStore.records.values.filter {
                $0.lastErrorMessage != nil && $0.isEnabled
            }.count
        default:
            return 0
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selectedSection {
        case .chat:
            Color.clear
        case .connectors:
            DesktopConnectorsView(
                companionManager: companionManager,
                store: companionManager.connectorStore,
                runtime: companionManager.connectorRuntime,
                composioConnections: companionManager.composioConnections,
                composioToolkitDirectory: companionManager.composioToolkitDirectory
            )
        case .notch, .privacy, .settings:
            // Notch and Privacy land on Settings (see `landingSection`), so
            // all three show the Settings page for the remembered section.
            SettingsDetailView(companionManager: companionManager, navigation: settingsNavigation)
        case .skills:
            DesktopSkillsView(companionManager: companionManager)
        case .memory:
            DesktopMemoryView(companionManager: companionManager)
        case .notes:
            NoteListView(store: companionManager.noteStore)
        }
    }
}

// MARK: - Shared desktop chrome

/// Standard page scaffold: a title, a one-line explanation of what this
/// page is for, and scrolling content at a fixed reading measure. Used by
/// every desktop section so they cannot drift apart visually.
struct DesktopPage<Content: View>: View {
    let title: String
    let subtitle: String
    /// Optional trailing control in the header (a "+" or a search field).
    var accessory: AnyView?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(DS.Fonts.pageTitle)
                        .tracking(-0.5)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(subtitle)
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                if let accessory { accessory }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 17)
            .background(DS.Colors.surface1.opacity(0.6))

            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content()
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A grouped card, the desktop equivalent of a settings section.
struct DesktopCard<Content: View>: View {
    var title: String?
    var footnote: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                DSSectionLabel(title: title)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard()
            if let footnote {
                Text(footnote)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }
}

/// Shown when a list is legitimately empty — never a blank pane. The buddy
/// mark keeps even an empty page inside the den.
struct DesktopEmptyState: View {
    let symbolName: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            BrandAppIcon(size: 58)

            VStack(spacing: 5) {
                Text(title)
                    .font(DS.Fonts.title)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(message)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(DSPrimaryButtonStyle(isFullWidth: false))
                    .pointerCursor()
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}
