//
//  DriveTakeOverOverlay.swift
//  HeyMate
//
//  What the person sees around a drive: the consent card before it, and
//  while it runs, a frame around every display, a status pill naming the
//  goal and step, and a ring where HeyMate is about to act. There is no
//  silent takeover: if the frame is gone, HeyMate is not driving.
//
//  The frame and pill never take clicks. Only the consent card does.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class DriveTakeOverOverlayModel: ObservableObject {
    @Published var goal = ""
    @Published var applicationName = ""
    @Published var step = 0
    @Published var maxSteps = 0
    @Published var status = ""
    @Published var target: CGPoint?
}

@MainActor
final class DriveTakeOverOverlay {
    let model = DriveTakeOverOverlayModel()
    private var framePanels: [NSPanel] = []
    private var consentPanel: NSPanel?
    private var consentContinuation: CheckedContinuation<Bool, Never>?

    var isShowingDrive: Bool { !framePanels.isEmpty }

    // MARK: Consent

    /// Shows the card and waits for an answer. A second card replaces the
    /// first, which resolves as "not now".
    func requestConsent(goal: String, applicationName: String, origin: String) async -> Bool {
        dismissConsent(answer: false)
        let card = DriveTakeOverConsentCard(
            goal: goal,
            applicationName: applicationName,
            origin: origin,
            onDecline: { [weak self] in self?.dismissConsent(answer: false) },
            onAccept: { [weak self] in self?.dismissConsent(answer: true) }
        )
        let panel = Self.makePanel(interactive: true)
        let hosting = NSHostingView(rootView: card)
        hosting.frame.size = hosting.fittingSize
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let size = hosting.fittingSize
            panel.setFrameOrigin(CGPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.visibleFrame.maxY - size.height - 24
            ))
        }
        consentPanel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
        NSSound(named: "Tink")?.play()
        return await withCheckedContinuation { consentContinuation = $0 }
    }

    func dismissConsent(answer: Bool) {
        consentPanel?.orderOut(nil)
        consentPanel = nil
        consentContinuation?.resume(returning: answer)
        consentContinuation = nil
    }

    // MARK: Driving

    func showDrive(goal: String, applicationName: String, maxSteps: Int) {
        model.goal = goal
        model.applicationName = applicationName
        model.maxSteps = maxSteps
        model.step = 0
        model.status = "Starting"
        model.target = nil
        hideDrive()
        guard !HeyMateDataDirectory.isUnitTestHost else { return }
        for (index, screen) in NSScreen.screens.enumerated() {
            let panel = Self.makePanel(interactive: false)
            panel.setFrame(screen.frame, display: false)
            panel.contentView = NSHostingView(rootView: DriveFrameView(
                model: model,
                screenFrame: screen.frame,
                showsPill: index == 0
            ))
            panel.orderFrontRegardless()
            framePanels.append(panel)
        }
    }

    func update(step: Int, status: String) {
        model.step = step
        model.status = status
    }

    /// Marks where the next action lands, in AppKit global coordinates.
    func showTarget(_ point: CGPoint) {
        model.target = point
    }

    func hideDrive() {
        framePanels.forEach { $0.orderOut(nil) }
        framePanels.removeAll()
        model.target = nil
    }

    private static func makePanel(interactive: Bool) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: interactive ? [.borderless, .nonactivatingPanel] : [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = interactive
        panel.level = interactive ? .popUpMenu : .statusBar
        panel.ignoresMouseEvents = !interactive
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        // Screenshots taken mid-drive should show the app, not HeyMate's frame.
        panel.sharingType = .none
        return panel
    }
}

/// "Can I take over?" Asked before every drive. Never the Return key's
/// default for "Take over": a stray keypress must not hand over the Mac.
struct DriveTakeOverConsentCard: View {
    let goal: String
    let applicationName: String
    let origin: String
    let onDecline: () -> Void
    let onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "cursorarrow.motionlines")
                    .font(DS.Glyph.regular)
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Let HeyMate take over?")
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer(minLength: 0)
                if !applicationName.isEmpty {
                    Text(applicationName)
                        .font(DS.Fonts.statusWord)
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, DS.Spacing.sm)
                        .padding(.vertical, 3)
                        .background(Capsule(style: .continuous).fill(DS.Colors.surface3))
                }
            }
            Text(goal)
                .font(DS.Fonts.title)
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("I'll click and type in \(applicationName.isEmpty ? "that app" : applicationName) until it's done. Move the mouse, click, type, or press Esc to take it back at any time. I won't send, pay, or delete anything.")
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if origin == "agent" || origin == "bridge" {
                Text("Asked by an agent working for you.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            HStack(spacing: DS.Spacing.sm) {
                Spacer(minLength: 0)
                Button("Not now", action: onDecline)
                    .buttonStyle(DSSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Take over", action: onAccept)
                    .buttonStyle(DSPrimaryButtonStyle())
            }
        }
        .padding(DS.Spacing.lg)
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.borderStrong, lineWidth: 1)
        )
    }
}

/// The frame around one display while a drive runs.
private struct DriveFrameView: View {
    @ObservedObject var model: DriveTakeOverOverlayModel
    let screenFrame: CGRect
    let showsPill: Bool
    @State private var pulse = false

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(DS.Colors.textPrimary.opacity(pulse ? 0.85 : 0.45), lineWidth: 3)
                .padding(2)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)

            if showsPill {
                HStack(spacing: DS.Spacing.sm) {
                    Circle().fill(DS.Colors.textPrimary).frame(width: 7, height: 7)
                    Text("HeyMate is driving \(model.applicationName)")
                        .font(DS.Fonts.titleCompact)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("step \(model.step)/\(model.maxSteps)")
                        .font(DS.Fonts.numeric)
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("·").foregroundColor(DS.Colors.textTertiary)
                    Text(model.status)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: 320, alignment: .leading)
                    Text("Move the mouse to take back")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .background(Capsule(style: .continuous).fill(DS.Colors.surface1.opacity(0.94)))
                .overlay(Capsule(style: .continuous).stroke(DS.Colors.borderStrong, lineWidth: 1))
                .padding(.top, 40)
            }

            if let target = model.target, screenFrame.contains(target) {
                Circle()
                    .stroke(DS.Colors.textPrimary, lineWidth: 2.5)
                    .frame(width: 34, height: 34)
                    .position(x: target.x - screenFrame.minX, y: screenFrame.maxY - target.y)
                    .transition(.opacity)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .onAppear { pulse = true }
    }
}
