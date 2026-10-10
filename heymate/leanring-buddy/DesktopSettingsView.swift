//
//  DesktopSettingsView.swift
//  leanring-buddy
//
//  Settings: a section rail with search, and one page per section.
//
//  The old five-tab bar split topics across tabs (voice lived in three
//  places) and could not be searched. Sections now follow what a person is
//  trying to change — see docs/settings-redesign.md for the audit and the
//  map from old placement to new.
//
//  Two hosts, one set of pieces:
//    • the desktop window shows `SettingsSidebar` as its own sidebar while
//      Settings is open, so there is never a sidebar beside a sidebar;
//    • the Cmd-, Settings window shows `DesktopSettingsView`, which puts
//      the same rail and pages side by side.
//
//  The selected section is stored under `desktopSettingsSelectedTab`, so
//  other code can deep-link to a section by writing that key first.
//

import SwiftUI

/// The standalone Settings window (Cmd-,): rail and pages side by side.
struct DesktopSettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    @StateObject private var navigation = SettingsNavigationModel()

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(navigation: navigation)
                .frame(width: DS.SettingsLayout.railWidth)

            Rectangle()
                .fill(DS.Colors.borderSubtle)
                .frame(width: 1)
                .accessibilityHidden(true)

            SettingsDetailView(companionManager: companionManager, navigation: navigation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.Colors.background)
    }
}

// MARK: - Detail

/// The page for the selected section.
struct SettingsDetailView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var navigation: SettingsNavigationModel

    /// AppStorage, not State, so a deep link that writes the key while this
    /// view is on screen switches the page.
    @AppStorage(DesktopSettingsTab.storageKey) private var selectedTabRawValue = DesktopSettingsTab.general.rawValue

    private var selectedTab: DesktopSettingsTab {
        DesktopSettingsTab.resolve(selectedTabRawValue)
    }

    var body: some View {
        page
            .id(selectedTab)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(DS.Colors.background)
            .task {
                // Model catalogs and sign-in status feed the AI and Agents
                // pages, so they load once for Settings, not per page.
                await AISettingsRefresh.refreshCatalogsAndReadiness(companionManager)
            }
    }

    @ViewBuilder
    private var page: some View {
        switch selectedTab {
        case .general:
            SettingsGeneralPane(companionManager: companionManager, navigation: navigation)
        case .shortcuts:
            SettingsShortcutsPane(companionManager: companionManager, navigation: navigation)
        case .voice:
            SettingsVoicePane(companionManager: companionManager, navigation: navigation)
        case .notch:
            SettingsNotchPane(activityCenter: companionManager.notchActivityCenter, navigation: navigation)
        case .accounts:
            DesktopSettingsAccountsTab(companionManager: companionManager, navigation: navigation)
        case .agents:
            SettingsAgentsPane(companionManager: companionManager, navigation: navigation)
        case .connections:
            SettingsConnectionsPane(companionManager: companionManager, navigation: navigation)
        case .privacy:
            SettingsPrivacyPane(companionManager: companionManager, navigation: navigation)
        }
    }
}

// MARK: - Rail

/// The section rail: search on top, then sections under their group
/// headings. While searching, the rail lists matching settings instead;
/// Return opens the first one, Esc clears the search, Cmd-F focuses it.
struct SettingsSidebar: View {
    @ObservedObject var navigation: SettingsNavigationModel
    /// Rows above the search field. The desktop window puts "Back to chat"
    /// and "Apps" here.
    var header: AnyView?

    @AppStorage(DesktopSettingsTab.storageKey) private var selectedTabRawValue = DesktopSettingsTab.general.rawValue
    @FocusState private var isSearchFieldFocused: Bool

    private var selectedTab: DesktopSettingsTab {
        DesktopSettingsTab.resolve(selectedTabRawValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                header
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.top, DS.Spacing.sm)
            }

            searchField
                .padding(.horizontal, DS.Spacing.sm + 2)
                .padding(.top, header == nil ? DS.Spacing.md : DS.Spacing.sm)
                .padding(.bottom, DS.Spacing.sm)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if navigation.isSearching {
                        searchResults
                    } else {
                        sectionList
                    }
                }
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.bottom, DS.Spacing.md)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Colors.surface1.ignoresSafeArea())
        .background(
            // Cmd-F from anywhere in Settings.
            Button("Search settings") { isSearchFieldFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(DS.Glyph.small)
                .foregroundColor(DS.Colors.textTertiary)
                .accessibilityHidden(true)
            TextField("Search settings", text: $navigation.searchQuery)
                .textFieldStyle(.plain)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textPrimary)
                .focused($isSearchFieldFocused)
                .onSubmit {
                    if let first = navigation.searchResults.first {
                        navigation.reveal(first)
                    }
                }
                .onExitCommand { navigation.searchQuery = "" }
                .accessibilityLabel("Search settings")
            if navigation.isSearching {
                Button {
                    navigation.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(DS.Glyph.small)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: DS.ControlSize.regular)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(isSearchFieldFocused ? DS.Colors.focusRing : DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = navigation.searchResults
        if results.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("No matching settings")
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Try another word, like “microphone” or “sign in”.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.top, DS.Spacing.sm)
            .accessibilityElement(children: .combine)
        } else {
            Text(results.count == 1 ? "1 result" : "\(results.count) results")
                .font(DS.Fonts.sectionLabel)
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xs)
                .accessibilityAddTraits(.isHeader)
            ForEach(results) { item in
                SettingsSidebarResultButton(item: item) {
                    navigation.reveal(item)
                }
            }
        }
    }

    // MARK: Sections

    private var sectionList: some View {
        ForEach(DesktopSettingsTabGroup.allCases) { group in
            Text(group.title)
                .font(DS.Fonts.sectionLabel)
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.top, group == DesktopSettingsTabGroup.allCases.first ? DS.Spacing.xs : DS.Spacing.md)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)

            ForEach(group.tabs) { tab in
                SettingsSidebarItem(
                    title: tab.title,
                    symbolName: tab.symbolName,
                    isSelected: tab == selectedTab
                ) {
                    selectedTabRawValue = tab.rawValue
                }
            }
        }
    }
}

/// One rail row. Also used for the desktop window's "Back to chat" and
/// "Apps" links so the whole rail reads as one list.
struct SettingsSidebarItem: View {
    let title: String
    let symbolName: String
    var isSelected = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.sm + 2) {
                Image(systemName: symbolName)
                    .font(DS.Glyph.regular)
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .frame(width: DS.SettingsLayout.rowIconWidth)
                    .accessibilityHidden(true)
                Text(title)
                    .font(isSelected ? DS.Fonts.headline : DS.Fonts.bodyLarge)
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.sm)
            .frame(minHeight: DS.ControlSize.large - 2)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isSelected ? DS.Colors.selectionFill : (isHovered ? DS.Colors.surface2 : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
    }
}

/// A search result: the setting, and the section it lives in.
private struct SettingsSidebarResultButton: View {
    let item: SettingsItem
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.sm + 2) {
                Image(systemName: item.tab.symbolName)
                    .font(DS.Glyph.small)
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: DS.SettingsLayout.rowIconWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(DS.Fonts.bodyLarge)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(item.tab.title)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isHovered ? DS.Colors.surface2 : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(item.title), in \(item.tab.title)")
    }
}
