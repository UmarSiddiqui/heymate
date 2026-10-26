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

struct NotchModelPickerPanel: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var searchText = ""
    @State private var hoveredBrain: AgentBrain?
    @State private var hoveredCodexModelID: String?
    @State private var hoveredClaudeModelID: String?
    @State private var hoveredOpenCodeModelID: String?

    var body: some View {

            VStack(alignment: .leading, spacing: 12) {
                Text("HeyMate Agent").font(DS.Fonts.titleCompact)
                Text("Choose your plan or API provider and model in Brain.")
                    .font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                Button("Brain…") {
                    companionManager.openDesktopWindow(section: .settings)
                    DesktopSection.openSettings(tab: DesktopSettingsTab.brain.rawValue)
                }.dsCapsuleButtonStyle(.secondary)
                Spacer()
            }.padding(16)

    }

}
