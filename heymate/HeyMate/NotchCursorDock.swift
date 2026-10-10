//
//  NotchCursorDock.swift
//  HeyMate
//
//  Cursor dock in the expanded notch footer. The docked buddy cursor sits in
//  the bay, and its glyph reports a live screen-space anchor so overlay
//  flight starts and ends exactly on it.
//

import AppKit
import SwiftUI

struct NotchCursorDock: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        rocketLauncherControl
    }

    private var rocketLauncherControl: some View {
        let phase = companionManager.cursorDockPhase
        let canToggle = phase.acceptsDeploymentToggle && companionManager.voiceState == .idle

        return Button(action: {
            companionManager.toggleCursorDeployment()
        }) {
            HStack(spacing: 5) {
                RocketLaunchBayGlyph(phase: phase)
                    .frame(width: 20, height: 20)
                    .background {
                        DockScreenAnchorReader(
                            onAnchorChange: { point in
                                companionManager.updateCursorDockAnchorScreenPoint(point)
                            },
                            onProviderChange: { provider in
                                companionManager.setCursorDockAnchorProvider(provider)
                            }
                        )
                    }

                Text(compactTitle(for: phase))
                    .font(DS.Fonts.control)
                    .lineLimit(1)
            }
            .foregroundColor(phase == .deployed ? DS.Colors.textOnAccent : DS.Colors.textPrimary.opacity(0.85))
            .padding(.horizontal, 12)
            .frame(height: NotchControlMetrics.controlSize)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        phase == .deployed
                            ? DS.Colors.accent.opacity(0.30)
                            : DS.Colors.surface3.opacity(0.7)
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        phase == .deployed
                            ? DS.Colors.accent.opacity(0.65)
                            : DS.Colors.borderStrong.opacity(0.5),
                        lineWidth: 0.8
                    )
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(!canToggle)
        .help(launcherHelp(for: phase, canToggle: canToggle))
        .accessibilityLabel(launcherTitle(for: phase))
        .accessibilityValue(launcherSubtitle(for: phase))
    }

    private func compactTitle(for phase: CursorDockPhase) -> String {
        switch phase {
        case .docked: return "Undock"
        case .launching: return "Launching"
        case .deployed: return "Dock"
        case .returning: return "Docking"
        }
    }

    private func launcherTitle(for phase: CursorDockPhase) -> String {
        switch phase {
        case .docked: return "Launch buddy"
        case .launching: return "Igniting…"
        case .deployed: return "Recall buddy"
        case .returning: return "Docking…"
        }
    }

    private func launcherSubtitle(for phase: CursorDockPhase) -> String {
        switch phase {
        case .docked: return "Deploy beside pointer"
        case .launching: return "Leaving launch bay"
        case .deployed: return "Flying beside pointer"
        case .returning: return "Returning to dock"
        }
    }

    private func launcherHelp(for phase: CursorDockPhase, canToggle: Bool) -> String {
        if !canToggle && !phase.isTransitioning {
            return "Finish current voice interaction first"
        }
        switch phase {
        case .docked: return "Launch cursor buddy from this dock"
        case .launching: return "Cursor buddy is launching"
        case .deployed: return "Recall cursor buddy to this dock"
        case .returning: return "Cursor buddy is returning"
        }
    }

}

private struct DockScreenAnchorReader: NSViewRepresentable {
    let onAnchorChange: (CGPoint) -> Void
    let onProviderChange: ((() -> CGPoint?)?) -> Void

    func makeNSView(context: Context) -> DockScreenAnchorView {
        let view = DockScreenAnchorView()
        view.onAnchorChange = onAnchorChange
        onProviderChange { [weak view] in view?.currentAnchor() }
        return view
    }

    static func dismantleNSView(_ nsView: DockScreenAnchorView, coordinator: ()) {
        nsView.onAnchorChange = nil
    }

    func updateNSView(_ nsView: DockScreenAnchorView, context: Context) {
        nsView.onAnchorChange = onAnchorChange
        nsView.reportAnchor()
    }
}

private final class DockScreenAnchorView: NSView {
    var onAnchorChange: ((CGPoint) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.reportAnchor() }
    }

    override func layout() {
        super.layout()
        reportAnchor()
    }

    func reportAnchor() {
        guard let anchor = currentAnchor() else { return }
        onAnchorChange?(anchor)
    }

    /// Center of the glyph in screen coordinates right now. Nil while the
    /// notch is collapsed and the glyph is off screen.
    func currentAnchor() -> CGPoint? {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return nil }
        let centerInWindow = convert(
            CGPoint(x: bounds.midX, y: bounds.midY),
            to: nil
        )
        return window.convertPoint(toScreen: centerInWindow)
    }
}

/// The bay the buddy cursor lives in while docked. It draws the exact cursor
/// the overlay flies (same shape, size, rest angle and glow), so a return
/// flight lands on it and an undock lifts off from it without a visible swap.
private struct RocketLaunchBayGlyph: View {
    let phase: CursorDockPhase

    var body: some View {
        ZStack {
            Circle()
                .stroke(DS.Colors.borderStrong.opacity(phase == .docked ? 0 : 0.6), lineWidth: 0.8)
                .frame(width: 14, height: 14)

            CompanionCursorGlyph()
                .opacity(phase == .docked ? 1 : 0)
        }
    }
}

struct NotchModelPickerPanel: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var searchText = ""
    @State private var hoveredBrain: AgentBrain?
    @State private var hoveredCodexModelID: String?
    @State private var hoveredClaudeModelID: String?
    @State private var hoveredOpenCodeModelID: String?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            providerRail

            Rectangle()
                .fill(DS.Colors.borderSubtle.opacity(0.8))
                .frame(width: 1)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 9) {
                providerSummary
                modelChoices
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle.opacity(0.8), lineWidth: 1)
        )
        .task {
            await companionManager.refreshClaudeModelCatalog()
            await companionManager.refreshCodexModelCatalog()
            await companionManager.refreshOpenCodeServerStatus()
        }
        .onChange(of: companionManager.selectedBrain) { _, brain in
            if brain != .openCode {
                searchText = ""
            }
            if brain == .codex {
                Task { await companionManager.refreshCodexModelCatalog() }
            } else if brain == .openCode {
                Task { await companionManager.refreshOpenCodeServerStatus() }
            } else if brain == .claudeCode {
                Task { await companionManager.refreshClaudeModelCatalog() }
            }
        }
    }

    private var providerRail: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Provider")
                .font(DS.Fonts.sectionLabel)
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 7)
                .padding(.bottom, 2)

            ForEach(AgentBrain.allCases, id: \.self) { brain in
                providerButton(brain)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 142)
        .padding(.trailing, 10)
    }

    private func providerButton(_ brain: AgentBrain) -> some View {
        let isSelected = companionManager.selectedBrain == brain
        let isHovered = hoveredBrain == brain
        return Button(action: { companionManager.setSelectedBrain(brain) }) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(isSelected ? DS.Colors.accentSubtle : DS.Colors.surface3)
                    Image(systemName: providerSymbol(for: brain))
                        .font(DS.Glyph.small)
                        .foregroundColor(isSelected ? DS.Colors.accentText : DS.Colors.textTertiary)
                }
                .frame(width: 24, height: 24)

                Text(brain.displayName)
                    .font(DS.Fonts.caption.weight(.semibold))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 2)

                Circle()
                    .fill(DS.Colors.accent)
                    .frame(width: 5, height: 5)
                    .shadow(color: DS.Colors.accentGlow, radius: 4)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 7)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(isSelected ? DS.Colors.accentSubtle : (isHovered ? DS.Colors.surface3 : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .stroke(isSelected ? DS.Colors.accent.opacity(0.32) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hoveredBrain = $0 ? brain : nil }
        .accessibilityLabel(brain.displayName)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var providerSummary: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(companionManager.selectedBrain.displayName)
                    .font(DS.Fonts.titleCompact)
                    .foregroundColor(DS.Colors.textPrimary)

                Text(companionManager.selectedBrain.subtitle)
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            if companionManager.selectedBrain != .customAPI {
                updateCLIButton
            }

            HStack(spacing: 4) {
                Circle()
                    .fill(DS.Colors.accent)
                    .frame(width: 5, height: 5)
                Text("Selected")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                Capsule(style: .continuous)
                    .fill(DS.Colors.surface2)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var modelChoices: some View {
        switch companionManager.selectedBrain {
        case .openCode:
            openCodeModelList
        case .claudeCode:
            claudeChoices
        case .codex:
            codexChoices
        case .customAPI:
            customAPIChoice
        case .onDevice:
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("On this Mac", detail: "Apple Intelligence")
                Text(OnDeviceLanguageAvailability.statusLine)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var claudeChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            claudeEffortPanel
            claudeModelList
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var claudeEffortPanel: some View {
        if !companionManager.claudeEfforts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Thinking effort")

                HStack(spacing: 3) {
                    effortSegment(
                        title: "Auto",
                        help: "Let the Claude CLI pick its default effort",
                        isSelected: companionManager.selectedClaudeEffortIfSupported == nil
                    ) {
                        companionManager.setSelectedClaudeEffort("")
                    }
                    ForEach(companionManager.claudeEfforts) { option in
                        effortSegment(
                            title: option.displayName,
                            help: "claude --effort \(option.effort)",
                            isSelected: companionManager.selectedClaudeEffortIfSupported == option.effort
                        ) {
                            companionManager.setSelectedClaudeEffort(option.effort)
                        }
                    }
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )

                Text("Higher effort thinks longer before answering. Applies to Talk and agent jobs.")
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var claudeModelList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionHeader("Model", detail: "From Claude CLI")
                Spacer(minLength: 4)
                catalogRefreshButton(
                    isRefreshing: companionManager.isClaudeModelRefreshInFlight,
                    help: "Reload models from Claude CLI",
                    accessibilityLabel: "Reload Claude models"
                ) {
                    await companionManager.refreshClaudeModelCatalog()
                }
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 5) {
                    ForEach(companionManager.claudeModels) { option in
                        claudeModelButton(option)
                    }
                }
                .padding(.trailing, 2)
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: .infinity)

            if let errorText = companionManager.claudeModelCatalogErrorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.warningText)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var codexChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            codexEffortPanel
            codexModelList
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var codexModelList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionHeader("Model", detail: "From Codex CLI")
                Spacer(minLength: 4)
                codexRefreshButton
            }

            if companionManager.codexModels.isEmpty && companionManager.isCodexModelRefreshInFlight {
                loadingState("Loading models…")
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 5) {
                            ForEach(companionManager.codexModels) { option in
                                codexModelButton(option)
                                    .id(option.model)
                            }
                        }
                        .padding(.trailing, 2)
                    }
                    .scrollIndicators(.visible)
                    .frame(maxHeight: .infinity)
                    .onAppear {
                        DispatchQueue.main.async {
                            proxy.scrollTo(companionManager.selectedCodexModelID, anchor: .center)
                        }
                    }
                    .onChange(of: companionManager.selectedCodexModelID) { _, modelID in
                        withAnimation(DS.Animation.controlSpring) {
                            proxy.scrollTo(modelID, anchor: .center)
                        }
                    }
                    .onChange(of: companionManager.codexModels.count) { _, _ in
                        DispatchQueue.main.async {
                            proxy.scrollTo(companionManager.selectedCodexModelID, anchor: .center)
                        }
                    }
                }
            }

            if let errorText = companionManager.codexModelCatalogErrorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.warningText)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var codexEffortPanel: some View {
        if let selectedModel = companionManager.selectedCodexModel {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Thinking effort")

                HStack(spacing: 3) {
                    ForEach(selectedModel.supportedReasoningEfforts) { option in
                        effortButton(option)
                    }
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )

                if let selectedEffort = selectedModel.supportedReasoningEfforts.first(where: {
                    $0.reasoningEffort == companionManager.selectedCodexReasoningEffort
                }) {
                    Text(selectedEffort.description)
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var codexRefreshButton: some View {
        catalogRefreshButton(
            isRefreshing: companionManager.isCodexModelRefreshInFlight,
            help: "Reload models from Codex CLI",
            accessibilityLabel: "Reload Codex models"
        ) {
            await companionManager.refreshCodexModelCatalog()
        }
    }

    private func catalogRefreshButton(
        isRefreshing: Bool,
        help: String,
        accessibilityLabel: String,
        refresh: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await refresh() }
        } label: {
            Group {
                if isRefreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(DS.Glyph.regular)
                }
            }
            .foregroundColor(DS.Colors.textSecondary)
            .frame(width: 28, height: 28)
            .contentShape(Circle())
            .background(Circle().fill(DS.Colors.surface2))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(isRefreshing)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }

    private func codexModelButton(_ option: CodexModelOption) -> some View {
        let isSelected = companionManager.selectedCodexModelID == option.model
        let isHovered = hoveredCodexModelID == option.id
        return Button(action: { companionManager.setSelectedCodexModel(option) }) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(option.displayName)
                            .font(DS.Fonts.caption.weight(.semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)

                        if option.isDefault {
                            Text("Default")
                                .font(DS.Fonts.keycap)
                                .foregroundColor(DS.Colors.textTertiary)
                                .padding(.horizontal, 6)
                                .frame(height: 17)
                                .background(Capsule().fill(DS.Colors.surface3))
                        }
                    }

                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(DS.Fonts.micro)
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)
                selectionMark(isSelected: isSelected)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectionBackground(isSelected: isSelected, isHovered: isHovered))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hoveredCodexModelID = $0 ? option.id : nil }
        .accessibilityLabel(option.displayName)
        .accessibilityHint(option.description)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func effortButton(_ option: CodexReasoningEffortOption) -> some View {
        effortSegment(
            title: option.displayName,
            help: option.description,
            isSelected: companionManager.selectedCodexReasoningEffort == option.reasoningEffort
        ) {
            companionManager.setSelectedCodexReasoningEffort(option.reasoningEffort)
        }
    }

    /// One cell of the effort control. Claude and Codex share it so both
    /// engines read the same way.
    private func effortSegment(
        title: String,
        help: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.Fonts.micro.weight(isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .frame(height: 25)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(isSelected ? DS.Colors.surface4 : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
        .accessibilityLabel("\(title) thinking effort")
        .accessibilityHint(help)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func claudeModelButton(_ option: ClaudeModelOption) -> some View {
        let isSelected = companionManager.selectedClaudeModelID == option.id
        let isHovered = hoveredClaudeModelID == option.id
        return Button(action: { companionManager.setSelectedClaudeModel(option) }) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.displayName)
                        .font(DS.Fonts.caption.weight(.semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(option.isLatestAlias ? "Latest" : option.summary)
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                selectionMark(isSelected: isSelected)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectionBackground(isSelected: isSelected, isHovered: isHovered))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hoveredClaudeModelID = $0 ? option.id : nil }
        .accessibilityLabel(option.displayName)
        .accessibilityHint(option.summary)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var customAPIChoice: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Configured model", detail: "Anthropic-compatible endpoint")

            HStack(spacing: 9) {
                Image(systemName: "network")
                    .font(DS.Glyph.regular)
                    .foregroundColor(DS.Colors.accentText)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(DS.Colors.accentSubtle))

                VStack(alignment: .leading, spacing: 2) {
                    Text(CustomAPIConfiguration.model)
                        .font(DS.Fonts.caption.weight(.semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text("Model and credentials are managed in Settings.")
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                }

                Spacer(minLength: 4)

                Button("Settings") {
                    companionManager.openDesktopWindow(section: .settings)
                }
                .font(DS.Fonts.micro.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundColor(DS.Colors.accentText)
                .pointerCursor()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var openCodeModelList: some View {
        if companionManager.openCodeModels.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Model", detail: "From opencode serve")
                HStack(spacing: 8) {
                    Text(companionManager.isOpenCodeServerReachable == false
                         ? "OpenCode server is offline"
                         : "No models yet — start `opencode serve`")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    refreshButton
                }
                Text("For Codex: opencode auth login → ChatGPT Plus/Pro, then opencode serve.")
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            let groups = companionManager.openCodeProviderGroups(matching: searchText)
            let visibleCount = groups.flatMap(\.models).count
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Model", detail: "\(visibleCount) of \(companionManager.openCodeModels.count) available")

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(DS.Glyph.small)
                        .foregroundColor(DS.Colors.textTertiary)
                    TextField(
                        "Search \(companionManager.openCodeModels.count) models",
                        text: $searchText
                    )
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textPrimary)
                    refreshButton
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.surface2)
                )

                if groups.isEmpty {
                    Text("No models match “\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))”")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.top, 8)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(groups, id: \.providerID) { group in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(group.providerName)
                                            .font(DS.Fonts.sectionLabel)
                                            .foregroundColor(DS.Colors.textTertiary)
                                        Spacer()
                                        Text("\(group.models.count)")
                                            .font(DS.Fonts.keycap)
                                            .foregroundColor(DS.Colors.textTertiary.opacity(0.7))
                                    }
                                    .padding(.horizontal, 4)

                                    ForEach(group.models) { option in
                                        openCodeRow(option)
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .scrollIndicators(.visible)
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var refreshButton: some View {
        Button(action: {
            Task { await companionManager.refreshOpenCodeServerStatus() }
        }) {
            Image(systemName: "arrow.clockwise")
                .font(DS.Glyph.small)
                .foregroundColor(DS.Colors.textSecondary)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(companionManager.isOpenCodeRefreshInFlight)
        .help("Reload models from opencode serve")
    }

    private func openCodeRow(_ option: OpenCodeModelOption) -> some View {
        let isSelected = option.modelID == companionManager.openCodeModelID
            && option.providerID == companionManager.openCodeProviderID
        let isHovered = hoveredOpenCodeModelID == option.id
        return Button(action: { companionManager.selectOpenCodeModel(option) }) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.shortLabel)
                        .font(DS.Fonts.caption.weight(.semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    if OpenCodeTrainingPolicy.dataUse(
                        providerID: option.providerID,
                        modelID: option.modelID,
                        modelName: option.modelName
                    ) != .notFlagged {
                        Text("Trains")
                            .font(DS.Fonts.micro)
                            .foregroundColor(DS.Colors.warningText)
                    }
                    if option.modelName != option.modelID {
                        Text(option.modelID)
                            .font(DS.Fonts.micro)
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                selectionMark(isSelected: isSelected)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selectionBackground(isSelected: isSelected, isHovered: isHovered))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hoveredOpenCodeModelID = $0 ? option.id : nil }
        .accessibilityLabel("\(option.shortLabel), \(option.providerName)")
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var updateCLIButton: some View {
        Button {
            Task { await companionManager.updateSubscriptionCLIsNow() }
        } label: {
            HStack(spacing: 4) {
                if companionManager.isSubscriptionCLIUpdateInFlight {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(DS.Glyph.small)
                }
                Text("Update CLI")
                    .font(DS.Fonts.caption.weight(.semibold))
            }
            .foregroundColor(DS.Colors.accentText)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .contentShape(Capsule())
            .background(
                Capsule(style: .continuous)
                    .fill(DS.Colors.surface2)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(companionManager.isSubscriptionCLIUpdateInFlight)
        .help("Update Claude, Codex, and OpenCode to the latest release")
        .accessibilityLabel("Update CLIs to the latest")
    }

    private func sectionHeader(_ title: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(DS.Fonts.sectionLabel)
                .foregroundColor(DS.Colors.textSecondary)
            if let detail {
                Text(detail)
                    .font(DS.Fonts.micro)
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private func selectionMark(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(isSelected ? DS.Colors.accent : DS.Colors.borderStrong, lineWidth: 1)
            if isSelected {
                Circle()
                    .fill(DS.Colors.accent)
                    .padding(3)
            }
        }
        .frame(width: 14, height: 14)
    }

    private func selectionBackground(isSelected: Bool, isHovered: Bool) -> some View {
        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
            .fill(isSelected ? DS.Colors.accentSubtle : (isHovered ? DS.Colors.surface3 : DS.Colors.surface2.opacity(0.66)))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .stroke(isSelected ? DS.Colors.accent.opacity(0.36) : DS.Colors.borderSubtle.opacity(0.7), lineWidth: 1)
            )
    }

    private func loadingState(_ title: String) -> some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.mini)
            Text(title)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func providerSymbol(for brain: AgentBrain) -> String {
        switch brain {
        case .codex: return "cpu"
        case .claudeCode: return "sparkles"
        case .openCode: return "terminal"
        case .customAPI: return "network"
        case .onDevice: return "apple.intelligence"
        }
    }

}
