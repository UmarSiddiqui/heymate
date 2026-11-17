//
//  MateSettingsSheet.swift
//  HeyMate
//
//  Everything about one agent, laid out like the app settings window: a
//  section rail with search on the left, one section on the right. Every
//  control saves as it changes; destructive actions confirm. Opening or
//  editing settings never spends a model call (only "Check now" does).
//
//  The sections live one per file (MateSettings*Pane.swift); this file is the
//  shell: rail, search, deep-link landing, and the reveal highlight.
//

import SwiftUI

struct MateSettingsSheet: View {
    let mate: Mate
    @ObservedObject var companionManager: CompanionManager
    /// Opens a desktop page (all memories, the skills library, Integrations)
    /// after the sheet closes.
    var onOpenSection: (DesktopSection) -> Void
    var onSave: (String, String, String, String?) -> String?
    var onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var section: MateSettingsSection
    @State private var query = ""
    @State private var revealAnchor: String?
    @State private var highlightedAnchor: String?
    @FocusState private var isSearchFocused: Bool
    @Namespace private var railSelection

    static let minimumSize = CGSize(width: 760, height: 520)

    init(
        mate: Mate,
        companionManager: CompanionManager,
        initialSection: MateSettingsSection = .profile,
        onOpenSection: @escaping (DesktopSection) -> Void,
        onSave: @escaping (String, String, String, String?) -> String?,
        onDelete: @escaping () -> Void
    ) {
        self.mate = mate
        self.companionManager = companionManager
        self.onOpenSection = onOpenSection
        self.onSave = onSave
        self.onDelete = onDelete
        _section = State(initialValue: initialSection)
    }

    private var liveMate: Mate { companionManager.mates.first { $0.id == mate.id } ?? mate }

    private var context: MateSettingsContext {
        MateSettingsContext(
            mateID: mate.id, fallback: mate, companionManager: companionManager,
            openDesktopSection: { section in
                dismiss()
                onOpenSection(section)
            },
            close: { dismiss() },
            onSave: onSave,
            onDelete: onDelete
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            rail
                .frame(width: DS.SettingsLayout.railWidth - 24)
            Rectangle().fill(DS.Colors.hairline).frame(width: 1).accessibilityHidden(true)
            detail
        }
        .preferredColorScheme(.dark)
        .background(DS.Colors.background)
        .frame(minWidth: Self.minimumSize.width, idealWidth: 880, maxWidth: 1_040,
               minHeight: Self.minimumSize.height, idealHeight: 680, maxHeight: 820)
        .tint(DS.Colors.accent)
        .background(
            Button("Search agent settings") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    // MARK: Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Spacing.sm) {
                MateFaceView(mate: liveMate, size: 28, expression: .idle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(liveMate.name)
                        .font(DS.Fonts.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text("Agent settings")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, DS.Spacing.md + 2)
            .padding(.top, DS.Spacing.lg)

            searchField
                .padding(.horizontal, DS.Spacing.sm + 2)
                .padding(.vertical, DS.Spacing.md)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        ForEach(MateSettingsSection.allCases) { item in
                            SettingsSidebarItem(
                                title: item.title,
                                symbolName: item.symbolName,
                                isSelected: item == section,
                                selectionNamespace: accessibilityReduceMotion ? nil : railSelection
                            ) {
                                withAnimation(accessibilityReduceMotion ? DS.Animation.reducedMotionFade : DS.Animation.settingsPage) {
                                    section = item
                                }
                            }
                        }
                    } else {
                        searchResults
                    }
                }
                .padding(.horizontal, DS.Spacing.sm + 2)
                .padding(.bottom, DS.Spacing.lg)
            }
            .scrollIndicators(.never)

            Text("Changes save as you make them.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, DS.Spacing.md + 2)
                .padding(.bottom, DS.Spacing.md)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(WorkspaceBackground().ignoresSafeArea())
    }

    private var results: [MateSettingsItem] {
        MateSettingsCatalog.results(for: query, conductsOthers: liveMate.conductsOthers)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(DS.Glyph.small)
                .foregroundColor(DS.Colors.textTertiary)
                .accessibilityHidden(true)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textPrimary)
                .focused($isSearchFocused)
                .onSubmit { if let first = results.first { reveal(first) } }
                .onExitCommand { query = "" }
                .accessibilityLabel("Search agent settings")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(DS.Glyph.small)
                        .foregroundColor(DS.Colors.textTertiary)
                        .dsIconHitArea()
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
                .stroke(isSearchFocused ? DS.Colors.focusRing : DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var searchResults: some View {
        let found = results
        if found.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("No matching settings")
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Try another word, like “model” or “quiet”.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.top, DS.Spacing.sm)
            .accessibilityElement(children: .combine)
        } else {
            Text(found.count == 1 ? "1 result" : "\(found.count) results")
                .font(DS.Fonts.sectionLabel)
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xs)
                .accessibilityAddTraits(.isHeader)
            ForEach(found) { item in
                Button { reveal(item) } label: {
                    HStack(spacing: DS.Spacing.sm + 2) {
                        Image(systemName: item.section.symbolName)
                            .font(DS.Glyph.small)
                            .foregroundColor(DS.Colors.textTertiary)
                            .frame(width: DS.SettingsLayout.rowIconWidth)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(DS.Fonts.bodyLarge)
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(1)
                            Text(item.section.title)
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, 5)
                    .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityLabel("\(item.title), in \(item.section.title)")
            }
        }
    }

    private func reveal(_ item: MateSettingsItem) {
        query = ""
        section = item.section
        revealAnchor = item.anchor
    }

    // MARK: Detail

    private var detail: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.SettingsLayout.sectionSpacing) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(section.title)
                            .font(DS.Fonts.pageTitle)
                            .tracking(-0.5)
                            .foregroundColor(DS.Colors.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: DS.Spacing.md)
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                            .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                            .accessibilityHint("Closes agent settings. Changes are already saved.")
                    }
                    pane
                        .id(section)
                        .transition(.opacity)
                }
                .frame(maxWidth: DS.SettingsLayout.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, DS.Spacing.xxl + 4)
                .padding(.vertical, DS.Spacing.xxl + 4)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .environment(\.settingsHighlightedItemID, highlightedAnchor)
            .onChange(of: revealAnchor) { _, anchor in scroll(to: anchor, with: proxy) }
            .onAppear { scroll(to: revealAnchor, with: proxy) }
        }
        .background(DS.Colors.background)
    }

    @ViewBuilder
    private var pane: some View {
        switch section {
        case .profile: MateSettingsProfilePane(context: context)
        case .brain: MateSettingsBrainPane(context: context)
        case .permissions: MateSettingsPermissionsPane(context: context)
        case .proactive: MateSettingsProactivePane(context: context)
        case .notifications: MateSettingsNotificationsPane(context: context)
        case .memory: MateSettingsMemoryPane(context: context)
        case .files: MateSettingsFilesPane(context: context)
        case .apps: MateSettingsAppsPane(context: context)
        case .limits: MateSettingsLimitsPane(context: context)
        }
    }

    /// Waits one layout pass so a section that just appeared has its rows.
    private func scroll(to anchor: String?, with proxy: ScrollViewProxy) {
        guard let anchor else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(accessibilityReduceMotion ? nil : DS.Animation.settingsPage) {
                proxy.scrollTo(anchor, anchor: .center)
            }
            revealAnchor = nil
            highlightedAnchor = anchor
            try? await Task.sleep(for: .seconds(DS.SettingsLayout.revealHighlightSeconds))
            if highlightedAnchor == anchor { highlightedAnchor = nil }
        }
    }
}
