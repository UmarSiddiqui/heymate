//
//  NotchCompanionController.swift
//  leanring-buddy
//
//  HeyClicky-style ambient presence anchored to the MacBook notch. The
//  collapsed surface is a small black tab over the camera housing showing
//  the companion's live state (idle dot → listening waveform → thinking
//  pulse → speaking rings). The tab is interactive:
//
//    • Hover the tab → it PEEKS: the window widens past the camera housing
//      and reveals a compact leading indicator plus a trailing context chip.
//      It does NOT open the card. Brushing the notch on the way to the menu
//      bar therefore costs one cheap width animation instead of a full panel.
//      (Users who preferred the old behavior can turn "open on hover" back
//      on; it is off by default.)
//    • Click the tab → the Home/Agents card drops below the notch, pinned.
//    • Press ctrl+command (configurable) → a compact chat drops from the
//      notch, pinned, with the composer focused. Press again or Escape
//      collapses it. Hover/click still opens the full Home/Agents card.
//
//  Window recipe mirrors proven notch apps (boring.notch): level above the
//  menu bar (.mainMenu + 3), floating non-activating panels, forced dark
//  appearance, stationary across Spaces — plus exact notch geometry derived
//  from NSScreen so the tab merges with the camera housing on any model.
//
//  Two panels cooperate: the collapsed tab and the expanded card overlap the
//  same notch pixels. Expanded panel stays at its destination frame while a
//  matched Liquid Glass surface morphs from the pill geometry. The tab is
//  ordered out while the card is visible (see `presentSurface`).
//

import AppKit
import Combine
import Darwin
import QuartzCore
import SwiftUI

extension Notification.Name {
    /// Collapse the expanded notch card. Posted when a talk/dictate/spatial
    /// session starts, onboarding begins, or the user sends a typed message
    /// so the card does not cover the screen during the interaction.
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")

    /// User started dragging HeyMate.app toward System Settings. Fade the
    /// notch card and let mouse events pass through so the drop can land.
    static let clickyPrivacyDragDidBegin = Notification.Name("clickyPrivacyDragDidBegin")
    static let clickyPrivacyDragDidEnd = Notification.Name("clickyPrivacyDragDidEnd")
}

/// Lets the expanded notch card become key so typed input and menus work,
/// without using an activating window style that would steal the user's app.
private final class KeyableNotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class NotchCompanionController {

    /// How long the pointer must rest on the collapsed tab before the card
    /// opens — only consulted when the user has opted into open-on-hover.
    /// Longer than the old 150 ms because opening a panel is a commitment
    /// and should require intent, not a passing pointer.
    private static let hoverExpandDelayMilliseconds: UInt64 = 320

    /// UserDefaults key for the opt-in "hovering the notch opens the card"
    /// behavior. Default OFF: hover peeks, click opens.
    nonisolated static let hoverOpensCardPreferenceKey = "notchHoverOpensCard"

    static var hoverOpensCard: Bool {
        get { UserDefaults.standard.bool(forKey: hoverOpensCardPreferenceKey) }
        set { UserDefaults.standard.set(newValue, forKey: hoverOpensCardPreferenceKey) }
    }

    /// Grace window after the pointer leaves the UNPINNED card before it
    /// auto-collapses. Absorbs the two ways a pointer "briefly" leaves the
    /// card in practice: crossing the hairline seam between tab and card,
    /// and overshooting the card's bottom edge mid-scroll.
    private static let mouseExitCollapseGraceMilliseconds: UInt64 = 400

    private var pillPanel: NSPanel?
    private var expandedPanel: NSPanel?

    /// Single source of truth for everything the collapsed tab renders.
    /// Handed to the hosting view once at construction; afterwards the
    /// controller mutates its properties and SwiftUI diffs normally. This
    /// replaces the old pattern of assigning a fresh `rootView` on every
    /// audio tick, which rebuilt the entire view graph 12 times a second.
    private let pillModel = NotchPillModel()

    /// SwiftUI owns visible card morph. Expanded NSPanel stays fixed at its
    /// destination frame so glass never re-renders against a moving window.
    private let surfaceTransitionModel = NotchSurfaceTransitionModel()

    /// Live mic power subscription. Only alive while the pipeline is
    /// actually listening — an idle menu-bar app should not be running a
    /// Combine chain at all.
    private var audioPowerCancellable: AnyCancellable?

    private var cancellables: Set<AnyCancellable> = []
    private var dismissCardObserver: NSObjectProtocol?
    private var privacyDragBeginObserver: NSObjectProtocol?
    private var privacyDragEndObserver: NSObjectProtocol?
    private var expandedPanelAlphaBeforePrivacyDrag: CGFloat = 1
    private weak var companionManager: CompanionManager?

    // MARK: Interaction state machine

    /// True while the expanded card is on screen (the tab is ordered out).
    private var isExpanded = false

    /// Pinned cards ignore the mouse-exit grace timer and stay open until
    /// explicitly closed (a second tab click or the card's close button).
    private var isPinned = false

    /// Cancelable hover→expand delay. Canceled when the pointer exits the
    /// tab before the delay elapses.
    private var pendingHoverExpandTask: Task<Void, Never>?

    /// Cancelable collapse-after-mouse-exit delay. Canceled when the pointer
    /// re-enters the card within the grace window.
    private var pendingGraceCollapseTask: Task<Void, Never>?

    /// Vsync-driven frame animator — pill hover-widen, and the card's real
    /// expand/collapse frame growth. Replaced a `Task.sleep(16.6 ms)` loop
    /// that assumed a 60 Hz display and landed its `setFrame` calls at
    /// arbitrary points inside each refresh, which is what made the morph
    /// look steppy on ProMotion. See `NotchFrameAnimator` below.
    private let frameAnimator = NotchFrameAnimator()

    /// True while a morph is running. Hover-expand is ignored during this
    /// so a second trigger can't pile animations on top of each other.
    private var isTransitioning = false

    /// Escape / click-outside dismissal, installed only while the card is on
    /// screen. Without these a pinned card has exactly two exits (its close
    /// button and a second tab click) — and the tab is ordered out while the
    /// card is up, so in practice a click anywhere else left it stuck open.
    private var escapeKeyMonitor: Any?
    private var outsideClickMonitor: Any?

    /// Visual-only hover on the collapsed tab (brightens the peek, drops
    /// the chevron) — does not change the window frame.
    private var isPillHovered = false

    /// Full Home card vs compact chat. Hover/click uses the full card;
    /// ctrl+command uses compact chat.
    private var presentedSurface: NotchPresentedSurface = .fullCard

    /// Toggled from the panel; persists via UserDefaults. Re-evaluated on
    /// every show attempt so display changes are handled naturally.
    static var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "showNotchCompanion") == nil
                ? true
                : UserDefaults.standard.bool(forKey: "showNotchCompanion")
        }
        set { UserDefaults.standard.set(newValue, forKey: "showNotchCompanion") }
    }

    func start(companionManager: CompanionManager) {
        self.companionManager = companionManager
        showIfPossible()
        observeStateChanges()

        // Displays reconnect/resolution change/sleep-wake → collapse back to
        // the tab and re-place it (collapseAndUnpin re-runs placement for
        // both surfaces). didChangeScreenParameters is what notch apps
        // observe — it fires reliably on display config changes, unlike
        // per-window notifications. Collapsing first guarantees neither
        // surface is left parked at a stale frame on a screen that changed
        // underneath it.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.collapseAndUnpin(animated: false)
            }
        }

        dismissCardObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.collapseAndUnpin()
            }
        }

        privacyDragBeginObserver = NotificationCenter.default.addObserver(
            forName: .clickyPrivacyDragDidBegin,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setPrivacyDragChrome(active: true)
            }
        }

        privacyDragEndObserver = NotificationCenter.default.addObserver(
            forName: .clickyPrivacyDragDidEnd,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setPrivacyDragChrome(active: false)
            }
        }
    }

    /// Drops the Home/Agents card open and pins it. Used on first launch
    /// (and whenever permissions are missing) so setup is visible without
    /// the old menu-bar panel.
    func expandPinned() {
        presentSurface(.fullCard, pinned: true)
    }

    /// Press ctrl+command: open compact chat (or collapse it if that's
    /// already what's showing). Always pinned so typing isn't interrupted
    /// by a mouse-exit collapse.
    func toggleCompactChat() {
        if isExpanded, presentedSurface == .compactChat, expandedPanel?.isVisible == true {
            collapseAndUnpin()
        } else {
            presentSurface(.compactChat, pinned: true)
        }
    }

    func stop() {
        // Full teardown — unlike `collapseAndUnpin` (which brings the tab
        // back), dismissing here orders out every surface before the panel
        // references are dropped.
        cancellables.removeAll()
        if let dismissCardObserver {
            NotificationCenter.default.removeObserver(dismissCardObserver)
            self.dismissCardObserver = nil
        }
        if let privacyDragBeginObserver {
            NotificationCenter.default.removeObserver(privacyDragBeginObserver)
            self.privacyDragBeginObserver = nil
        }
        if let privacyDragEndObserver {
            NotificationCenter.default.removeObserver(privacyDragEndObserver)
            self.privacyDragEndObserver = nil
        }
        dismissEverything()
        pillPanel = nil
        expandedPanel = nil
    }

    func setHidden(_ hidden: Bool) {
        if hidden {
            dismissEverything()
        } else {
            showIfPossible()
        }
    }

    private func observeStateChanges() {
        guard let companionManager else { return }

        // Coarse signals only. Audio power is deliberately NOT in this
        // merge: it fires continuously while listening, and folding it in
        // here is what used to keep the notch repainting during silence.
        Publishers.Merge4(
            companionManager.$state.map { _ in () },
            companionManager.$themeColorHex.map { _ in () },
            companionManager.$isNotchOutlineEnabled.map { _ in () },
            companionManager.$activeNotchActivity.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.refreshContent()
        }
        .store(in: &cancellables)

        companionManager.computerUseCoordinator.$pendingRequest
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pendingRequest in
                guard pendingRequest != nil else { return }
                self?.expandPinned()
            }
            .store(in: &cancellables)

        companionManager.$shouldRevealAgentsTab
            .removeDuplicates()
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.expandPinned()
            }
            .store(in: &cancellables)

        companionManager.$agentRuns
            .receive(on: DispatchQueue.main)
            .sink { [weak self] runs in
                self?.pillModel.agentFilaments = AgentFilament.live(from: runs)
            }
            .store(in: &cancellables)
    }

    /// Attach/detach the mic-power subscription so it exists only while the
    /// waveform is on screen. 30 Hz is the ceiling the eye needs for a
    /// 5-bar meter; the previous 80 ms throttle plus a 24 fps TimelineView
    /// was doing the same work twice.
    private func updateAudioPowerSubscription(isListening: Bool) {
        guard isListening else {
            audioPowerCancellable = nil
            pillModel.audioPowerLevel = 0
            return
        }
        guard audioPowerCancellable == nil, let companionManager else { return }
        audioPowerCancellable = companionManager.$currentAudioPowerLevel
            .throttle(for: .milliseconds(33), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] powerLevel in
                self?.pillModel.audioPowerLevel = powerLevel
            }
    }

    private func refreshContent() {
        guard let companionManager else { return }

        let voiceState = companionManager.voiceState
        updateAudioPowerSubscription(isListening: voiceState == .listening)

        // Mutate the shared model regardless of which surface is visible —
        // it is cheap, and it means the tab is already correct the instant
        // the card collapses back onto it.
        pillModel.voiceState = voiceState
        pillModel.themeColor = companionManager.themeColor
        pillModel.isOutlineEnabled = companionManager.isNotchOutlineEnabled
        pillModel.isAgentActive = companionManager.isForegroundAgentActive
        pillModel.agentFilaments = AgentFilament.live(from: companionManager.agentRuns)
        pillModel.activity = companionManager.activeNotchActivity

        guard !isExpanded, !isTransitioning else { return }
        syncPillFrameToModel()
    }

    /// Resize the tab window to match whatever the model says it needs to
    /// show. One widened size, one dormant size — see
    /// `NotchLayoutMath.activeWidthBonus`.
    private func syncPillFrameToModel() {
        guard let pillPanel, let screen = pillPanel.screen else { return }

        pillModel.occludedTopInset = screen.safeAreaInsets.top
        pillModel.hardwareNotchWidth = hardwareNotchWidthForCurrentScreen()

        guard let targetFrame = pillFrame(
            for: screen,
            activeInteraction: pillModel.wantsWidenedFrame
        ) else { return }

        guard !framesAreEffectivelyEqual(pillPanel.frame, targetFrame) else { return }
        animateFrame(
            of: pillPanel,
            to: targetFrame,
            duration: NotchLayoutMath.pillResizeDuration
        )
    }

    private func showIfPossible() {
        guard Self.isEnabled else {
            dismissEverything()
            return
        }

        guard let targetScreen = targetScreen(),
              let pillWindowFrame = pillFrame(for: targetScreen, activeInteraction: false) else {
            return
        }

        if pillPanel == nil {
            pillPanel = makePillPanel()
        }
        guard let pillPanel else { return }

        logDetectedNotch(on: targetScreen, frame: pillWindowFrame)
        pillPanel.setFrame(pillWindowFrame, display: false)
        pillPanel.contentView = makePillContentView(occludedTopInset: targetScreen.safeAreaInsets.top)

        if isExpanded {
            // Defensive: every normal path collapses before re-placing, but
            // if the card is somehow still flagged open, re-place it at the
            // fresh geometry rather than flashing the tab.
            if let companionManager, let cardFrame = frame(for: presentedSurface, screen: targetScreen) {
                if expandedPanel == nil {
                    expandedPanel = makeExpandedPanel()
                }
                expandedPanel?.setFrame(cardFrame, display: false)
                expandedPanel?.contentView = makeExpandedContentView(
                    surface: presentedSurface,
                    companionManager: companionManager,
                    occludedTopInset: targetScreen.safeAreaInsets.top,
                    layoutSize: cardFrame.size
                )
                expandedPanel?.orderFrontRegardless()
            }
            pillPanel.orderOut(nil)
        } else {
            expandedPanel?.orderOut(nil)
            pillPanel.orderFrontRegardless()
        }
    }

    /// Prefer the built-in notched display. If this Mac has no camera housing
    /// (Studio Display, iMac, lid-closed laptop on an external), fall back to
    /// the main screen so the control surface still exists without a menu bar.
    private func targetScreen() -> NSScreen? {
        if let builtinScreen = findBuiltinScreen(),
           NotchLayoutMath.screenHasNotch(topSafeAreaInset: builtinScreen.safeAreaInsets.top) {
            return builtinScreen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// The built-in display is the only one with a hardware notch. macOS
    /// NSScreen has no isBuiltIn flag — query CoreGraphics with the display ID.
    private func findBuiltinScreen() -> NSScreen? {
        NSScreen.screens.first(where: { screen in
            guard let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(displayID) != 0
        })
    }

    private static var didLogHardwareNotch = false

    /// One-shot log of the live cutout so we can confirm this Mac's
    /// NSScreen geometry (never a hardcoded model table) is driving layout.
    private func logDetectedNotch(on screen: NSScreen, frame: CGRect) {
        guard !Self.didLogHardwareNotch else { return }
        Self.didLogHardwareNotch = true
        NSLog(
            "HeyMate notch: %.0f×%.0f pt at (%.0f, %.0f) on %@ @%.0fx — idle tab matches hardware, no peek",
            Double(frame.width),
            Double(frame.height),
            Double(frame.minX),
            Double(frame.minY),
            Self.hardwareModelIdentifier() as NSString,
            Double(screen.backingScaleFactor)
        )
    }

    private static func hardwareModelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    /// Screen-derived tab frame. Hardware notch when available; otherwise the
    /// software-notch fallback parked just below the menu bar.
    private func pillFrame(for screen: NSScreen, activeInteraction: Bool) -> CGRect? {
        let outlineEnabled = companionManager?.isNotchOutlineEnabled ?? true
        let safeInset = screen.safeAreaInsets.top
        if let auxTopLeft = screen.auxiliaryTopLeftArea,
           let auxTopRight = screen.auxiliaryTopRightArea,
           let hardwareFrame = NotchLayoutMath.pillFrame(
            screenFrame: screen.frame,
            topSafeAreaInset: safeInset,
            auxiliaryTopLeftMaxX: auxTopLeft.maxX,
            auxiliaryTopRightMinX: auxTopRight.minX,
            activeInteraction: activeInteraction
           ) {
            return NotchLayoutMath.outlinePaddedFrame(
                hardware: pixelAlign(hardwareFrame, on: screen),
                isOutlineEnabled: outlineEnabled
            )
        }
        return NotchLayoutMath.outlinePaddedFrame(
            hardware: pixelAlign(
                NotchLayoutMath.fallbackPillFrame(
                    screenFrame: screen.frame,
                    activeInteraction: activeInteraction
                ),
                on: screen
            ),
            isOutlineEnabled: outlineEnabled
        )
    }

    /// Screen-derived frame for the requested expanded surface.
    private func frame(for surface: NotchPresentedSurface, screen: NSScreen) -> CGRect? {
        switch surface {
        case .fullCard:
            return expandedCardFrame(for: screen)
        case .compactChat:
            return compactChatFrame(for: screen)
        }
    }

    /// Screen-derived expanded-card frame — hardware notch when available,
    /// software-notch fallback otherwise. Always returns a frame once a
    /// target screen exists, so the control surface cannot go missing.
    private func expandedCardFrame(for screen: NSScreen) -> CGRect? {
        let safeInset = screen.safeAreaInsets.top
        if let auxTopLeft = screen.auxiliaryTopLeftArea,
           let auxTopRight = screen.auxiliaryTopRightArea,
           let hardwareFrame = NotchLayoutMath.expandedFrame(
            screenFrame: screen.frame,
            topSafeAreaInset: safeInset,
            auxiliaryTopLeftMaxX: auxTopLeft.maxX,
            auxiliaryTopRightMinX: auxTopRight.minX
           ) {
            return pixelAlign(hardwareFrame, on: screen)
        }
        return pixelAlign(
            NotchLayoutMath.fallbackExpandedFrame(screenFrame: screen.frame),
            on: screen
        )
    }

    private func compactChatFrame(for screen: NSScreen) -> CGRect? {
        let safeInset = screen.safeAreaInsets.top
        if let auxTopLeft = screen.auxiliaryTopLeftArea,
           let auxTopRight = screen.auxiliaryTopRightArea,
           let hardwareFrame = NotchLayoutMath.compactChatFrame(
            screenFrame: screen.frame,
            topSafeAreaInset: safeInset,
            auxiliaryTopLeftMaxX: auxTopLeft.maxX,
            auxiliaryTopRightMinX: auxTopRight.minX
           ) {
            return pixelAlign(hardwareFrame, on: screen)
        }
        return pixelAlign(
            NotchLayoutMath.fallbackCompactChatFrame(screenFrame: screen.frame),
            on: screen
        )
    }

    private func hardwareNotchWidthForCurrentScreen() -> CGFloat {
        guard let screen = targetScreen() else {
            return NotchLayoutMath.fallbackIdleWidth
        }
        if let auxTopLeft = screen.auxiliaryTopLeftArea,
           let auxTopRight = screen.auxiliaryTopRightArea,
           let hardwareFrame = NotchLayoutMath.pillFrame(
            screenFrame: screen.frame,
            topSafeAreaInset: screen.safeAreaInsets.top,
            auxiliaryTopLeftMaxX: auxTopLeft.maxX,
            auxiliaryTopRightMinX: auxTopRight.minX
           ) {
            return pixelAlign(hardwareFrame, on: screen).width
        }
        return NotchLayoutMath.fallbackIdleWidth
    }

    /// Snap a global point-space rect onto this screen's backing pixels so
    /// a 1.5pt halo lands on whole physical pixels instead of half-pixels.
    private func pixelAlign(_ rect: CGRect, on screen: NSScreen) -> CGRect {
        NotchLayoutMath.backingAlignedRect(rect, scale: screen.backingScaleFactor)
    }

    private func makePillPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above both the menu bar (.mainMenu) and status items (.statusBar) —
        // lower levels get covered by / conformed out of the menu-bar strip
        // that surrounds the physical notch.
        panel.level = .mainMenu + 3
        // The bezel around the camera housing is always black regardless of
        // system theme — force dark so the tab's black matches it exactly.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        // Must now RECEIVE events: hover drives the delayed expand and clicks
        // toggle the pinned card. Non-activating keeps keyboard focus with
        // whatever app the user is working in.
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.worksWhenModal = true
        AppPresencePreferences.shared.registerAmbientWindow(panel)
        return panel
    }

    private func makeExpandedPanel() -> NSPanel {
        let panel = KeyableNotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Same level as the tab: both surfaces must sit above the menu-bar
        // strip, and the card replaces the tab rather than stacking with it.
        panel.level = .mainMenu + 3
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        // The card hosts real controls (tabs, buttons, scroll); it must take
        // mouse events but still never steal keyboard focus.
        panel.ignoresMouseEvents = false
        panel.isMovable = false
        panel.worksWhenModal = true
        AppPresencePreferences.shared.registerAmbientWindow(panel)
        return panel
    }

    // MARK: Content construction

    /// Built exactly once per panel. The model reference inside is stable,
    /// so nothing here ever needs to be re-created for a state change.
    private func makePillContentView(occludedTopInset: CGFloat) -> NotchInteractionHostingView<NotchPillView> {
        pillModel.occludedTopInset = occludedTopInset
        pillModel.hardwareNotchWidth = hardwareNotchWidthForCurrentScreen()
        if let companionManager {
            pillModel.voiceState = companionManager.voiceState
            pillModel.themeColor = companionManager.themeColor
            pillModel.isOutlineEnabled = companionManager.isNotchOutlineEnabled
            pillModel.isAgentActive = companionManager.isForegroundAgentActive
            pillModel.agentFilaments = AgentFilament.live(from: companionManager.agentRuns)
            pillModel.activity = companionManager.activeNotchActivity
        }

        let hostingView = NotchInteractionHostingView(rootView: NotchPillView(model: pillModel))
        hostingView.clipsToBounds = true
        hostingView.onMouseEnter = { [weak self] in self?.handlePillMouseEnter() }
        hostingView.onMouseExit = { [weak self] in self?.handlePillMouseExit() }
        hostingView.onClick = { [weak self] in self?.handlePillClick() }
        hostingView.setAccessibilityElement(true)
        hostingView.setAccessibilityRole(.button)
        hostingView.setAccessibilityLabel("HeyMate notch")
        hostingView.setAccessibilityHelp("Opens HeyMate")
        hostingView.registerAsFileDropTarget()
        hostingView.onDragEnter = { [weak self] in self?.setPillDragTargeting(true) }
        hostingView.onDragExit = { [weak self] in self?.setPillDragTargeting(false) }
        hostingView.onFileDrop = { [weak self] droppedURLs in
            self?.acceptDroppedFiles(droppedURLs) ?? false
        }
        return hostingView
    }

    private func makeExpandedContentView(
        surface: NotchPresentedSurface,
        companionManager: CompanionManager,
        occludedTopInset: CGFloat,
        layoutSize: CGSize
    ) -> NotchInteractionHostingView<NotchSurfaceRoot> {
        let hostingView = NotchInteractionHostingView(rootView: makeSurfaceRootView(
            surface: surface,
            companionManager: companionManager,
            occludedTopInset: occludedTopInset,
            layoutSize: layoutSize
        ))
        hostingView.clipsToBounds = true
        hostingView.sizingOptions = []
        hostingView.onMouseEnter = { [weak self] in self?.handleExpandedCardMouseEnter() }
        hostingView.onMouseExit = { [weak self] in self?.handleExpandedCardMouseExit() }
        hostingView.onClick = { [weak self] in self?.pinExpandedCardAndTakeKey() }
        return hostingView
    }

    private func makeSurfaceRootView(
        surface: NotchPresentedSurface,
        companionManager: CompanionManager,
        occludedTopInset: CGFloat,
        layoutSize: CGSize
    ) -> NotchSurfaceRoot {
        NotchSurfaceRoot(
            surface: surface,
            companionManager: companionManager,
            occludedTopInset: occludedTopInset,
            layoutSize: layoutSize,
            hardwareNotchWidth: hardwareNotchWidthForCurrentScreen(),
            transitionModel: surfaceTransitionModel,
            onClose: { [weak self] in self?.collapseAndUnpin() }
        )
    }

    // MARK: Expand / collapse state machine

    /// Hover PEEKS. It widens the tab and lights up the two slots beside
    /// the camera; it does not open the card unless the user opted in.
    private func handlePillMouseEnter() {
        cancelPendingGraceCollapse()
        guard !isExpanded, !isTransitioning else { return }
        isPillHovered = true
        pillModel.isHovered = true
        syncPillFrameToModel()
        if Self.hoverOpensCard {
            scheduleHoverExpand()
        }
    }

    private func handlePillMouseExit() {
        cancelPendingHoverExpand()
        guard !isExpanded else { return }
        isPillHovered = false
        pillModel.isHovered = false
        syncPillFrameToModel()
    }

    /// Widen the tab while a drag hovers it so the drop target is visibly
    /// bigger than the camera housing, and so the shelf glyph is readable.
    private func setPillDragTargeting(_ isTargeting: Bool) {
        pillModel.isDropTargeted = isTargeting
        syncPillFrameToModel()
    }

    private func acceptDroppedFiles(_ droppedURLs: [URL]) -> Bool {
        guard let companionManager else { return false }
        let shelfStore = companionManager.notchActivityCenter.shelfStore
        // The shelf micro-app might be off; a deliberate drop onto the
        // notch is a clear enough request to turn it on.
        if !companionManager.notchActivityCenter.isEnabled(.shelf) {
            companionManager.notchActivityCenter.setEnabled(true, for: .shelf)
        }
        let acceptedCount = shelfStore.accept(fileURLs: droppedURLs)
        setPillDragTargeting(false)
        return acceptedCount > 0
    }

    private func handlePillClick() {
        if isExpanded {
            collapseAndUnpin()
        } else {
            presentSurface(.fullCard, pinned: true)
        }
    }

    private func handleExpandedCardMouseEnter() {
        // Re-entering within the grace window cancels the scheduled collapse
        // — this is what makes the grace feel forgiving instead of laggy.
        cancelPendingGraceCollapse()
    }

    private func handleExpandedCardMouseExit() {
        guard isExpanded, !isPinned else { return }   // pinned cards never auto-collapse
        scheduleGraceCollapse()
    }

    /// Hover delay elapsed → drop the card open but unpinned, so leaving it
    /// auto-collapses again.
    private func expandAfterHover() {
        guard !isExpanded, !isTransitioning else { return }
        presentSurface(.fullCard, pinned: false)
    }

    private func pinExpandedCardAndTakeKey() {
        guard isExpanded else { return }
        isPinned = true
        cancelPendingGraceCollapse()
        expandedPanel?.makeKey()
    }

    /// Fade the card and pass mouse through so a drag can land on System
    /// Settings instead of dying on the notch window sitting above it.
    private func setPrivacyDragChrome(active: Bool) {
        guard let expandedPanel else { return }
        if active {
            isPinned = true
            cancelPendingGraceCollapse()
            expandedPanelAlphaBeforePrivacyDrag = expandedPanel.alphaValue
            expandedPanel.alphaValue = 0.12
            expandedPanel.ignoresMouseEvents = true
        } else {
            expandedPanel.alphaValue = expandedPanelAlphaBeforePrivacyDrag
            expandedPanel.ignoresMouseEvents = false
        }
    }

    private func presentSurface(_ surface: NotchPresentedSurface, pinned: Bool) {
        cancelScheduledTransitions()
        // Stop any in-flight pill hover-widen so it doesn't keep ticking
        // frames under/after the card morph — that double animation is what
        // reads as "widens left-right, then finally opens" instead of one
        // continuous liquid glass expand.
        frameAnimator.cancel()
        guard let companionManager else { return }
        guard let targetScreen = targetScreen(),
              let destinationFrame = frame(for: surface, screen: targetScreen) else { return }

        isPinned = pinned
        isPillHovered = false

        let isAlreadyShowingSameSurface = isExpanded
            && presentedSurface == surface
            && expandedPanel?.isVisible == true
            && !isTransitioning

        if isAlreadyShowingSameSurface {
            if pinned {
                expandedPanel?.makeKey()
            }
            return
        }

        presentedSurface = surface
        isExpanded = true
        isTransitioning = true
        installDismissalMonitors()

        if expandedPanel == nil {
            expandedPanel = makeExpandedPanel()
        }
        guard let expandedPanel else { return }

        // Grow from wherever the current visible surface actually is. The
        // window's real frame animates from here to `destinationFrame`
        // (`animateFrame`, the same per-frame technique the pill hover-widen
        // already uses) — the content underneath is always full destination
        // size and gets revealed as the window grows, so there is no
        // SwiftUI-level shape morph for GlassEffectContainer to fight with.
        let startFrame: CGRect
        if expandedPanel.isVisible {
            startFrame = expandedPanel.frame
        } else if let pillPanel, pillPanel.isVisible {
            startFrame = pillPanel.frame
        } else {
            startFrame = pillFrame(for: targetScreen, activeInteraction: false) ?? destinationFrame
        }

        surfaceTransitionModel.prepare()
        expandedPanel.setFrame(startFrame, display: false)
        expandedPanel.contentView = makeExpandedContentView(
            surface: surface,
            companionManager: companionManager,
            occludedTopInset: targetScreen.safeAreaInsets.top,
            layoutSize: destinationFrame.size
        )
        if pinned {
            expandedPanel.makeKeyAndOrderFront(nil)
        } else {
            expandedPanel.orderFrontRegardless()
        }
        pillPanel?.orderOut(nil)

        if prefersReducedMotion {
            expandedPanel.setFrame(destinationFrame, display: true, animate: false)
            surfaceTransitionModel.showWithoutAnimation()
            isTransitioning = false
            if pinned { expandedPanel.makeKey() }
            return
        }

        surfaceTransitionModel.present()
        animateFrame(
            of: expandedPanel,
            to: destinationFrame,
            duration: NotchLayoutMath.expandDuration,
            curve: .easeOutExpo,
            onProgress: { [weak self] easedProgress, linearProgress in
                self?.surfaceTransitionModel.updateMorph(
                    easedProgress: easedProgress,
                    linearProgress: linearProgress
                )
            },
            completion: { [weak self] in
                guard let self else { return }
                self.isTransitioning = false
                if pinned { self.expandedPanel?.makeKey() }
            }
        )
    }

    /// Every close path funnels here: mouse-exit grace expiry, second tab
    /// click, the card's close button, feature disable, teardown, and
    /// display-geometry changes. Always unpins — an unpinned hover-expand
    /// never needs a separate unpin step, and pinning never survives a
    /// collapse.
    private func collapseAndUnpin(animated: Bool = true) {
        cancelScheduledTransitions()
        isPinned = false
        isPillHovered = false

        guard isExpanded, let expandedPanel, expandedPanel.isVisible else {
            finishCollapse()
            return
        }

        isExpanded = false
        expandedPanel.resignKey()

        if !animated {
            frameAnimator.cancel()
            finishCollapse()
            return
        }

        isTransitioning = true
        surfaceTransitionModel.dismiss()

        // Shrink the real window back toward the pill's own frame, same
        // technique as the expand — a real collapse, not a shape morph.
        let collapseTargetFrame = targetScreen()
            .flatMap { pillFrame(for: $0, activeInteraction: false) }
            ?? expandedPanel.frame
        animateFrame(
            of: expandedPanel,
            to: collapseTargetFrame,
            duration: NotchLayoutMath.collapseDuration,
            curve: .easeInCubic,
            onProgress: { [weak self] easedProgress, linearProgress in
                self?.surfaceTransitionModel.updateMorph(
                    easedProgress: easedProgress,
                    linearProgress: linearProgress
                )
            },
            completion: { [weak self] in
                self?.finishCollapse()
            }
        )
    }

    private func finishCollapse() {
        removeDismissalMonitors()
        isTransitioning = false
        isExpanded = false
        isPinned = false
        presentedSurface = .fullCard
        expandedPanel?.orderOut(nil)
        showIfPossible()
    }

    /// Orders out every notch surface and resets interaction state. Unlike
    /// `collapseAndUnpin` this does NOT bring the tab back — used when the
    /// feature is disabled or being torn down.
    private func dismissEverything() {
        removeDismissalMonitors()
        cancelScheduledTransitions()
        frameAnimator.cancel()
        isTransitioning = false
        isExpanded = false
        isPinned = false
        isPillHovered = false
        presentedSurface = .fullCard
        pillPanel?.orderOut(nil)
        expandedPanel?.orderOut(nil)
    }

    // MARK: Frame morph

    /// Interpolates `panel.frame` on the main actor. AppKit's
    /// `animator().setFrame` is unreliable for borderless panels at this
    /// window level, so we drive the frames ourselves — but on the
    /// display's own refresh boundary via `NotchFrameAnimator`, not on a
    /// free-running timer.
    ///
    /// `onProgress` reports (easedProgress, linearProgress) once per tick
    /// so the SwiftUI surface can morph corner radius and content opacity
    /// on the exact same clock as the window frame.
    private func animateFrame(
        of panel: NSPanel,
        to target: CGRect,
        duration: TimeInterval,
        curve: NotchFrameAnimator.Curve = .easeOutCubic,
        onProgress: ((_ easedProgress: CGFloat, _ linearProgress: CGFloat) -> Void)? = nil,
        completion: (() -> Void)? = nil
    ) {
        frameAnimator.cancel()
        let source = panel.frame

        if duration <= 0 || prefersReducedMotion || framesAreEffectivelyEqual(source, target) {
            panel.setFrame(target, display: true, animate: false)
            onProgress?(1, 1)
            completion?()
            return
        }

        frameAnimator.animate(
            panel: panel,
            to: target,
            duration: duration,
            curve: curve,
            onProgress: onProgress,
            completion: completion
        )
    }

    private var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func framesAreEffectivelyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5
            && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5
            && abs(a.height - b.height) < 0.5
    }

    // MARK: Transition timers

    private func scheduleHoverExpand() {
        cancelPendingHoverExpand()
        pendingHoverExpandTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.hoverExpandDelayMilliseconds * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.expandAfterHover()
        }
    }

    private func scheduleGraceCollapse() {
        cancelPendingGraceCollapse()
        pendingGraceCollapseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.mouseExitCollapseGraceMilliseconds * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.collapseAndUnpin()
        }
    }

    private func cancelPendingHoverExpand() {
        pendingHoverExpandTask?.cancel()
        pendingHoverExpandTask = nil
    }

    private func cancelPendingGraceCollapse() {
        pendingGraceCollapseTask?.cancel()
        pendingGraceCollapseTask = nil
    }

    /// Escape (local, card is key) and any mouse-down outside the card
    /// (global, another app or the desktop) both collapse. Idempotent.
    private func installDismissalMonitors() {
        if escapeKeyMonitor == nil {
            escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isExpanded, event.keyCode == 53 else { return event }
                if self.companionManager?.voiceState == .listening {
                    self.companionManager?.finishVoiceInputFromNotch()
                    return nil
                }
                self.collapseAndUnpin()
                return nil
            }
        }
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                Task { @MainActor in
                    guard let self, self.isExpanded else { return }
                    // A global monitor only fires for events HeyMate did not
                    // receive, so anything landing inside the card never gets
                    // here. The frame check covers the pill window and any
                    // other HeyMate panel sitting under the pointer.
                    let clickLocation = NSEvent.mouseLocation
                    if self.expandedPanel?.frame.contains(clickLocation) == true { return }
                    self.collapseAndUnpin()
                }
            }
        }
    }

    private func removeDismissalMonitors() {
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
        }
        escapeKeyMonitor = nil
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }

    private func cancelScheduledTransitions() {
        cancelPendingHoverExpand()
        cancelPendingGraceCollapse()
    }
}

/// Vsync-aligned window-frame animator. `CADisplayLink` (macOS 14+) fires
/// once per display refresh, so every interpolated `setFrame` is one the
/// screen is actually about to composite — the previous `Task.sleep(16.6ms)`
/// loop assumed 60 Hz and landed mid-refresh, which is what made the notch
/// morph judder on ProMotion. The link is invalidated the instant the
/// animation finishes or is cancelled: an idle menu-bar app must not keep
/// a run-loop source alive.
///
/// Kept in this file (not its own) so the Xcode project needs no new
/// target entry; it has exactly one owner — `NotchCompanionController`.
@MainActor
private final class NotchFrameAnimator: NSObject {

    /// Easing shape applied to linear time before interpolating the frame.
    /// Expand and collapse deliberately use different curves: a grow eases
    /// out (fast attack, gentle settle), a shrink eases in (accelerates
    /// into the notch).
    enum Curve {
        case easeOutCubic
        case easeOutExpo
        case easeInCubic
    }

    private weak var panel: NSPanel?
    private var displayLink: CADisplayLink?
    private var sourceFrame: CGRect = .zero
    private var targetFrame: CGRect = .zero
    private var animationDuration: TimeInterval = 0
    private var animationStartTime: CFTimeInterval = 0
    private var curve: Curve = .easeOutCubic
    private var onProgress: ((_ easedProgress: CGFloat, _ linearProgress: CGFloat) -> Void)?
    private var completion: (() -> Void)?

    /// Starts interpolating `panel.frame` toward `targetFrame`. Cancels any
    /// in-flight animation first. `completion` fires ONLY on a natural
    /// finish — a cancelled animation never completes, matching the old
    /// task-loop semantics the collapse path depends on.
    func animate(
        panel: NSPanel,
        to targetFrame: CGRect,
        duration: TimeInterval,
        curve: Curve,
        onProgress: ((_ easedProgress: CGFloat, _ linearProgress: CGFloat) -> Void)?,
        completion: (() -> Void)?
    ) {
        cancel()

        // On macOS a display link is minted from the NSScreen it should
        // track — use the panel's own screen so the morph ticks on the
        // refresh of the display the notch is actually on.
        guard let screen = panel.screen ?? NSScreen.main else {
            panel.setFrame(targetFrame, display: true, animate: false)
            onProgress?(1, 1)
            completion?()
            return
        }

        self.panel = panel
        self.sourceFrame = panel.frame
        self.targetFrame = targetFrame
        self.animationDuration = duration
        self.animationStartTime = CACurrentMediaTime()
        self.curve = curve
        self.onProgress = onProgress
        self.completion = completion

        let displayLink = screen.displayLink(target: self, selector: #selector(handleDisplayLinkTick(_:)))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        panel = nil
        onProgress = nil
        completion = nil
    }

    /// CADisplayLink needs an @objc selector; the link lives on the main
    /// run loop, so the hop back onto the actor is a no-op at runtime.
    @objc nonisolated private func handleDisplayLinkTick(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            tick()
        }
    }

    private func tick() {
        guard let panel, let displayLink else { return }
        let elapsed = CACurrentMediaTime() - animationStartTime
        let linearProgress = CGFloat(min(elapsed / animationDuration, 1))
        let easedProgress = eased(linearProgress)

        panel.setFrame(
            NotchLayoutMath.interpolatedRect(
                from: sourceFrame,
                to: targetFrame,
                easedProgress: easedProgress
            ),
            display: true,
            animate: false
        )
        onProgress?(easedProgress, linearProgress)

        if linearProgress >= 1 {
            // Land exactly on the target before reporting completion — the
            // final interpolated frame can sit a fraction of a point short.
            panel.setFrame(targetFrame, display: true, animate: false)
            onProgress?(1, 1)
            let completion = self.completion
            displayLink.invalidate()
            self.displayLink = nil
            self.panel = nil
            self.onProgress = nil
            self.completion = nil
            completion?()
        }
    }

    private func eased(_ linearProgress: CGFloat) -> CGFloat {
        switch curve {
        case .easeOutCubic: return NotchLayoutMath.easeOutCubic(linearProgress)
        case .easeOutExpo: return NotchLayoutMath.easeOutExpo(linearProgress)
        case .easeInCubic: return NotchLayoutMath.easeInCubic(linearProgress)
        }
    }
}
/// NSHostingView subclass that reports hover enter/exit and clicks back to
/// the controller via closures. NSTrackingArea is required because plain
/// NSHostingView doesn't surface mouseEntered/mouseExited, and `.activeAlways`
/// matters here: a menu-bar-only app is almost never frontmost, and the
/// notch tab must still respond to hover while another app has focus.
private final class NotchInteractionHostingView<Content: View>: NSHostingView<Content> {
    var onMouseEnter: (() -> Void)?
    var onMouseExit: (() -> Void)?

    /// Files dragged onto the notch. Returning true means "I took them",
    /// which is what makes the drag animation land instead of snapping
    /// back to the Finder window it came from.
    var onFileDrop: (([URL]) -> Bool)?

    /// A drag is hovering over the notch. Drives the "drop here" affordance
    /// without going through the ordinary hover path, because a drag must
    /// not trigger the peek or the card.
    var onDragEnter: (() -> Void)?
    var onDragExit: (() -> Void)?

    /// Called on raw mouse-down BEFORE SwiftUI sees the event. Callers that
    /// don't need it leave this nil (e.g. the expanded card, where only real
    /// controls should handle clicks).
    var onClick: (() -> Void)?

    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Re-add on every updateTrackingAreas pass — AppKit calls this after
        // resizes/geometry changes and stale areas silently stop delivering.
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExit?()
    }

    override func mouseDown(with event: NSEvent) {
        // Fire our handler AND forward to super: super's handling is what
        // lets embedded SwiftUI controls (the card's buttons/tabs) keep
        // receiving the click normally.
        onClick?()
        super.mouseDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return super.accessibilityPerformPress() }
        onClick()
        return true
    }

    // MARK: Dragging destination
    //
    // Implemented in AppKit rather than SwiftUI's `.dropDestination` because
    // the notch panel is non-activating: SwiftUI's drop plumbing assumes a
    // window that can become key, and silently never fires here.

    func registerAsFileDropTarget() {
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onFileDrop != nil, !fileURLs(from: sender).isEmpty else { return [] }
        onDragEnter?()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExit?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragExit?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !fileURLs(from: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty, let onFileDrop else { return false }
        onDragExit?()
        return onFileDrop(urls)
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [URL]) ?? []
    }
}
