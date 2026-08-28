//
//  DesktopSkillsView.swift
//  leanring-buddy
//
//  Skills library: active precedence, local provenance, and review-gated
//  installation from Anthropic's verified public skills repository.
//

import AppKit
import SwiftUI

struct DesktopSkillsView: View {
    @ObservedObject var companionManager: CompanionManager
    @StateObject private var registry = AnthropicSkillRegistry()

    @State private var searchText = ""
    @State private var selectedSkillIdentifier: String?
    @State private var selectedRemoteIdentifier: String?
    @State private var selectedFilter: SkillLibraryFilter = .all
    @State private var reviewedRemoteIdentifiers: Set<String> = []
    @State private var hoveredActiveIdentifier: String?
    @State private var mutationError: String?
    @State private var skillPendingRemoval: RemoteSkillDescriptor?
    @State private var showsResetConfirmation = false

    private var activeSkills: [DiscoveredSkill] {
        companionManager.discoveredSkills
            .filter { companionManager.isSkillActive($0) }
            .sorted {
                (companionManager.activeSkillPriority(for: $0) ?? .max)
                    < (companionManager.activeSkillPriority(for: $1) ?? .max)
            }
    }

    private var localSkills: [DiscoveredSkill] {
        filtered(companionManager.discoveredSkills).filter(filterAllows)
    }

    private var remoteSkills: [RemoteSkillDescriptor] {
        guard selectedFilter == .all || selectedFilter == .anthropic else { return [] }
        let query = normalizedSearch
        return registry.skills.filter { descriptor in
            query.isEmpty
                || descriptor.name.localizedCaseInsensitiveContains(query)
                || descriptor.description.localizedCaseInsensitiveContains(query)
        }
    }

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedLocalSkill: DiscoveredSkill? {
        companionManager.discoveredSkills.first { $0.identifier == selectedSkillIdentifier }
    }

    private var selectedRemoteSkill: RemoteSkillDescriptor? {
        registry.skills.first { $0.id == selectedRemoteIdentifier }
    }

    var body: some View {
        DesktopPage(
            title: "Skills",
            subtitle: "Review what HeyMate may add to a prompt. Active skills run in priority order.",
            accessory: AnyView(headerActions)
        ) {
            activeConstellation
            filterRail
            libraryCard
        }
        .onAppear {
            companionManager.reloadSkills()
            selectFirstSkillIfNeeded()
            if registry.skills.isEmpty { Task { await registry.refresh() } }
        }
        .onChange(of: selectedFilter) { _, _ in selectFirstSkillIfNeeded() }
        .onChange(of: searchText) { _, _ in selectFirstSkillIfNeeded() }
        .onChange(of: registry.skills) { _, _ in selectFirstSkillIfNeeded() }
        .alert("Skill change failed", isPresented: Binding(
            get: { mutationError != nil },
            set: { if !$0 { mutationError = nil } }
        )) {
            Button("OK", role: .cancel) { mutationError = nil }
        } message: {
            Text(mutationError ?? "Unknown error")
        }
        .confirmationDialog(
            "Remove installed skill?",
            isPresented: Binding(
                get: { skillPendingRemoval != nil },
                set: { if !$0 { skillPendingRemoval = nil } }
            )
        ) {
            Button("Remove from this Mac", role: .destructive) {
                guard let descriptor = skillPendingRemoval else { return }
                do {
                    try companionManager.removeRemoteSkill(descriptor)
                    reviewedRemoteIdentifiers.remove(descriptor.id)
                    skillPendingRemoval = nil
                } catch { mutationError = error.localizedDescription }
            }
            Button("Cancel", role: .cancel) { skillPendingRemoval = nil }
        } message: {
            Text("Removes HeyMate's installed copy. Source repository stays unchanged.")
        }
        .confirmationDialog("Reset all skill choices?", isPresented: $showsResetConfirmation) {
            Button("Reset activation and priority", role: .destructive) {
                companionManager.resetSkillActivationChoices()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Built-in and personal HeyMate skills return to active. Claude Code and installed remote skills return to inactive. Installed files remain on this Mac.")
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            TextField("Search skills", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)

            Button {
                companionManager.reloadSkills()
                Task { await registry.refresh() }
            } label: {
                if registry.isLoading { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .dsIconButtonStyle(size: 30, tooltip: "Reload local and Anthropic skills")

            Button("Open folder") {
                NSWorkspace.shared.open(SkillMarkdownParser.defaultDirectory())
            }
            .buttonStyle(DSPrimaryButtonStyle(isFullWidth: false))
        }
    }

    private var activeConstellation: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(LinearGradient(colors: [DS.Colors.surface2, DS.Colors.surface1, DS.Colors.surface2], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    DSSectionLabel(title: "Active constellation")
                    Text(activeSkills.isEmpty ? "Quiet by default" : "\(activeSkills.count) skills in orbit")
                        .font(DS.Fonts.pageTitle)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(activeSkills.isEmpty
                         ? "Activate reviewed skills to build a working set."
                         : "Nearest the core means higher prompt precedence.")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let hoveredActiveIdentifier,
                       let hovered = activeSkills.first(where: { $0.identifier == hoveredActiveIdentifier }) {
                        Text(hovered.skill.name)
                            .font(DS.Fonts.titleCompact)
                            .foregroundColor(DS.Colors.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(DS.Colors.surface3, in: Capsule())
                    } else if !activeSkills.isEmpty {
                        Text("Hover a node for its name")
                            .font(DS.Fonts.caption)
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 245, alignment: .leading)
                .padding(24)

                ActiveSkillOrbit(
                    skills: Array(activeSkills.prefix(9)),
                    accent: DS.Colors.accent,
                    systemAccent: DS.Colors.info,
                    hoveredIdentifier: $hoveredActiveIdentifier,
                    select: selectLocalSkill
                )
                .frame(maxWidth: .infinity, minHeight: 190)
                .accessibilityLabel("Active skills by priority")
            }
        }
        .frame(height: 210)
    }

    private var filterRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(SkillLibraryFilter.allCases) { filter in
                    Button { selectedFilter = filter } label: {
                        HStack(spacing: 6) {
                            Image(systemName: filter.symbolName)
                            Text(filter.title).fixedSize(horizontal: true, vertical: false)
                        }
                        .font(DS.Fonts.sectionLabel)
                        .foregroundColor(selectedFilter == filter ? DS.Colors.accentText : DS.Colors.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(selectedFilter == filter ? DS.Colors.accentSubtle : DS.Colors.surface2, in: Capsule())
                        .overlay(Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }

                Spacer(minLength: 8)
                Button("Reset choices") { showsResetConfirmation = true }
                    .buttonStyle(DSTertiaryButtonStyle())
            }
            .padding(.vertical, 1)
        }
    }

    private var libraryCard: some View {
        DesktopCard {
            HStack(alignment: .top, spacing: 0) {
                libraryList.frame(width: 292)
                Divider().padding(.horizontal, 16)
                detailPane.frame(maxWidth: .infinity, minHeight: 500, alignment: .topLeading)
            }
        }
    }

    private var libraryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if !localSkills.isEmpty {
                    sectionLabel("On this Mac", count: localSkills.count, color: DS.Colors.accent)
                    ForEach(localSkills) { skill in localRow(skill) }
                }

                if selectedFilter == .anthropic || selectedFilter == .all {
                    sectionLabel("Verified · Anthropic", count: remoteSkills.count, color: DS.Colors.info)
                    if registry.isLoading && registry.skills.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading official registry…")
                        }
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(10)
                    } else if let errorMessage = registry.errorMessage, registry.skills.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(errorMessage)
                                .font(DS.Fonts.caption)
                                .foregroundColor(DS.Colors.textSecondary)
                            Button("Try again") { Task { await registry.refresh() } }
                                .buttonStyle(DSTertiaryButtonStyle())
                        }
                        .padding(10)
                    } else {
                        ForEach(remoteSkills) { descriptor in remoteRow(descriptor) }
                    }
                }

                if localSkills.isEmpty && remoteSkills.isEmpty && !registry.isLoading {
                    Text("No matching skills")
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(10)
                }
            }
        }
        .frame(maxHeight: 620)
    }

    private func sectionLabel(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 6, height: 6)
            DSSectionLabel(title: title)
            Spacer()
            Text("\(count)").font(DS.Fonts.micro)
        }
        .foregroundColor(DS.Colors.textTertiary)
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private func localRow(_ skill: DiscoveredSkill) -> some View {
        let selected = selectedSkillIdentifier == skill.identifier && selectedRemoteIdentifier == nil
        let active = companionManager.isSkillActive(skill)
        return Button { selectLocalSkill(skill) } label: {
            HStack(spacing: 10) {
                skillMark(name: skill.skill.name, color: active ? DS.Colors.accentText : DS.Colors.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.skill.name)
                        .font(DS.Fonts.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(skill.origin.displayLabel)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if active {
                    Text("\(companionManager.activeSkillPriority(for: skill) ?? 0)")
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.accentText)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(selected ? DS.Colors.accentSubtle : Color.clear, in: RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous).stroke(selected ? DS.Colors.accent.opacity(0.35) : Color.clear))
        }
        .buttonStyle(.plain)
        .help(skill.skill.name)
        .pointerCursor()
    }

    private func remoteRow(_ descriptor: RemoteSkillDescriptor) -> some View {
        let selected = selectedRemoteIdentifier == descriptor.id
        let installed = companionManager.skillRegistryInstallationStore.installedDescriptor(id: descriptor.id)
        return Button {
            selectedRemoteIdentifier = descriptor.id
            selectedSkillIdentifier = nil
        } label: {
            HStack(spacing: 10) {
                skillMark(name: descriptor.name, color: DS.Colors.info)
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.name)
                        .font(DS.Fonts.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(installed == nil ? "Browse · v\(descriptor.shortVersion)" : "Installed · v\(installed!.shortVersion)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: installed == nil ? "arrow.down.circle" : "checkmark.seal.fill")
                    .foregroundColor(DS.Colors.info)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(selected ? DS.Colors.info.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous).stroke(selected ? DS.Colors.info.opacity(0.35) : Color.clear))
        }
        .buttonStyle(.plain)
        .help(descriptor.name)
        .pointerCursor()
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selectedRemoteSkill { remoteDetail(selectedRemoteSkill) }
        else if let selectedLocalSkill { localDetail(selectedLocalSkill) }
        else {
            ContentUnavailableView(
                "Select a skill",
                systemImage: "wand.and.stars",
                description: Text("Inspect instructions and provenance before activation.")
            )
            .frame(maxWidth: .infinity, minHeight: 500)
        }
    }

    private func localDetail(_ skill: DiscoveredSkill) -> some View {
        detailShell(
            name: skill.skill.name,
            description: skill.skill.trigger,
            accent: skill.trustTier == .remoteVerified ? DS.Colors.info : DS.Colors.accentText,
            badges: [skill.trustTier.displayLabel, skill.origin.displayLabel],
            author: skill.remoteMetadata?.author ?? localAuthor(for: skill.origin),
            repository: skill.remoteMetadata?.repositoryURL,
            version: skill.remoteMetadata?.shortVersion,
            tools: skill.skill.tools,
            instructions: skill.skill.instructions,
            sourcePath: skill.fileURL.path
        ) {
            HStack(spacing: 8) {
                Toggle("Active", isOn: Binding(
                    get: { companionManager.isSkillActive(skill) },
                    set: { companionManager.setSkillActive($0, for: skill) }
                ))
                .toggleStyle(.switch)

                if companionManager.isSkillActive(skill) { priorityButtons(for: skill) }
                Spacer()

                if let descriptor = skill.remoteMetadata {
                    Button("Remove", role: .destructive) { skillPendingRemoval = descriptor }
                        .buttonStyle(DSTertiaryButtonStyle())
                } else {
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([skill.fileURL]) }
                        .buttonStyle(DSTertiaryButtonStyle())
                }
            }
        }
    }

    private func remoteDetail(_ descriptor: RemoteSkillDescriptor) -> some View {
        let installed = companionManager.skillRegistryInstallationStore.installedDescriptor(id: descriptor.id)
        let installedSkill = companionManager.discoveredSkills.first { $0.remoteMetadata?.id == descriptor.id }
        let updateAvailable = installed.map { $0.version != descriptor.version } ?? false

        return detailShell(
            name: descriptor.name,
            description: descriptor.description,
            accent: DS.Colors.info,
            badges: ["Verified", "Anthropic"],
            author: descriptor.author,
            repository: descriptor.repositoryURL,
            version: descriptor.shortVersion,
            tools: descriptor.tools,
            instructions: descriptor.instructions,
            sourcePath: descriptor.sourceURL.absoluteString
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if installed == nil || updateAvailable {
                    Toggle("I reviewed these instructions", isOn: Binding(
                        get: { reviewedRemoteIdentifiers.contains(descriptor.id) },
                        set: { reviewed in
                            if reviewed { reviewedRemoteIdentifiers.insert(descriptor.id) }
                            else { reviewedRemoteIdentifiers.remove(descriptor.id) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(DS.Fonts.caption)
                }

                HStack(spacing: 8) {
                    if installed == nil || updateAvailable {
                        Button(installed == nil ? "Install reviewed skill" : "Update reviewed skill") {
                            do {
                                try companionManager.installRemoteSkill(descriptor)
                                reviewedRemoteIdentifiers.remove(descriptor.id)
                            } catch { mutationError = error.localizedDescription }
                        }
                        .buttonStyle(DSPrimaryButtonStyle(isFullWidth: false))
                        .disabled(!reviewedRemoteIdentifiers.contains(descriptor.id))
                    }

                    if let installedSkill {
                        Toggle("Active", isOn: Binding(
                            get: { companionManager.isSkillActive(installedSkill) },
                            set: { companionManager.setSkillActive($0, for: installedSkill) }
                        ))
                        .toggleStyle(.switch)

                        Button("Remove", role: .destructive) { skillPendingRemoval = descriptor }
                            .buttonStyle(DSTertiaryButtonStyle())
                    }

                    Spacer()
                    Button("View repository") { NSWorkspace.shared.open(descriptor.sourceURL) }
                        .buttonStyle(DSTertiaryButtonStyle())
                }
            }
        }
    }

    private func detailShell<Actions: View>(
        name: String,
        description: String,
        accent: Color,
        badges: [String],
        author: String?,
        repository: URL?,
        version: String?,
        tools: [String],
        instructions: String,
        sourcePath: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 13) {
                skillMark(name: name, color: accent, size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(DS.Fonts.title)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(description)
                        .font(DS.Fonts.body)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }

            HStack(spacing: 6) {
                ForEach(uniqueBadges(badges), id: \.self) { badge in
                    Text(badge)
                        .font(DS.Fonts.micro)
                        .foregroundColor(accent)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(accent.opacity(0.1), in: Capsule())
                }
            }

            metadataGrid(author: author, repository: repository, version: version, sourcePath: sourcePath)

            VStack(alignment: .leading, spacing: 7) {
                detailLabel("Declared tools")
                if tools.isEmpty {
                    Text("Not provided")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(tools, id: \.self) { tool in
                                Text(tool)
                                    .font(.system(size: 11, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .frame(height: 23)
                                    .background(DS.Colors.surface3, in: RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    detailLabel("Instructions · review before activation")
                    Spacer()
                    Text("Read only")
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                ScrollView {
                    Text(instructions.isEmpty ? "No instruction body provided." : instructions)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(DS.Colors.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(minHeight: 170, maxHeight: 250)
                .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous).stroke(DS.Colors.borderSubtle))
            }

            actions()
        }
    }

    private func metadataGrid(author: String?, repository: URL?, version: String?, sourcePath: String) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
            metadataRow("Author", author ?? "Not provided")
            metadataRow("Version", version.map { "Git \($0)" } ?? "Not provided")
            metadataRow("Repository", repository?.absoluteString ?? "Not provided")
            metadataRow("Source", sourcePath)
        }
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func priorityButtons(for skill: DiscoveredSkill) -> some View {
        HStack(spacing: 4) {
            Text("Priority \(companionManager.activeSkillPriority(for: skill) ?? 0)")
                .font(DS.Fonts.statusWord)
                .foregroundColor(DS.Colors.accentText)
            Button { companionManager.moveActiveSkill(skill, by: -1) } label: { Image(systemName: "chevron.up") }
                .dsIconButtonStyle(size: 25, tooltip: "Raise priority")
                .disabled(companionManager.activeSkillPriority(for: skill) == 1)
            Button { companionManager.moveActiveSkill(skill, by: 1) } label: { Image(systemName: "chevron.down") }
                .dsIconButtonStyle(size: 25, tooltip: "Lower priority")
                .disabled(companionManager.activeSkillPriority(for: skill) == activeSkills.count)
        }
    }

    private func detailLabel(_ text: String) -> some View {
        DSSectionLabel(title: text)
    }

    private func skillMark(name: String, color: Color, size: CGFloat = 30) -> some View {
        Text(initials(for: name))
            .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
            .foregroundColor(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: size * 0.3))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3).stroke(color.opacity(0.25)))
    }

    private func initials(for name: String) -> String {
        name.split { $0 == "-" || $0 == "_" || $0.isWhitespace }
            .prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    private func uniqueBadges(_ badges: [String]) -> [String] {
        var seen: Set<String> = []
        return badges.filter { seen.insert($0).inserted }
    }

    private func localAuthor(for origin: SkillOrigin) -> String? {
        switch origin {
        case .bundledDefault: return "HeyMate"
        case .userSkillsFolder: return "You"
        case .claudeCodeUserFolder, .claudeCodeProjectFolder, .remoteRegistry: return nil
        }
    }

    private func filtered(_ skills: [DiscoveredSkill]) -> [DiscoveredSkill] {
        guard !normalizedSearch.isEmpty else { return skills }
        return skills.filter {
            $0.skill.name.localizedCaseInsensitiveContains(normalizedSearch)
                || $0.skill.trigger.localizedCaseInsensitiveContains(normalizedSearch)
                || $0.origin.displayLabel.localizedCaseInsensitiveContains(normalizedSearch)
        }
    }

    private func filterAllows(_ skill: DiscoveredSkill) -> Bool {
        switch selectedFilter {
        case .all, .onThisMac: return true
        case .active: return companionManager.isSkillActive(skill)
        case .builtIn: return skill.origin == .bundledDefault
        case .claudeCode:
            if case .claudeCodeUserFolder = skill.origin { return true }
            if case .claudeCodeProjectFolder = skill.origin { return true }
            return false
        case .anthropic:
            if case .remoteRegistry(let identifier) = skill.origin {
                return identifier == AnthropicSkillRegistry.registryIdentifier
            }
            return false
        }
    }

    private func selectLocalSkill(_ skill: DiscoveredSkill) {
        selectedSkillIdentifier = skill.identifier
        selectedRemoteIdentifier = nil
    }

    private func selectFirstSkillIfNeeded() {
        if let selectedSkillIdentifier,
           localSkills.contains(where: { $0.identifier == selectedSkillIdentifier }) { return }
        if let selectedRemoteIdentifier,
           remoteSkills.contains(where: { $0.id == selectedRemoteIdentifier }) { return }
        if let first = localSkills.first { selectLocalSkill(first) }
        else {
            selectedSkillIdentifier = nil
            selectedRemoteIdentifier = remoteSkills.first?.id
        }
    }
}

private enum SkillLibraryFilter: String, CaseIterable, Identifiable {
    case all, active, onThisMac, builtIn, claudeCode, anthropic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .active: return "Active"
        case .onThisMac: return "On this Mac"
        case .builtIn: return "Built in"
        case .claudeCode: return "Claude Code"
        case .anthropic: return "Anthropic"
        }
    }
    var symbolName: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .active: return "sparkles"
        case .onThisMac: return "macbook"
        case .builtIn: return "shippingbox.fill"
        case .claudeCode: return "terminal"
        case .anthropic: return "checkmark.seal"
        }
    }
}

private struct ActiveSkillOrbit: View {
    let skills: [DiscoveredSkill]
    let accent: Color
    let systemAccent: Color
    @Binding var hoveredIdentifier: String?
    let select: (DiscoveredSkill) -> Void

    private let positions: [(CGFloat, CGFloat)] = [
        (0.50, 0.50), (0.29, 0.32), (0.72, 0.29), (0.76, 0.67), (0.28, 0.72),
        (0.49, 0.16), (0.91, 0.47), (0.50, 0.86), (0.09, 0.48)
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Circle().stroke(Color.white.opacity(0.07), lineWidth: 1).frame(width: 110, height: 110)
                Circle().stroke(Color.white.opacity(0.045), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                    .frame(width: 178, height: 178)

                ForEach(Array(skills.enumerated()), id: \.element.identifier) { index, skill in
                    let position = positions[index % positions.count]
                    let isCore = index == 0
                    Button { select(skill) } label: {
                        Text(initials(skill.skill.name))
                            .font(.system(size: isCore ? 15 : 11, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(width: isCore ? 52 : 38, height: isCore ? 52 : 38)
                            .background((skill.trustTier == .remoteVerified ? systemAccent : accent).opacity(isCore ? 0.95 : 0.72), in: Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                            .shadow(color: (skill.trustTier == .remoteVerified ? systemAccent : accent).opacity(0.32), radius: isCore ? 14 : 7)
                    }
                    .buttonStyle(.plain)
                    .help("Priority \(index + 1) · \(skill.skill.name)")
                    .position(x: proxy.size.width * position.0, y: proxy.size.height * position.1)
                    .onHover { hovering in hoveredIdentifier = hovering ? skill.identifier : nil }
                    .pointerCursor()
                }

                if skills.isEmpty {
                    Image(systemName: "circle.dotted")
                        .font(.system(size: 42, weight: .ultraLight))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
        }
    }

    private func initials(_ name: String) -> String {
        name.split { $0 == "-" || $0 == "_" || $0.isWhitespace }
            .prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}
