//
//  HeyMateDesktopWindowController.swift
//  HeyMate
//
//  The full HeyMate desktop app — a real, native macOS window, opened from
//  the notch.
//
//  Why this lives in the same process rather than a second bundle: every
//  permission HeyMate holds (Screen Recording, Accessibility, Microphone,
//  Input Monitoring) is granted per code signature. A separate desktop
//  binary would need the user to grant all of them a second time, and the
//  two processes would then fight over the same CGEvent taps and audio
//  device. One process, two surfaces — the notch for ambient work, this
//  window for everything that needs room.
//
//  Activation policy is switched to `.regular` while the window is open so
//  it behaves like an ordinary app (Dock icon, standard menu bar, Cmd-Tab)
//  and back to `.accessory` when it closes so HeyMate returns to being
//  invisible. That switch is the whole trick to "menu-bar app with a real
//  window" on macOS.
//

import AppKit
import SwiftUI

@MainActor
final class HeyMateDesktopWindowController: NSObject, NSWindowDelegate {

    /// Big enough for a sidebar plus a content column at a comfortable
    /// reading measure, small enough to open on a 13-inch display.
    private static let defaultContentSize = CGSize(width: 1_240, height: 800)
    private static let minimumContentSize = CGSize(width: 960, height: 620)

    /// Frame autosave name so macOS restores the user's size and position.
    private static let frameAutosaveName = "HeyMateDesktopWindow"

    private var window: NSWindow?
    private weak var companionManager: CompanionManager?
    private var deactivationObserver: NSObjectProtocol?
    /// True while the window is being rebuilt for the other placement, so
    /// its close doesn't restore the resting activation policy.
    private var isSwitchingPlacement = false

    /// What the app's activation policy was before we made the window
    /// visible, so closing restores exactly that rather than assuming.
    private var activationPolicyBeforeShowing: NSApplication.ActivationPolicy?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
    }

    var isVisible: Bool { window?.isVisible == true }

    /// True while the panel hanging from the notch is on screen.
    var isAttachedPanelVisible: Bool { (window as? AttachedDesktopPanel)?.isVisible == true }

    /// The attached panel and the notch card share the notch, so only one
    /// is open at a time. A detached window is left alone.
    func foldAttachedPanel() {
        guard let panel = window as? AttachedDesktopPanel, panel.isVisible else { return }
        panel.close()
    }

    // MARK: Presentation

    func show(initialSection: DesktopSection = .chat) {
        guard let companionManager else { return }

        if window == nil {
            window = DesktopWindowPlacement.isAttached
                ? makeAttachedWindow(companionManager: companionManager, initialSection: initialSection)
                : makeWindow(companionManager: companionManager, initialSection: initialSection)
        } else {
            // Already built — just retarget the sidebar selection.
            NotificationCenter.default.post(
                name: .heyMateDesktopSelectSection,
                object: nil,
                userInfo: ["section": initialSection.rawValue]
            )
        }

        guard let window else { return }

        if window is AttachedDesktopPanel {
            // Hanging from the notch it is part of the notch, not an app
            // window: no Dock tile, and it folds away when you switch apps.
            placeUnderNotch(window)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            observeDeactivation()
            return
        }

        // Become a regular app so the window gets normal chrome, a Dock
        // icon, and keyboard focus. Remembered so `windowWillClose` can put
        // it back.
        if activationPolicyBeforeShowing == nil {
            activationPolicyBeforeShowing = NSApp.activationPolicy()
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Moves the window between hanging from the notch and floating free,
    /// keeping the section that was open.
    func setAttached(_ attached: Bool) {
        guard DesktopWindowPlacement.isAttached != attached else { return }
        DesktopWindowPlacement.isAttached = attached
        guard let oldWindow = window else { return }
        isSwitchingPlacement = true
        oldWindow.close()
        isSwitchingPlacement = false
        window = nil
        // Placement is switched from Settings; chat lives in the notch now.
        show(initialSection: .settings)
    }

    func toggle(initialSection: DesktopSection = .chat) {
        if isVisible {
            window?.performClose(nil)
        } else {
            show(initialSection: initialSection)
        }
    }

    private func makeWindow(
        companionManager: CompanionManager,
        initialSection: DesktopSection
    ) -> NSWindow {
        let rootView = DesktopRootView(
            companionManager: companionManager,
            initialSection: initialSection
        )

        let newWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "HeyMate"
        newWindow.contentMinSize = Self.minimumContentSize
        newWindow.contentView = NSHostingView(rootView: rootView)
        newWindow.delegate = self
        newWindow.isReleasedWhenClosed = false

        // Sidebar apps on macOS use a unified toolbar with the title inline,
        // which is what makes the sidebar's translucency read correctly all
        // the way to the top of the window.
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.toolbarStyle = .unified
        // Matte fill behind the titlebar so the toolbar strip is the same
        // black (or white) as the page instead of AppKit's default gray.
        newWindow.backgroundColor = NSColor(DS.Colors.background)

        // Beside the traffic lights: put the window back under the notch.
        let attachButton = NSButton(
            image: NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Attach to notch")
                ?? NSImage(),
            target: self,
            action: #selector(attachToNotch)
        )
        attachButton.bezelStyle = .accessoryBarAction
        attachButton.isBordered = false
        attachButton.toolTip = "Attach to notch"
        attachButton.contentTintColor = .secondaryLabelColor
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .leading
        accessory.view = NSView(frame: NSRect(x: 0, y: 0, width: 34, height: 28))
        attachButton.frame = NSRect(x: 6, y: 2, width: 24, height: 24)
        accessory.view.addSubview(attachButton)
        newWindow.addTitlebarAccessoryViewController(accessory)

        newWindow.setFrameAutosaveName(Self.frameAutosaveName)
        if newWindow.frame.size.width < Self.minimumContentSize.width {
            newWindow.setContentSize(Self.defaultContentSize)
            newWindow.center()
        }
        return newWindow
    }

    // MARK: NSWindowDelegate

    @objc private func attachToNotch() {
        setAttached(true)
    }

    // MARK: Attached to the notch

    private static let attachedContentSize = CGSize(width: 1_160, height: 740)
    private static let attachedCornerRadius: CGFloat = 22

    private func makeAttachedWindow(
        companionManager: CompanionManager,
        initialSection: DesktopSection
    ) -> NSWindow {
        let screen = Self.notchScreen
        let rootView = AttachedDesktopChrome(
            neckWidth: Self.notchWidth(on: screen),
            neckHeight: Self.neckHeight(on: screen),
            cornerRadius: Self.attachedCornerRadius,
            onClose: { [weak self] in self?.window?.close() },
            onDetach: { [weak self] in self?.setAttached(false) }
        ) {
            DesktopRootView(companionManager: companionManager, initialSection: initialSection)
        }
        let panel = AttachedDesktopPanel(
            contentRect: NSRect(origin: .zero, size: Self.attachedContentSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The neck continues the black notch, so the attached panel is
        // always dark, like the notch card.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = true
        // Above the menu bar, so the panel reads as growing out of the notch.
        panel.level = .statusBar
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = []
        panel.contentView = hosting
        AppPresencePreferences.shared.registerAmbientWindow(panel)
        return panel
    }

    /// The camera housing's width, from the menu bar areas either side of
    /// it. Macs without a notch get a pill-sized neck.
    private static func notchWidth(on screen: NSScreen?) -> CGFloat {
        guard let screen,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return 180 }
        return max(120, screen.frame.width - left.width - right.width)
    }

    /// The neck reaches a little below the notch before it opens out.
    private static func neckHeight(on screen: NSScreen?) -> CGFloat {
        max(screen?.safeAreaInsets.top ?? 0, NSStatusBar.system.thickness) + 10
    }

    private static var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func placeUnderNotch(_ window: NSWindow) {
        guard let screen = Self.notchScreen else { return }
        let frame = screen.frame
        let size = CGSize(
            width: min(Self.attachedContentSize.width, frame.width - 40),
            height: min(Self.attachedContentSize.height + Self.neckHeight(on: screen), frame.height - 60)
        )
        window.setFrame(
            NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height),
            display: true
        )
    }

    /// Clicking into another app folds the attached panel away, like the
    /// notch itself. Sheets and panels inside HeyMate keep it open.
    private func observeDeactivation() {
        guard deactivationObserver == nil else { return }
        // Armed a beat later: activating can briefly bounce focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.armDeactivationObserver()
        }
    }

    private func armDeactivationObserver() {
        guard deactivationObserver == nil, window is AttachedDesktopPanel, window?.isVisible == true else { return }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let window = self?.window as? AttachedDesktopPanel, window.isVisible else { return }
                window.close()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let deactivationObserver {
            NotificationCenter.default.removeObserver(deactivationObserver)
            self.deactivationObserver = nil
        }
        // Rebuilding for the other placement: the policy is settled once the
        // new window closes, not now. Restoring here would deactivate the
        // app mid-switch and fold the new attached panel straight away.
        if isSwitchingPlacement { return }
        // An attached panel never changed the policy unless it replaced a
        // detached window, in which case the remembered policy is restored.
        if notification.object is AttachedDesktopPanel, activationPolicyBeforeShowing == nil { return }
        // Back to a menu-bar-only app. Without this the Dock icon survives
        // the window and HeyMate stops feeling ambient.
        // Show in Dock wins over "what it was before": if the user asked for
        // a permanent Dock tile, closing this window must not take it away.
        let restingPolicy = AppPresencePreferences.shared.restingActivationPolicy
        let restoredPolicy: NSApplication.ActivationPolicy = restingPolicy == .regular
            ? .regular
            : (activationPolicyBeforeShowing ?? .accessory)
        activationPolicyBeforeShowing = nil
        // Deferred: changing activation policy inside windowWillClose races
        // AppKit's own teardown and can leave a ghost Dock tile.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(restoredPolicy)
        }
    }
}

/// Whether the desktop window hangs from the notch or floats as a normal
/// window. Attached is the default: it's the notch app's own surface.
enum DesktopWindowPlacement {
    static let attachedKey = "desktopWindowAttachedToNotch"

    static var isAttached: Bool {
        get { UserDefaults.standard.object(forKey: attachedKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: attachedKey) }
    }
}

/// A borderless window that can still take the keyboard.
final class AttachedDesktopPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// The attached panel's outline: a neck the width of the notch that
/// curves out into a rounded panel, so the window reads as growing out of
/// the camera housing.
struct NotchNeckPanelShape: Shape {
    var neckWidth: CGFloat
    var neckHeight: CGFloat
    var cornerRadius: CGFloat
    var flareRadius: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        let neckLeft = (width - neckWidth) / 2
        let neckRight = neckLeft + neckWidth
        let top = neckHeight
        let flare = min(flareRadius, neckHeight)
        let corner = min(cornerRadius, (height - top) / 2)

        var path = Path()
        path.move(to: CGPoint(x: neckLeft, y: 0))
        path.addLine(to: CGPoint(x: neckRight, y: 0))
        path.addLine(to: CGPoint(x: neckRight, y: top - flare))
        path.addQuadCurve(to: CGPoint(x: neckRight + flare, y: top), control: CGPoint(x: neckRight, y: top))
        path.addLine(to: CGPoint(x: width - corner, y: top))
        path.addQuadCurve(to: CGPoint(x: width, y: top + corner), control: CGPoint(x: width, y: top))
        path.addLine(to: CGPoint(x: width, y: height - corner))
        path.addQuadCurve(to: CGPoint(x: width - corner, y: height), control: CGPoint(x: width, y: height))
        path.addLine(to: CGPoint(x: corner, y: height))
        path.addQuadCurve(to: CGPoint(x: 0, y: height - corner), control: CGPoint(x: 0, y: height))
        path.addLine(to: CGPoint(x: 0, y: top + corner))
        path.addQuadCurve(to: CGPoint(x: corner, y: top), control: CGPoint(x: 0, y: top))
        path.addLine(to: CGPoint(x: neckLeft - flare, y: top))
        path.addQuadCurve(to: CGPoint(x: neckLeft, y: top - flare), control: CGPoint(x: neckLeft, y: top))
        path.closeSubpath()
        return path
    }
}

/// The neck, then a slim bar with detach and close on the right, then the
/// app, all inside the neck-and-panel outline.
struct AttachedDesktopChrome<Content: View>: View {
    let neckWidth: CGFloat
    let neckHeight: CGFloat
    let cornerRadius: CGFloat
    let onClose: () -> Void
    let onDetach: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        let outline = NotchNeckPanelShape(neckWidth: neckWidth, neckHeight: neckHeight, cornerRadius: cornerRadius)
        VStack(spacing: 0) {
            Color.clear.frame(height: neckHeight)
            HStack(spacing: 6) {
                Spacer()
                chromeButton("macwindow.on.rectangle", help: "Detach into a window", action: onDetach)
                chromeButton("xmark", help: "Close", action: onClose)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(outline.fill(Color.black))
        .clipShape(outline)
        .overlay(outline.stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func chromeButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

extension Notification.Name {
    /// Retarget the desktop window's sidebar from outside SwiftUI.
    static let heyMateDesktopSelectSection = Notification.Name("heyMateDesktopSelectSection")
}
