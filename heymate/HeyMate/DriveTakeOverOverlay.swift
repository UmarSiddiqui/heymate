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
        // The ask grows out of the notch: flush with the top of the screen
        // that has the camera housing, its black top merging into it.
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
        let card = DriveTakeOverConsentCard(
            goal: goal,
            applicationName: applicationName,
            origin: origin,
            topInset: max(screen?.safeAreaInsets.top ?? 0, NSStatusBar.system.thickness),
            onDecline: { [weak self] in self?.dismissConsent(answer: false) },
            onAccept: { [weak self] in self?.dismissConsent(answer: true) }
        )
        let panel = Self.makePanel(interactive: true)
        panel.hasShadow = false
        let hosting = NSHostingView(rootView: card)
        hosting.frame.size = hosting.fittingSize
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        if let screen {
            let size = hosting.fittingSize
            panel.setFrameOrigin(CGPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - size.height
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

/// "Can I take over?" Asked before every drive, as a shelf hanging from the
/// notch: the app, a one-line ask, and the two answers. The take-back rule
/// is a caption, with the rest on hover. Never the Return key's default
/// for "Take over": a stray keypress must not hand over the Mac.
struct DriveTakeOverConsentCard: View {
    let goal: String
    let applicationName: String
    let origin: String
    /// Height hidden behind the camera housing and menu bar.
    var topInset: CGFloat = 0
    let onDecline: () -> Void
    let onAccept: () -> Void

    @State private var isHovered = false

    /// The goal is written as the end state ("998633 is entered"), so the
    /// ask reads "Use Calculator until 998633 is entered?".
    private var ask: String { Self.ask(goal: goal) }

    static func ask(goal: String) -> String {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmed.isEmpty else { return "Take over?" }
        // Only plain lead words drop their capital; names ("Safari") and
        // acronyms ("PDF") stay as written.
        let firstWord = trimmed.prefix { $0.isLetter }
        let plain: Set<Substring> = ["The", "A", "An", "This", "That", "These", "Those", "It", "Its", "Your", "My", "There", "Each", "Every", "All"]
        let sentence = plain.contains(firstWord) ? firstWord.lowercased() + trimmed.dropFirst(firstWord.count) : trimmed
        return "until \(sentence)?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: DS.Spacing.sm) {
                Image(systemName: "cursorarrow.motionlines")
                    .font(DS.Glyph.regular)
                    .foregroundColor(DS.Colors.textPrimary)
                    .accessibilityHidden(true)
                Text("Use")
                    .font(DS.Fonts.bodyLarge)
                    .foregroundColor(DS.Colors.textSecondary)
                Text(applicationName.isEmpty ? "this app" : applicationName)
                    .font(DS.Fonts.statusWord)
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, DS.Spacing.sm)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous).fill(DS.Colors.surface3))
                Text(ask)
                    .font(DS.Fonts.bodyLarge)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Not now", action: onDecline)
                    .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.regular)
                    .keyboardShortcut(.cancelAction)
                Button("Take over", action: onAccept)
                    .dsCapsuleButtonStyle(.primary, height: DS.ControlSize.regular)
            }
            Text(caption)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
                .padding(.leading, 26)
        }
        .padding(.top, topInset + 8)
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.bottom, 12)
        .frame(width: 600)
        .background(
            UnevenRoundedRectangle(
                bottomLeadingRadius: DS.CornerRadius.extraLarge,
                bottomTrailingRadius: DS.CornerRadius.extraLarge,
                style: .continuous
            )
            .fill(Color.black)
        )
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Let HeyMate use \(applicationName.isEmpty ? "this app" : applicationName) \(ask)")
    }

    private var caption: String {
        var parts = ["Move the mouse or press Esc to take it back"]
        if isHovered { parts.append("Never sends, pays, or deletes") }
        if origin == "agent" || origin == "bridge" { parts.append("Asked by an agent working for you") }
        return parts.joined(separator: " · ")
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
