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
            .foregroundColor(phase == .deployed ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: NotchControlMetrics.controlSize)
        }
        // Borderless like the rest of the notch. A deployed buddy keeps a
        // soft accent fill so "it is out" still reads at a glance.
        .notchSoftButtonStyle(
            .capsule,
            isActive: phase == .deployed,
            activeFill: DS.Colors.accent.opacity(0.22)
        )
        .disabled(!canToggle)
        .help(launcherHelp(for: phase, canToggle: canToggle))
        .accessibilityLabel(launcherTitle(for: phase))
        .accessibilityValue(launcherSubtitle(for: phase))
    }

    private func compactTitle(for phase: CursorDockPhase) -> String {
        switch phase {
        case .docked: return "Show buddy"
        case .launching: return "Launching"
        case .deployed: return "Park buddy"
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

/// The chat's Brain picker: switch between signed-in subscriptions, pick a
/// model and effort. Changes apply at once; signing in lives in Brain.
struct BrainQuickPicker: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var brain = MateAgentSetupController.shared
    @State private var model = ""
    @State private var effort = "medium"
    @State private var speed = "default"

    static func brand(for provider: String) -> AgentBrain? {
        switch provider {
        case "openai-codex": return .codex
        case "anthropic": return .claudeCode
        case "heymate-custom": return .customAPI
        default: return nil
        }
    }
    private var current: MateAgentSetupController.Provider? { brain.providers.first { $0.id == brain.currentProvider } }
    private var models: [String] {
        let all = current?.models ?? []
        return all.reversed().filter { id in
            guard let range = id.range(of: #"-\d{8}$"#, options: .regularExpression) else { return true }
            return !all.contains(String(id[..<range.lowerBound]))
        }
    }
    private var efforts: [String] {
        brain.currentProvider == "heymate-custom" ? ["off", "low", "medium", "high", "max"] : current?.efforts[model] ?? []
    }
    private var speeds: [String] { current?.speeds[model] ?? [] }
    private var locked: Bool { brain.busy || companionManager.isResponseInFlight || companionManager.isMateAgentTurnInFlight }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text("SUBSCRIPTION").font(DS.Fonts.sectionLabel).tracking(0.8).foregroundColor(DS.Colors.textTertiary)
            HStack(spacing: DS.Spacing.xs) {
                ForEach(["openai-codex", "anthropic", "heymate-custom"], id: \.self) { id in
                    providerButton(id)
                }
            }
            if brain.currentProvider == "openai-codex" {
                Button {
                    Task { await brain.check(.load(), refresh: true) }
                } label: { Label("Refresh models", systemImage: "arrow.clockwise") }
                .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                if let warning = brain.catalogWarning {
                    Text(warning).font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                }
            }
            if brain.currentProvider != "heymate-custom", !models.isEmpty {
                Text("MODEL").font(DS.Fonts.sectionLabel).tracking(0.8).foregroundColor(DS.Colors.textTertiary)
                DSMenuPicker(accessibilityTitle: "Model", selection: $model,
                             options: models.map { DSMenuOption(value: $0, title: current?.modelNames[$0] ?? $0) },
                             width: nil)
            }
            if !efforts.isEmpty {
                Text("EFFORT").font(DS.Fonts.sectionLabel).tracking(0.8).foregroundColor(DS.Colors.textTertiary)
                DSSegmentedControl(accessibilityTitle: "Effort", selection: $effort,
                                   segments: efforts.map { DSSegment(value: $0, title: MateAgentSetupPane.effortName($0)) },
                                   width: nil)
            }
            if speeds.count > 1 {
                Text("SPEED").font(DS.Fonts.sectionLabel).tracking(0.8).foregroundColor(DS.Colors.textTertiary)
                DSSegmentedControl(accessibilityTitle: "Speed", selection: $speed,
                    segments: speeds.map { DSSegment(value: $0, title: MateAgentSetupController.speedName($0)) }, width: nil)
                Text("Faster speeds can use more of your plan.").font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
            }
            HStack {
                if brain.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Open Brain…") {
                    companionManager.openDesktopWindow(section: .settings)
                    DesktopSection.openSettings(tab: DesktopSettingsTab.brain.rawValue)
                }.dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
            }
        }
        .padding(DS.Spacing.lg)
        .disabled(locked)
        .task { model = brain.currentModel; effort = brain.currentEffort; speed = brain.currentSpeed; await brain.check(.load()); model = brain.currentModel; effort = brain.currentEffort; speed = brain.currentSpeed }
        .onChange(of: model) {
            speed = model == brain.currentModel ? brain.currentSpeed : "default"
            apply(provider: brain.currentProvider)
        }
        .onChange(of: effort) { apply(provider: brain.currentProvider) }
        .onChange(of: speed) { apply(provider: brain.currentProvider) }
    }

    private func providerButton(_ id: String) -> some View {
        let info = brain.providers.first { $0.id == id }
        let signedIn = info?.authenticated == true
        let selected = brain.currentProvider == id
        return Button {
            guard !selected else { return }
            // A custom API needs its endpoint and key, which live in Brain.
            if signedIn, id != "heymate-custom" { apply(provider: id, model: "") }
            else {
                companionManager.openDesktopWindow(section: .settings)
                DesktopSection.openSettings(tab: DesktopSettingsTab.brain.rawValue)
            }
        } label: {
            VStack(spacing: 4) {
                if let brand = Self.brand(for: id) { AgentBrandMark(brain: brand, size: 18) }
                Text(MateAgentSetupController.providerNames[id] ?? id).font(DS.Fonts.caption)
                Text(signedIn ? (selected ? "In use" : "Switch") : "Sign in")
                    .font(DS.Fonts.micro).foregroundColor(DS.Colors.textTertiary)
            }
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: .infinity).padding(.vertical, DS.Spacing.sm)
            .background(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(selected ? DS.Colors.surface3 : DS.Colors.surface2.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(selected ? DS.Colors.textPrimary.opacity(0.7) : DS.Colors.borderSubtle, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor(isEnabled: !selected)
    }

    /// Saves only real changes; the harness keeps the model's saved effort and clamps it.
    private func apply(provider: String, model chosen: String? = nil) {
        let target = chosen ?? model
        guard !brain.busy, provider != brain.currentProvider || target != brain.currentModel || effort != brain.currentEffort || speed != brain.currentSpeed else { return }
        Task {
            await brain.connect(.load(), provider: provider, model: target, key: "",
                                effort: provider == brain.currentProvider ? effort : "",
                                baseURL: brain.currentBaseURL, apiFormat: brain.currentAPIFormat,
                                speed: provider == brain.currentProvider ? speed : "default")
            await brain.check(.load())
            model = brain.currentModel; effort = brain.currentEffort; speed = brain.currentSpeed
        }
    }
}
