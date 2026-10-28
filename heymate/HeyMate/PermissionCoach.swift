//
//  PermissionCoach.swift
//  HeyMate
//
//  The buddy cursor as a permission coach. When PermissionGuide sends the
//  person to System Settings for a switch macOS only flips there, the
//  cursor flies to HeyMate's switch, taps it, shows the slide a few times,
//  and waits with a slow bob. When the grant lands it hops once; if the
//  wait drags on, or System Settings closes with the switch still off, it
//  gives a small "not yet" wobble and taps the spot again.
//
//      guiding (land · tap · slide demo · wait loop)
//         ├─ granted ───────────────→ success (hop, ring) → flies home
//         └─ still off after a while → recovery (wobble, tap) → guiding
//
//  The arrow never changes shape: every move here is an offset, a scale or
//  a few degrees layered on top of the parked pose. Reduce Motion holds it
//  still and lets the label carry the message.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

// MARK: - Cue

/// What the coach is doing right now, published on CompanionManager for
/// the overlay on the matching display.
nonisolated struct PermissionCoachCue: Equatable {
    enum Phase: Equatable {
        case guiding
        case success
        case recovery
    }

    let permission: HeyMatePermission
    var phase: Phase
    /// Bumped on every phase change, so the overlay restarts its clock
    /// even when the same phase repeats (a second recovery nudge).
    var step: Int

    var caption: String {
        switch phase {
        case .guiding: return "flip the switch next to HeyMate"
        case .success: return "got it!"
        case .recovery: return "still off. try this switch, or off and on again"
        }
    }
}

// MARK: - Motion

/// The coach's parked moves, sampled by seconds since the phase began, so
/// a dropped frame never stretches one. Builds on `CursorPointingMotion`
/// for the landing settle and the tap.
nonisolated enum PermissionCoachMotion {
    struct Pose: Equatable {
        /// Settle, tap lean, scale and heading wobble.
        var pointing = CursorPointingMotion.Pose.rest
        /// Free move in overlay points (+x right, +y down), for the slide
        /// demo and the success hop.
        var offset: CGVector = .zero
        /// 0...1 while a success ring spreads from the cursor.
        var successRingProgress: Double?

        static let rest = Pose()
    }

    /// The landing always taps: the line asks the person to flip a switch.
    static let landing = CursorPointingMotion(caption: "click")

    /// The slide demo and wait loop start once the tap has eased out.
    static let loopStart: TimeInterval = CursorPointingMotion.tapWindow.upperBound + 0.2
    static let loopPeriod: TimeInterval = 8
    static let dragDuration: TimeInterval = 1.4
    /// How far the demo slides, about the travel of a System Settings switch.
    static let dragDistance: CGFloat = 16
    static let bobAmplitude: CGFloat = 1.5

    static let successDuration: TimeInterval = 1.0
    static let recoveryDuration: TimeInterval = 1.4
    static let wobbleDuration: TimeInterval = 0.6
    static let recoveryTapWindow: Range<TimeInterval> = 0.7..<1.2

    static func pose(_ phase: PermissionCoachCue.Phase, at elapsed: TimeInterval, reduceMotion: Bool) -> Pose {
        guard !reduceMotion, elapsed >= 0 else { return .rest }
        switch phase {
        case .guiding: return guiding(at: elapsed)
        case .success: return success(at: elapsed)
        case .recovery: return recovery(at: elapsed)
        }
    }

    /// Land and tap, then repeat: one slide demo, a slow two-bob wait.
    private static func guiding(at elapsed: TimeInterval) -> Pose {
        guard elapsed >= loopStart else {
            return Pose(pointing: landing.pose(at: elapsed, isHeld: false, reduceMotion: false))
        }
        let phase = (elapsed - loopStart).truncatingRemainder(dividingBy: loopPeriod)
        if phase < dragDuration {
            return drag(phase / dragDuration)
        }
        // Two slow breaths across the rest of the loop, zero at both ends.
        let t = (phase - dragDuration) / (loopPeriod - dragDuration)
        let wave = sin(t * 4 * .pi)
        return Pose(
            pointing: CursorPointingMotion.Pose(scale: 1 + 0.02 * CGFloat(abs(wave))),
            offset: CGVector(dx: 0, dy: -bobAmplitude * CGFloat(wave))
        )
    }

    /// Press down, slide right like the switch would, let go, glide back.
    private static func drag(_ t: Double) -> Pose {
        let pressed: CGFloat = 0.9
        switch t {
        case ..<0.15:
            let local = smooth(t / 0.15)
            return Pose(pointing: CursorPointingMotion.Pose(scale: 1 - (1 - pressed) * local))
        case ..<0.6:
            let local = smooth((t - 0.15) / 0.45)
            return Pose(
                pointing: CursorPointingMotion.Pose(scale: pressed),
                offset: CGVector(dx: dragDistance * local, dy: 0)
            )
        case ..<0.75:
            let local = smooth((t - 0.6) / 0.15)
            return Pose(
                pointing: CursorPointingMotion.Pose(scale: pressed + (1 - pressed) * local),
                offset: CGVector(dx: dragDistance, dy: 0)
            )
        default:
            let local = smooth(min((t - 0.75) / 0.25, 1))
            return Pose(offset: CGVector(dx: dragDistance * (1 - local), dy: 0))
        }
    }

    /// A tall hop and a small one, with a ring spreading out.
    private static func success(at elapsed: TimeInterval) -> Pose {
        guard elapsed < successDuration else { return .rest }
        let ring = elapsed < 0.8 ? elapsed / 0.8 : nil
        let hop: Double
        if elapsed < 0.45 { hop = 10 * sin(elapsed / 0.45 * .pi) }
        else if elapsed < 0.75 { hop = 4 * sin((elapsed - 0.45) / 0.3 * .pi) }
        else { hop = 0 }
        return Pose(
            pointing: CursorPointingMotion.Pose(scale: 1 + 0.008 * CGFloat(hop)),
            offset: CGVector(dx: 0, dy: -hop),
            successRingProgress: ring
        )
    }

    /// A "not yet" wobble that fades out, then one tap on the switch.
    private static func recovery(at elapsed: TimeInterval) -> Pose {
        if elapsed < wobbleDuration {
            let t = elapsed / wobbleDuration
            return Pose(pointing: CursorPointingMotion.Pose(headingOffsetDegrees: 9 * sin(t * 6 * .pi) * (1 - t)))
        }
        if recoveryTapWindow.contains(elapsed) {
            // Same press as the landing tap, replayed on its own clock.
            let tapStart = CursorPointingMotion.tapWindow.lowerBound
            let local = elapsed - recoveryTapWindow.lowerBound
            return Pose(pointing: landing.pose(at: tapStart + local, isHeld: false, reduceMotion: false))
        }
        return .rest
    }

    private static func smooth(_ t: Double) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return CGFloat(clamped * clamped * (3 - 2 * clamped))
    }
}

// MARK: - Timeline

/// When the coach nudges and when it gives up. Pure, so the schedule is
/// testable without waiting on System Settings.
nonisolated enum PermissionCoachTimeline {
    /// First nudge, then one more every `recoveryRepeat` while still off.
    static let recoveryAfter: TimeInterval = 20
    static let recoveryRepeat: TimeInterval = 30
    /// Matches how long "Allow all" waits for the switch.
    static let giveUpAfter: TimeInterval = 90
    /// How long each reaction plays before the next phase.
    static let successHold: TimeInterval = 1.4
    static let recoveryHold: TimeInterval = 1.8
    /// System Settings can take a moment to open its pane.
    static let windowSearchLimit: TimeInterval = 8

    static func isRecoveryDue(waited: TimeInterval, nudgesShown: Int) -> Bool {
        waited >= recoveryAfter + Double(nudgesShown) * recoveryRepeat
    }
}

// MARK: - Where the switch is

nonisolated enum PermissionCoachAnchor {
    /// The switch to point at, in AppKit global coordinates. A real AX
    /// switch labelled HeyMate wins; a HeyMate row points at its right end;
    /// failing both, the switch column near the top of the app list.
    static func switchPoint(elements: [AccessibleElement], settingsWindow: CGRect?) -> CGPoint? {
        let heyMate = elements.filter { $0.label.lowercased().contains("heymate") }
        if let toggle = heyMate.first(where: { $0.role == kAXCheckBoxRole as String }) {
            return CGPoint(x: toggle.frame.midX, y: toggle.frame.midY)
        }
        if let row = heyMate.first {
            return CGPoint(x: row.frame.maxX - 28, y: row.frame.midY)
        }
        return settingsWindow.map(estimatedSwitch(in:))
    }

    /// Privacy panes list apps under a header, with switches at the right.
    static func estimatedSwitch(in window: CGRect) -> CGPoint {
        CGPoint(x: window.maxX - 44, y: window.maxY - min(150, window.height / 2))
    }

    /// Converts a CGWindowList bounds rect (origin top-left of the primary
    /// display) to AppKit's bottom-left global space.
    static func appKitFrame(fromWindowBounds bounds: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: bounds.minX, y: primaryDisplayHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }
}

// MARK: - Director

/// Watches PermissionGuide and drives the cursor through the coach phases.
@MainActor
final class PermissionCoachDirector {
    private static let settingsBundleIdentifier = "com.apple.systempreferences"

    private weak var manager: CompanionManager?
    private let guide: PermissionGuide
    private var cancellables: Set<AnyCancellable> = []
    private var runTask: Task<Void, Never>?
    private var coached: HeyMatePermission?

    init(manager: CompanionManager, guide: PermissionGuide = .shared) {
        self.manager = manager
        self.guide = guide
    }

    func start() {
        guard cancellables.isEmpty else { return }
        guide.$coaching
            .removeDuplicates()
            .sink { [weak self] permission in self?.coach(permission) }
            .store(in: &cancellables)
    }

    private func coach(_ permission: HeyMatePermission?) {
        guard permission != coached else { return }
        runTask?.cancel()
        runTask = nil
        if coached != nil { finish() }
        coached = permission
        guard let permission else { return }
        runTask = Task { [weak self] in await self?.run(permission) }
    }

    private func run(_ permission: HeyMatePermission) async {
        // Only clears the guide if it is still on this permission.
        defer { guide.endCoaching(permission) }
        guard let manager, CursorCompanionPreference.storedValue() else { return }
        guide.startWatching()
        defer { guide.stopWatching() }

        let began = Date()
        func waited() -> TimeInterval { Date().timeIntervalSince(began) }

        // Wait for System Settings to put its window up.
        var point: CGPoint?
        while point == nil, waited() < PermissionCoachTimeline.windowSearchLimit {
            point = Self.locateSwitch()
            if point == nil { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled, !guide.isGranted(permission) else { return }
        }
        guard let point else {
            HeyMateLog.log("🧭 Permission coach: no System Settings window for \(permission.title)")
            return
        }

        var step = 0
        func show(_ phase: PermissionCoachCue.Phase, at spot: CGPoint) {
            step += 1
            let cue = PermissionCoachCue(permission: permission, phase: phase, step: step)
            manager.permissionCoachCue = cue
            if !manager.overlayWindowManager.isShowingOverlay() {
                manager.overlayWindowManager.hasShownOverlayBefore = true
                manager.overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: manager)
            }
            let display = CompanionManager.nearestOnScreenPoint(to: spot)
            manager.pointingTarget = CursorPointingTarget(location: display.point, displayFrame: display.display, caption: cue.caption)
        }

        HeyMateLog.log("🧭 Permission coach: pointing at \(permission.title) switch")
        show(.guiding, at: point)
        var spot = point
        var nudges = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            if guide.isGranted(permission) {
                show(.success, at: spot)
                try? await Task.sleep(for: .seconds(PermissionCoachTimeline.successHold))
                break
            }
            if waited() >= PermissionCoachTimeline.giveUpAfter { break }
            let windowOpen = Self.settingsWindowFrame() != nil
            if !windowOpen || PermissionCoachTimeline.isRecoveryDue(waited: waited(), nudgesShown: nudges) {
                nudges += 1
                show(.recovery, at: spot)
                try? await Task.sleep(for: .seconds(PermissionCoachTimeline.recoveryHold))
                guard windowOpen, !Task.isCancelled else { break }
                spot = Self.locateSwitch() ?? spot
                show(.guiding, at: spot)
            }
        }
    }

    /// Lets the cursor fly home once the coach is done.
    private func finish() {
        guard let manager, manager.permissionCoachCue != nil else { return }
        manager.permissionCoachCue = nil
    }

    // MARK: System Settings

    private static func settingsApplication() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleIdentifier).first
    }

    /// The frontmost-ordered, largest normal window of System Settings.
    /// Window bounds need no Screen Recording permission.
    private static func settingsWindowFrame() -> CGRect? {
        guard let pid = settingsApplication()?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]],
              let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        let frames = windows.compactMap { window -> CGRect? in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 200, rect.height > 200 else { return nil }
            return rect
        }
        return frames.first.map {
            PermissionCoachAnchor.appKitFrame(fromWindowBounds: $0, primaryDisplayHeight: primaryHeight)
        }
    }

    private static func locateSwitch() -> CGPoint? {
        guard let window = settingsWindowFrame() else { return nil }
        let elements = settingsApplication().map {
            AccessibilityElementFinder.actionableElements(matching: "HeyMate", inApplicationWithProcessIdentifier: $0.processIdentifier)
        } ?? []
        return PermissionCoachAnchor.switchPoint(elements: elements, settingsWindow: window)
    }
}
