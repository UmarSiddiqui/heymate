//
//  HeyMateDesktopWindowController.swift
//  leanring-buddy
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
    private static let defaultContentSize = CGSize(width: 1_080, height: 720)
    private static let minimumContentSize = CGSize(width: 820, height: 560)

    /// Frame autosave name so macOS restores the user's size and position.
    private static let frameAutosaveName = "HeyMateDesktopWindow"

    private var window: NSWindow?
    private weak var companionManager: CompanionManager?

    /// What the app's activation policy was before we made the window
    /// visible, so closing restores exactly that rather than assuming.
    private var activationPolicyBeforeShowing: NSApplication.ActivationPolicy?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
    }

    var isVisible: Bool { window?.isVisible == true }

    // MARK: Presentation

    func show(initialSection: DesktopSection = .chat) {
        guard let companionManager else { return }

        if window == nil {
            window = makeWindow(companionManager: companionManager, initialSection: initialSection)
        } else {
            // Already built — just retarget the sidebar selection.
            NotificationCenter.default.post(
                name: .heyMateDesktopSelectSection,
                object: nil,
                userInfo: ["section": initialSection.rawValue]
            )
        }

        guard let window else { return }

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

        newWindow.setFrameAutosaveName(Self.frameAutosaveName)
        if newWindow.frame.size.width < Self.minimumContentSize.width {
            newWindow.setContentSize(Self.defaultContentSize)
            newWindow.center()
        }
        return newWindow
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
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

extension Notification.Name {
    /// Retarget the desktop window's sidebar from outside SwiftUI.
    static let heyMateDesktopSelectSection = Notification.Name("heyMateDesktopSelectSection")
}
