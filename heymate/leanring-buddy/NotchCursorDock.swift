//
//  NotchCursorDock.swift
//  leanring-buddy
//
//  Compact rocket launch bay in the expanded notch footer. Its glyph reports
//  a live screen-space anchor so overlay flight starts and ends on the bay.
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
                    .frame(width: 18, height: 18)
                    .background {
                        DockScreenAnchorReader { point in
                            companionManager.updateCursorDockAnchorScreenPoint(point)
                        }
                    }

                Text(compactTitle(for: phase))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundColor(phase == .deployed ? DS.Colors.textOnAccent : DS.Colors.textPrimary.opacity(0.85))
            .padding(.horizontal, 8)
            .frame(height: 22)
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

    func makeNSView(context: Context) -> DockScreenAnchorView {
        let view = DockScreenAnchorView()
        view.onAnchorChange = onAnchorChange
        return view
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
        guard let window else { return }
        let centerInWindow = convert(
            CGPoint(x: bounds.midX, y: bounds.midY),
            to: nil
        )
        onAnchorChange?(window.convertPoint(toScreen: centerInWindow))
    }
}

private struct RocketLaunchBayGlyph: View {
    let phase: CursorDockPhase

    private var rocketOffset: CGFloat {
        switch phase {
        case .docked, .returning: return 1
        case .launching, .deployed: return 8
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(DS.Colors.surface4)
                .frame(width: 17, height: 3)
                .offset(x: 1, y: 6)

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(DS.Colors.surface4)
                .frame(width: 5, height: 10)
                .offset(x: 0, y: 0)

            Image(systemName: "paperplane.fill")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(-42))
                .foregroundColor(
                    phase == .docked
                        ? DS.Colors.textSecondary
                        : DS.Colors.accent
                )
                .shadow(
                    color: DS.Colors.accent.opacity(phase == .docked ? 0 : 0.7),
                    radius: 5
                )
                .offset(x: rocketOffset, y: -1)

            HStack(spacing: 2) {
                Circle().fill(Color.white.opacity(0.9)).frame(width: 2.5, height: 2.5)
                Circle().fill(DS.Colors.accent.opacity(0.65)).frame(width: 3, height: 3)
            }
            .offset(x: max(5, rocketOffset - 3), y: 8)
            .opacity(phase.isTransitioning ? 1 : 0)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: phase)
    }
}

struct NotchModelPickerPanel: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                ForEach(AgentBrain.allCases, id: \.self) { brain in
                    brainButton(brain)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DS.Colors.surface2.opacity(0.72))
            )

            Text(companionManager.selectedBrain.subtitle)
                .font(DS.Fonts.micro)
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            modelChoices
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DS.Colors.surface2.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 0.5)
        )
        .task {
            if companionManager.selectedBrain == .openCode {
                await companionManager.refreshOpenCodeServerStatus()
            } else if companionManager.selectedBrain == .codex {
                await companionManager.refreshCodexModelCatalog()
            }
        }
        .onChange(of: companionManager.selectedBrain) { _, brain in
            if brain != .openCode {
                searchText = ""
            }
            if brain == .codex {
                Task { await companionManager.refreshCodexModelCatalog() }
            }
        }
    }

    private func brainButton(_ brain: AgentBrain) -> some View {
        let isSelected = companionManager.selectedBrain == brain
        return Button(action: { companionManager.setSelectedBrain(brain) }) {
            Text(brain.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? DS.Colors.surface4 : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    @ViewBuilder
    private var modelChoices: some View {
        switch companionManager.selectedBrain {
        case .openCode:
            openCodeModelList
        case .claudeCode:
            HStack(spacing: 0) {
                ForEach(ClaudeModelChoice.allCases, id: \.self) { choice in
                    brainButtonLabel(
                        choice.displayName,
                        isSelected: companionManager.selectedClaudeModel == choice,
                        action: { companionManager.setSelectedClaudeModel(choice) }
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DS.Colors.surface2.opacity(0.72))
            )
        case .codex:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Models from Codex CLI")
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                    Spacer()
                    Button {
                        Task { await companionManager.refreshCodexModelCatalog() }
                    } label: {
                        if companionManager.isCodexModelRefreshInFlight {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }

                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 4) {
                        ForEach(companionManager.codexModels) { option in
                            brainButtonLabel(
                                option.displayName,
                                isSelected: companionManager.selectedCodexModelID == option.model,
                                action: { companionManager.setSelectedCodexModel(option) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 120)

                if let selectedModel = companionManager.selectedCodexModel {
                    Text("Effort")
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                    HStack(spacing: 0) {
                        ForEach(selectedModel.supportedReasoningEfforts) { option in
                            brainButtonLabel(
                                option.displayName,
                                isSelected: companionManager.selectedCodexReasoningEffort == option.reasoningEffort,
                                action: {
                                    companionManager.setSelectedCodexReasoningEffort(option.reasoningEffort)
                                }
                            )
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(DS.Colors.surface2.opacity(0.72))
                    )
                }

                if let errorText = companionManager.codexModelCatalogErrorText {
                    Text(errorText)
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.warningText)
                }
            }
        case .customAPI:
            Text(CustomAPIConfiguration.model)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func brainButtonLabel(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? DS.Colors.surface4 : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    @ViewBuilder
    private var openCodeModelList: some View {
        if companionManager.openCodeModels.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
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
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
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
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.Colors.surface2.opacity(0.72))
                )

                HStack(spacing: 4) {
                    Text(visibleCount == companionManager.openCodeModels.count
                         ? "\(visibleCount) models"
                         : "\(visibleCount) of \(companionManager.openCodeModels.count)")
                    Text("·")
                    Text("scroll")
                }
                .font(DS.Fonts.micro)
                .foregroundColor(DS.Colors.textTertiary)

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
                                        Text(group.providerName.uppercased())
                                            .font(.system(size: 9, weight: .bold, design: .rounded))
                                            .foregroundColor(DS.Colors.textTertiary)
                                            .kerning(0.8)
                                        Spacer()
                                        Text("\(group.models.count)")
                                            .font(.system(size: 9, weight: .semibold))
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
                .font(.system(size: 10, weight: .semibold))
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
        return Button(action: { companionManager.selectOpenCodeModel(option) }) {
            HStack {
                Text(option.shortLabel)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(DS.Colors.accentText)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? DS.Colors.accentSubtle : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
