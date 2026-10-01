//
//  DesktopRootView.swift
//  leanring-buddy
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
//  mate's sheet, and Notch Apps and Privacy are Settings tabs. The other
//  `DesktopSection` cases stay so deep links keep working.
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
    case agents
    case connectors
    case notch
    case skills
    case memory
    case privacy
    case settings

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chat: return "Chat"
        case .agents: return "Jobs"
        case .connectors: return "Apps"
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
        case .agents: return "checklist"
        case .connectors: return "app.connected.to.app.below.fill"
        case .notch: return "rectangle.topthird.inset.filled"
        case .skills: return "wand.and.stars"
        case .memory: return "brain"
        case .privacy: return "hand.raised"
        case .settings: return "gearshape"
        }
    }

    /// What the sidebar lists under "Back to chat". Everything else is
    /// reached from inside chat or Settings.
    static let sidebarSections: [DesktopSection] = [.connectors, .settings]

    /// The `@AppStorage` key Settings reads to pick its tab.
    static let settingsTabDefaultsKey = "desktopSettingsSelectedTab"

    /// Notch Apps and Privacy live inside Settings now. A deep link to one
    /// of them lands on Settings, on that tab.
    var settingsTab: String? {
        switch self {
        case .notch: return "notch"
        case .privacy: return "privacy"
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
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    init(companionManager: CompanionManager, initialSection: DesktopSection) {
        self.companionManager = companionManager
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
        Group {
            if selectedSection == .chat {
                MateHomeView(
                    companionManager: companionManager,
                    isCompactLayout: false,
                    onOpenSection: { select($0) }
                )
                .navigationTitle("")
            } else {
                NavigationSplitView(columnVisibility: $sidebarVisibility) {
                    workspaceSidebar
                        .navigationSplitViewColumnWidth(min: 220, ideal: 237, max: 260)
                } detail: {
                    detail
                        .safeAreaInset(edge: .top, spacing: 0) {
                            if selectedSection.isOffSidebarPage {
                                backToChatBar
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(CelestialWorkspaceBackground(accent: companionManager.themeColor))
                }
                .navigationTitle(selectedSection.displayName)
            }
        }
        .tint(DS.Colors.accent)
        .onReceive(NotificationCenter.default.publisher(for: .heyMateDesktopSelectSection)) { notification in
            guard let rawValue = notification.userInfo?["section"] as? String,
                  let section = DesktopSection(rawValue: rawValue) else { return }
            select(section)
        }
    }

    // MARK: Sidebar

    /// Apps and Settings. The mate rail is the chat app; this list is only
    /// how you leave it.
    private var workspaceSidebar: some View {
        List(selection: $selectedSection) {
            Section {
                Button {
                    selectedSection = .chat
                } label: {
                    Label("Back to chat", systemImage: "bubble.left.and.bubble.right")
                        .font(DS.Fonts.headline)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .selectionDisabled()
            }

            Section {
                ForEach(DesktopSection.sidebarSections) { section in
                    Label(section.displayName, systemImage: section.symbolName)
                        .badge(badgeCount(for: section))
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 27)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarStatusBar
        }
        .background(CelestialSidebarBackground(accent: companionManager.themeColor))
    }

    /// Jobs, Skills, and Memory open from chat and from a mate's sheet, not
    /// the sidebar, so their pages say how to get back.
    private var backToChatBar: some View {
        HStack(spacing: 0) {
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
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .background(DS.Colors.surface1.opacity(0.6))
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
        if companionManager.isForegroundAgentActive { return "Working on a job" }
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
        case .agents:
            return MateJobs.activeCount(in: companionManager.agentRuns)
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
        case .agents:
            DesktopAgentsView(companionManager: companionManager)
        case .connectors:
            DesktopConnectorsView(
                store: companionManager.connectorStore,
                runtime: companionManager.connectorRuntime,
                composioConnections: companionManager.composioConnections,
                composioToolkitDirectory: companionManager.composioToolkitDirectory
            )
        case .notch:
            DesktopNotchView(activityCenter: companionManager.notchActivityCenter)
        case .skills:
            DesktopSkillsView(companionManager: companionManager)
        case .memory:
            DesktopMemoryView(companionManager: companionManager)
        case .privacy:
            DesktopPrivacyView(companionManager: companionManager)
        case .settings:
            DesktopSettingsView(companionManager: companionManager)
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
