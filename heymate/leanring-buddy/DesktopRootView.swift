//
//  DesktopRootView.swift
//  leanring-buddy
//
//  The HeyMate desktop window's content: a standard macOS sidebar app.
//
//  Division of labor between the two surfaces:
//    • the notch handles what should be glanceable and ambient — state,
//      one live activity, a quick chat, a running agent;
//    • this window handles what needs room and attention — the connector
//      catalog, agent history and artifacts, skills, memory, settings.
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
        case .agents: return "Agents"
        case .connectors: return "Integrations"
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
        case .agents: return "sparkles"
        case .connectors: return "app.connected.to.app.below.fill"
        case .notch: return "rectangle.topthird.inset.filled"
        case .skills: return "wand.and.stars"
        case .memory: return "brain"
        case .privacy: return "hand.raised"
        case .settings: return "gearshape"
        }
    }

    /// Sidebar grouping, named for what the user is doing rather than how
    /// the feature is built: the buddy (talk and agents), what the buddy
    /// can do (integrations, notch apps, skills), and how it behaves
    /// (memory, privacy, settings).
    enum Group: String, CaseIterable, Identifiable {
        case companion = "HeyMate"
        case abilities = "Abilities"
        case preferences = "Preferences"

        var id: String { rawValue }

        var sections: [DesktopSection] {
            switch self {
            case .companion: return [.chat, .agents]
            case .abilities: return [.connectors, .notch, .skills]
            case .preferences: return [.memory, .privacy, .settings]
            }
        }
    }
}

// MARK: - Root

struct DesktopRootView: View {
    @ObservedObject var companionManager: CompanionManager

    @State private var selectedSection: DesktopSection
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    init(companionManager: CompanionManager, initialSection: DesktopSection) {
        self.companionManager = companionManager
        _selectedSection = State(initialValue: initialSection)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 196, ideal: 216, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.Colors.background)
        }
        .navigationTitle(selectedSection.displayName)
        .tint(companionManager.themeColor)
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: .heyMateDesktopSelectSection)) { notification in
            guard let rawValue = notification.userInfo?["section"] as? String,
                  let section = DesktopSection(rawValue: rawValue) else { return }
            selectedSection = section
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selectedSection) {
            Button {
                selectedSection = .chat
            } label: {
                statusHeader
            }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Open Chat")
                .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 16, trailing: 8))
                .listRowSeparator(.hidden)
                .selectionDisabled()

            ForEach(DesktopSection.Group.allCases) { group in
                Section(group.rawValue) {
                    ForEach(group.sections) { section in
                        Label(section.displayName, systemImage: section.symbolName)
                            .badge(badgeCount(for: section))
                            .tag(section)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(DS.Colors.surface1)
    }

    /// The buddy's presence at the top of the sidebar: the mark, its name,
    /// and what it is doing right now, on a soft wash of the theme color —
    /// the same hero treatment the notch Home opens with, so the two
    /// surfaces read as one place.
    private var statusHeader: some View {
        HStack(spacing: 11) {
            BuddyMark(
                size: .standard,
                state: companionManager.voiceState,
                color: companionManager.themeColor
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("HeyMate")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text(statusWord)
                    .font(DS.Fonts.statusWord)
                    .foregroundStyle(statusColor)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(DS.Colors.surface2)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [companionManager.themeColor.opacity(0.22), Color.clear],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 150
                        )
                    )
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(companionManager.themeColor.opacity(0.18), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("HeyMate, \(statusWord)")
        .accessibilityHint("Opens Chat")
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
        if companionManager.isForegroundAgentActive { return "Agent running" }
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
            return companionManager.agentRuns.filter { !$0.status.isTerminal }.count
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
            NotchChatView(companionManager: companionManager, isCompactLayout: false)
                .padding(.top, 6)
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
            BuddyMark(size: .hero, color: DS.Colors.accent)

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
