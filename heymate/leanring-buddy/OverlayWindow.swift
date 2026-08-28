//
//  OverlayWindow.swift
//  leanring-buddy
//
//  System-wide transparent overlay window for blue glowing cursor.
//  One OverlayWindow is created per screen so the cursor buddy
//  seamlessly follows the cursor across multiple monitors.
//

import AppKit
import AVFoundation
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// Cursor-like triangle shape (equilateral)
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0

        // Top vertex
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        // Bottom left vertex
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        // Bottom right vertex
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

// PreferenceKey for tracking bubble size
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
}

// SwiftUI view for the blue glowing cursor pointer.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// triangle when it is. During voice interaction, the triangle is
// replaced by a waveform (listening), spinner (processing), or
// streaming text bubble (responding).
struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(
        screenFrame: CGRect,
        isFirstAppearance: Bool,
        companionManager: CompanionManager
    ) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    @State private var timer: Timer?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0
    @State private var isRocketTrailVisible = false
    @State private var launchBayGlowOpacity: Double = 0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// The rotation angle of the triangle in degrees. Default is -35° (cursor-like).
    /// Changes to face the direction of travel when navigating to a target.
    @State private var triangleRotationDegrees: Double = -35.0

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// The cursor position at the moment navigation started, used to detect
    /// if the user moves the cursor enough to cancel the navigation.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    /// Invalidated when the flight completes, is canceled, or the view disappears.
    @State private var navigationAnimationTimer: Timer?

    /// Scale factor applied to the buddy triangle during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True when the buddy is flying BACK to the cursor after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    private let fullWelcomeMessage = "hey! i'm heymate"

    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!"
    ]

    var body: some View {
        let _ = companionManager.themeColorHex
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            // Structured drawing annotations (arrows, circles, highlights…)
            // resolved from the model's visualActions JSON. Rendered beneath
            // the cursor layer; always click-through because the overlay
            // panel itself ignores mouse events.
            AnnotationCanvasView(
                annotations: companionManager.activeAnnotations,
                screenFrame: screenFrame
            )
            .frame(width: screenFrame.width, height: screenFrame.height)
            .allowsHitTesting(false)

            // Live freehand trail while a spatial selection gesture is being
            // drawn on this screen (dashed, distinct from model drawings).
            if isCursorOnThisScreen && !companionManager.spatialDraftPoints.isEmpty {
                SpatialDraftView(points: companionManager.spatialDraftPoints)
                    .frame(width: screenFrame.width, height: screenFrame.height)
                    .allowsHitTesting(false)
            }

            // Welcome speech bubble (first launch only)
            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Onboarding prompt — "press control + option and say hi" streamed after welcome
            if isCursorOnThisScreen && companionManager.showOnboardingPrompt && !companionManager.onboardingPromptText.isEmpty {
                Text(companionManager.onboardingPromptText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(companionManager.onboardingPromptOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.easeOut(duration: 0.4), value: companionManager.onboardingPromptOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Navigation pointer bubble — shown when buddy arrives at a detected element.
            // Pops in with a scale-bounce (0.5x → 1.0x spring) and a bright initial
            // glow that settles, creating a "materializing" effect.
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(
                                color: DS.Colors.overlayCursorBlue.opacity(0.5 + (1.0 - navigationBubbleScale) * 1.0),
                                radius: 6 + (1.0 - navigationBubbleScale) * 16,
                                x: 0, y: 0
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (navigationBubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            if isCursorOnThisScreen && launchBayGlowOpacity > 0 {
                RocketLaunchBayGlow(color: DS.Colors.overlayCursorBlue)
                    .opacity(launchBayGlowOpacity)
                    .position(rocketLaunchBayPosition)
                    .allowsHitTesting(false)
            }

            if isCursorOnThisScreen && isRocketTrailVisible {
                RocketExhaustTrail(color: DS.Colors.overlayCursorBlue)
                    .rotationEffect(.degrees(triangleRotationDegrees))
                    .position(cursorPosition)
                    .allowsHitTesting(false)
            }

            // Blue triangle cursor — shown when idle or while TTS is playing (responding).
            // Position is sampled at 60fps; do not spring-animate every sample or
            // SwiftUI will run a full-screen layout transaction on each tick.
            Triangle()
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(triangleRotationDegrees))
                .shadow(color: DS.Colors.overlayCursorBlue, radius: 8 + (buddyFlightScale - 1.0) * 20, x: 0, y: 0)
                .scaleEffect(buddyFlightScale)
                .opacity(
                    buddyIsVisibleOnThisScreen
                        && (companionManager.voiceState == .idle
                            || companionManager.voiceState == .responding
                            || companionManager.cursorDockPhase.isTransitioning)
                        ? cursorOpacity
                        : 0
                )
                .position(cursorPosition)
                .animation(.easeIn(duration: 0.25), value: companionManager.voiceState)
                .animation(
                    buddyNavigationMode == .navigatingToTarget
                        ? nil
                        : .spring(response: 0.42, dampingFraction: 0.72),
                    value: triangleRotationDegrees
                )

            // Waveform / spinner only exist while listening/processing. Leaving
            // them in the tree at opacity 0 still paid for their layout every
            // time CompanionManager published.
            if buddyIsVisibleOnThisScreen && companionManager.voiceState == .listening {
                BlueCursorWaveformView(audioPowerLevel: companionManager.currentAudioPowerLevel)
                    .opacity(cursorOpacity)
                    .position(cursorPosition)
                    .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)
            }

            if buddyIsVisibleOnThisScreen && companionManager.voiceState == .processing {
                BlueCursorSpinnerView()
                    .opacity(cursorOpacity)
                    .position(cursorPosition)
                    .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)
            }

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            // Set initial cursor position immediately before starting animation
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

            startTrackingCursor()

            if companionManager.cursorDockPhase == .launching
                && shouldRunDockTransitionOnThisScreen {
                showWelcome = false
                cursorPosition = rocketLaunchBayPosition
                startRocketLaunchSequence()
            // Only show welcome message on first appearance (app start)
            // and only if the cursor starts on this screen
            } else if isFirstAppearance && isCursorOnThisScreen {
                withAnimation(.easeIn(duration: 2.0)) {
                    self.cursorOpacity = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                    startWelcomeAnimation()
                }
            } else {
                self.cursorOpacity = 1.0
            }
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTimer?.invalidate()
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { newLocation in
            // When a UI element location is detected, navigate the buddy to
            // that position so it points at the element.
            guard let screenLocation = newLocation,
                  let displayFrame = companionManager.detectedElementDisplayFrame else {
                return
            }

            // Only navigate if the target is on THIS screen
            guard screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
                  || displayFrame == screenFrame else {
                return
            }

            startNavigatingToElement(screenLocation: screenLocation)
        }
        .onChange(of: companionManager.cursorDockPhase) { _, phase in
            if phase == .returning && shouldRunDockTransitionOnThisScreen {
                startRocketReturnSequence()
            } else if phase == .deployed {
                isRocketTrailVisible = false
                launchBayGlowOpacity = 0
                buddyFlightScale = 1
                cursorOpacity = 1
                triangleRotationDegrees = -35
            }
        }
    }

    /// Whether the buddy triangle should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When another
    /// screen is navigating (detectedElementScreenLocation is set but this
    /// screen isn't the one animating), hide the cursor so only one buddy
    /// is ever visible at a time.
    private var buddyIsVisibleOnThisScreen: Bool {
        if companionManager.cursorDockPhase.isTransitioning && isRocketTrailVisible {
            return true
        }
        switch buddyNavigationMode {
        case .followingCursor:
            // If another screen's BlueCursorView is navigating to an element,
            // hide the cursor on this screen to prevent a duplicate buddy
            if companionManager.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

            // Launch and recall own cursorPosition for one short orchestrated
            // movement. Pointer tracking resumes when phase settles.
            let cursorDockIsTransitioning = MainActor.assumeIsolated {
                self.companionManager.cursorDockPhase.isTransitioning
            }
            if cursorDockIsTransitioning {
                return
            }

            // During forward flight or pointing, the buddy is NOT interrupted by
            // mouse movement — it completes its full animation and return flight.
            // Only during the RETURN flight do we allow cursor movement to cancel
            // (so the buddy snaps to following if the user moves while it's flying back).
            if self.buddyNavigationMode == .navigatingToTarget && self.isReturningToCursor {
                let currentMouseInSwiftUI = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
                let distanceFromNavigationStart = hypot(
                    currentMouseInSwiftUI.x - self.cursorPositionWhenNavigationStarted.x,
                    currentMouseInSwiftUI.y - self.cursorPositionWhenNavigationStarted.y
                )
                if distanceFromNavigationStart > 100 {
                    cancelNavigationAndResumeFollowing()
                }
                return
            }

            // During forward navigation or pointing, just skip cursor tracking
            if self.buddyNavigationMode != .followingCursor {
                return
            }

            // Normal cursor following — skip no-op writes so a still mouse
            // does not enqueue a SwiftUI transaction 60 times a second.
            let swiftUIPosition = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
            let nextPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)
            if hypot(nextPosition.x - self.cursorPosition.x, nextPosition.y - self.cursorPosition.y) >= 0.5 {
                self.cursorPosition = nextPosition
            }
        }
    }

    // MARK: - Rocket Launcher Dock

    /// Exact center of footer rocket bay, projected into this overlay. Point
    /// may be outside bounds; AppKit clipping turns identical per-screen
    /// animations into one continuous multi-display flight.
    private var rocketLaunchBayPosition: CGPoint {
        CursorDockGeometry.launchBayPosition(
            screenFrame: screenFrame,
            dockAnchorScreenPoint: companionManager.cursorDockAnchorScreenPoint
        )
    }

    private var shouldRunDockTransitionOnThisScreen: Bool {
        companionManager.cursorDockAnchorScreenPoint != nil || isCursorOnThisScreen
    }

    private func cursorFollowingPosition() -> CGPoint {
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(NSEvent.mouseLocation)
        return CGPoint(x: cursorInSwiftUI.x + 35, y: cursorInSwiftUI.y + 25)
    }

    private func rocketRotation(from start: CGPoint, to end: CGPoint) -> Double {
        atan2(end.y - start.y, end.x - start.x) * (180.0 / .pi) + 90.0
    }

    private func startRocketLaunchSequence() {
        guard companionManager.cursorDockPhase == .launching else { return }

        let startPosition = rocketLaunchBayPosition
        let destination = cursorFollowingPosition()
        let duration = accessibilityReduceMotion ? 0.12 : 0.78

        cursorPosition = startPosition
        cursorOpacity = accessibilityReduceMotion ? 0 : 0.35
        buddyFlightScale = accessibilityReduceMotion ? 1 : 0.58
        triangleRotationDegrees = rocketRotation(from: startPosition, to: destination)
        isRocketTrailVisible = !accessibilityReduceMotion
        launchBayGlowOpacity = accessibilityReduceMotion ? 0 : 1

        DispatchQueue.main.async {
            withAnimation(.timingCurve(0.16, 0.78, 0.20, 1, duration: duration)) {
                cursorPosition = destination
                cursorOpacity = 1
                buddyFlightScale = accessibilityReduceMotion ? 1 : 1.28
                launchBayGlowOpacity = 0
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + duration * 0.62) {
                guard companionManager.cursorDockPhase == .launching else { return }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.68)) {
                    buddyFlightScale = 1
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                guard companionManager.cursorDockPhase == .launching else { return }
                isRocketTrailVisible = false
                triangleRotationDegrees = -35
                buddyFlightScale = 1
                companionManager.completeCursorLaunchAnimation()
            }
        }
    }

    private func startRocketReturnSequence() {
        guard companionManager.cursorDockPhase == .returning else { return }

        let startPosition = cursorFollowingPosition()
        let destination = rocketLaunchBayPosition
        let duration = accessibilityReduceMotion ? 0.12 : 0.65

        triangleRotationDegrees = rocketRotation(from: startPosition, to: destination)
        isRocketTrailVisible = !accessibilityReduceMotion
        launchBayGlowOpacity = accessibilityReduceMotion ? 0 : 0.25

        withAnimation(.timingCurve(0.44, 0, 0.84, 0.22, duration: duration)) {
            cursorPosition = destination
            cursorOpacity = accessibilityReduceMotion ? 0 : 0.18
            buddyFlightScale = accessibilityReduceMotion ? 1 : 0.42
            launchBayGlowOpacity = accessibilityReduceMotion ? 0 : 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard companionManager.cursorDockPhase == .returning else { return }
            isRocketTrailVisible = false
            launchBayGlowOpacity = 0
            companionManager.completeCursorReturnAnimation()
        }
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Don't interrupt welcome animation
        guard !showWelcome || welcomeText.isEmpty else { return }

        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Offset the target so the buddy sits beside the element rather than
        // directly on top of it — 8px to the right, 12px below.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x + 8,
            y: targetInSwiftUI.y + 12
        )

        // Clamp target to screen bounds with padding
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        // Record the current cursor position so we can detect if the user
        // moves the mouse enough to cancel the return flight
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        // Enter navigation mode — stop cursor following
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        animateBezierFlightArc(to: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    /// Animates the buddy along a quadratic bezier arc from its current position
    /// to the specified destination. The triangle rotates to face its direction
    /// of travel (tangent to the curve) each frame, scales up at the midpoint
    /// for a "swooping" feel, and the glow intensifies during flight.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTimer?.invalidate()

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Flight duration scales with distance: short hops are quick, long
        // flights are more dramatic. Clamped to 0.6s–1.4s.
        let flightDurationSeconds = min(max(distance / 800.0, 0.6), 1.4)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        var currentFrame = 0

        // Control point for the quadratic bezier arc. Offset the midpoint
        // upward (negative Y in SwiftUI) so the buddy flies in a parabolic arc.
        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: frameInterval, repeats: true) { _ in
            currentFrame += 1

            if currentFrame > totalFrames {
                self.navigationAnimationTimer?.invalidate()
                self.navigationAnimationTimer = nil
                self.cursorPosition = endPosition
                self.buddyFlightScale = 1.0
                onComplete()
                return
            }

            // Linear progress 0→1 over the flight duration
            let linearProgress = Double(currentFrame) / Double(totalFrames)

            // Smoothstep easeInOut: 3t² - 2t³ (Hermite interpolation)
            let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

            // Quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
            let oneMinusT = 1.0 - t
            let bezierX = oneMinusT * oneMinusT * startPosition.x
                        + 2.0 * oneMinusT * t * controlPoint.x
                        + t * t * endPosition.x
            let bezierY = oneMinusT * oneMinusT * startPosition.y
                        + 2.0 * oneMinusT * t * controlPoint.y
                        + t * t * endPosition.y

            self.cursorPosition = CGPoint(x: bezierX, y: bezierY)

            // Rotation: face the direction of travel by computing the tangent
            // to the bezier curve. B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1)
            let tangentX = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                         + 2.0 * t * (endPosition.x - controlPoint.x)
            let tangentY = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                         + 2.0 * t * (endPosition.y - controlPoint.y)
            // +90° offset because the triangle's "tip" points up at 0° rotation,
            // and atan2 returns 0° for rightward movement
            self.triangleRotationDegrees = atan2(tangentY, tangentX) * (180.0 / .pi) + 90.0

            // Scale pulse: sin curve peaks at midpoint of the flight.
            // Buddy grows to ~1.3x at the apex, then shrinks back to 1.0x on landing.
            let scalePulse = sin(linearProgress * .pi)
            self.buddyFlightScale = 1.0 + scalePulse * 0.3
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement() {
        buddyNavigationMode = .pointingAtTarget

        // Lean ends with damped settle instead of abrupt stop.
        triangleRotationDegrees = -35.0

        // Reset navigation bubble state — start small for the scale-bounce entrance
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        // Use custom bubble text from the companion manager (e.g. onboarding demo)
        // if available, otherwise fall back to a random pointer phrase
        let pointerPhrase = companionManager.detectedElementBubbleText
            ?? navigationPointerPhrases.randomElement()
            ?? "right here!"

        streamNavigationBubbleCharacter(phrase: pointerPhrase, characterIndex: 0) {
            // All characters streamed — hold for 3 seconds, then fly back
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.buddyNavigationMode == .pointingAtTarget else { return }
                    self.startFlyingBackToCursor()
                }
            }
        }
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30–60ms) for a natural "speaking" rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        // On the first character, trigger the scale-bounce entrance
        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    /// Flies the buddy back to the current cursor position after pointing is done.
    private func startFlyingBackToCursor() {
        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorWithTrackingOffset = CGPoint(x: cursorInSwiftUI.x + 35, y: cursorInSwiftUI.y + 25)

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: cursorWithTrackingOffset) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        buddyFlightScale = 1.0
        finishNavigationAndResumeFollowing()
    }

    /// Returns the buddy to normal cursor-following mode after navigation completes.
    private func finishNavigationAndResumeFollowing() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
        triangleRotationDegrees = -35.0
        buddyFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        companionManager.clearDetectedElementLocation()
    }

    // MARK: - Welcome Animation

    private func startWelcomeAnimation() {
        withAnimation(.easeIn(duration: 0.4)) {
            self.bubbleOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < self.fullWelcomeMessage.count else {
                timer.invalidate()
                // Hold the text for 2 seconds, then fade it out
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.showWelcome = false
                    // Start the onboarding intro right after the welcome text disappears
                    self.companionManager.setupOnboardingVideo()
                }
                return
            }

            let index = self.fullWelcomeMessage.index(self.fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            self.welcomeText.append(self.fullWelcomeMessage[index])
            currentIndex += 1
        }
    }
}

private struct RocketExhaustTrail: View {
    let color: Color

    var body: some View {
        VStack(spacing: 1.5) {
            Capsule().fill(Color.white.opacity(0.92)).frame(width: 3, height: 7)
            Capsule().fill(color.opacity(0.88)).frame(width: 5, height: 10)
            Capsule().fill(color.opacity(0.28)).frame(width: 7, height: 14)
        }
        .offset(y: 16)
        .blur(radius: 0.45)
        .shadow(color: color.opacity(0.85), radius: 8)
    }
}

private struct RocketLaunchBayGlow: View {
    let color: Color

    var body: some View {
        ZStack {
            Capsule()
                .fill(color.opacity(0.18))
                .frame(width: 48, height: 7)
                .blur(radius: 3)
            HStack(spacing: 4) {
                Capsule().fill(color.opacity(0.45)).frame(width: 12, height: 2)
                Capsule().fill(Color.white.opacity(0.8)).frame(width: 8, height: 2)
                Capsule().fill(color.opacity(0.45)).frame(width: 12, height: 2)
            }
        }
    }
}

// MARK: - Blue Cursor Waveform

/// A small blue waveform that replaces the triangle cursor while
/// the user is holding the push-to-talk shortcut and speaking.
private struct BlueCursorWaveformView: View {
    let audioPowerLevel: CGFloat

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { barIndex in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(DS.Colors.overlayCursorBlue)
                    .frame(width: 2, height: barHeight(for: barIndex))
            }
        }
        .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
        .animation(.linear(duration: 0.08), value: audioPowerLevel)
    }

    private func barHeight(for barIndex: Int) -> CGFloat {
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        return 3 + easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
    }
}

// MARK: - Blue Cursor Spinner

/// A small blue spinning indicator that replaces the triangle cursor
/// while the AI is processing a voice input.
private struct BlueCursorSpinnerView: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        DS.Colors.overlayCursorBlue.opacity(0.0),
                        DS.Colors.overlayCursorBlue
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
// MARK: - Annotation Canvas

/// Renders the resolved visual-action annotations belonging to this screen.
/// A timeline tick purges expired annotations without extra timers, and each
/// shape springs in on appearance. Hit testing stays off — the whole layer is
/// click-through.
struct AnnotationCanvasView: View {
    let annotations: [ResolvedAnnotation]
    let screenFrame: CGRect

    var body: some View {
        if annotations.isEmpty {
            Color.clear
        } else {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let visibleAnnotations = annotations.filter {
                    $0.expiresAt > context.date && $0.screenFrame == screenFrame
                }
                ZStack {
                    ForEach(visibleAnnotations) { annotation in
                        AnnotationShapeView(annotation: annotation)
                    }
                }
            }
        }
    }
}

private struct AnnotationShapeView: View {
    let annotation: ResolvedAnnotation

    @State private var appeared = false

    private static let strokeColor = DS.Colors.overlayCursorBlue

    var body: some View {
        shapeBody
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 1.06)
            .onAppear {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    appeared = true
                }
            }
    }

    @ViewBuilder
    private var shapeBody: some View {
        switch annotation.kind {
        case .point:
            pointMarker

        case .arrow:
            arrowShape

        case .polyline:
            // Custom shapes are proposed the full overlay frame, so their
            // path coordinates are already overlay-local — do not re-position.
            PolylineShape(points: annotation.points, close: false)
                .strokedOverlay()

        case .polygon:
            ZStack {
                PolylineShape(points: annotation.points, close: true)
                    .fill(Self.strokeColor.opacity(0.15))
                PolylineShape(points: annotation.points, close: true)
                    .strokedOverlay()
            }

        case .circle:
            Ellipse()
                .stroke(Self.strokeColor, lineWidth: 3)
                .background(
                    Ellipse().fill(Self.strokeColor.opacity(0.10))
                )
                .frame(width: annotation.radius.width * 2, height: annotation.radius.height * 2)
                .shadow(color: Self.strokeColor.opacity(0.6), radius: 6)
                .position(annotation.center)

        case .roundedRect:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Self.strokeColor, lineWidth: 3)
                .frame(width: annotation.rect.width, height: annotation.rect.height)
                .shadow(color: Self.strokeColor.opacity(0.6), radius: 6)
                .position(x: annotation.rect.midX, y: annotation.rect.midY)

        case .highlight:
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(DS.Colors.warning.opacity(0.22))
                .frame(width: annotation.rect.width, height: annotation.rect.height)
                .position(x: annotation.rect.midX, y: annotation.rect.midY)

        case .caption:
            if let label = annotation.label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Self.strokeColor)
                            .shadow(color: Self.strokeColor.opacity(0.5), radius: 6)
                    )
                    .fixedSize()
                    .position(annotation.center)
            }

        case .clear:
            EmptyView()
        }

        if showsAttachedLabel {
            Text(annotation.label ?? "")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.65)))
                .fixedSize()
                .position(labelPosition)
        }
    }

    /// Bounding-box center of the annotation's points (label anchoring).
    private var pathCenter: CGPoint {
        guard !annotation.points.isEmpty else { return annotation.center }
        let xs = annotation.points.map(\.x)
        let ys = annotation.points.map(\.y)
        return CGPoint(
            x: (xs.min()! + xs.max()!) / 2,
            y: (ys.min()! + ys.max()!) / 2
        )
    }

    private var showsAttachedLabel: Bool {
        guard let label = annotation.label, !label.isEmpty else { return false }
        return annotation.kind != .caption && annotation.kind != .clear && annotation.kind != .point
    }

    /// Label placement that keeps small shapes unobscured: above circles and
    /// rects, past the end of arrows/lines.
    private var labelPosition: CGPoint {
        switch annotation.kind {
        case .circle:
            return CGPoint(x: annotation.center.x, y: annotation.center.y - annotation.radius.height - 12)
        case .roundedRect, .highlight:
            return CGPoint(x: annotation.rect.midX, y: max(12, annotation.rect.minY - 12))
        default:
            if let last = annotation.points.last {
                return CGPoint(x: last.x, y: max(12, last.y - 14))
            }
            return annotation.center
        }
    }

    private var pointMarker: some View {
        ZStack {
            Circle()
                .stroke(Self.strokeColor.opacity(0.55), lineWidth: 2)
                .frame(width: 26, height: 26)
            Circle()
                .fill(Self.strokeColor)
                .frame(width: 10, height: 10)
        }
        .shadow(color: Self.strokeColor.opacity(0.7), radius: 7)
        .position(annotation.center)
    }

    @ViewBuilder
    private var arrowShape: some View {
        if annotation.points.count >= 2 {
            ArrowShape(start: annotation.points[0], end: annotation.points[1])
                .strokedOverlay()
        }
    }
}

/// A stroked polyline (optionally closed) used for polylines and polygons.
private struct PolylineShape: Shape {
    let points: [CGPoint]
    let close: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        if close {
            path.closeSubpath()
        }
        return path
    }
}

/// Line + open V arrowhead from start to end.
private struct ArrowShape: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)

        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength: CGFloat = 13
        let headSpread: CGFloat = 0.42

        path.move(to: end)
        path.addLine(to: CGPoint(
            x: end.x - headLength * cos(angle - headSpread),
            y: end.y - headLength * sin(angle - headSpread)
        ))
        path.move(to: end)
        path.addLine(to: CGPoint(
            x: end.x - headLength * cos(angle + headSpread),
            y: end.y - headLength * sin(angle + headSpread)
        ))
        return path
    }
}

extension Shape {
    /// Shared stroke treatment so every annotation reads as one visual family.
    fileprivate func strokedOverlay() -> some View {
        self
            .stroke(DS.Colors.overlayCursorBlue, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 5)
    }
}

/// Dashed live trail for the user's in-progress spatial selection drag.
private struct SpatialDraftView: View {
    let points: [CGPoint]

    var body: some View {
        PolylineShape(points: points, close: false)
            .stroke(
                DS.Colors.warning,
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [6, 4])
            )
            .shadow(color: DS.Colors.warning.opacity(0.5), radius: 4)
    }
}

class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    var hasShownOverlayBefore = false

    // MARK: - Spatial Selection Capture

    /// Live gesture monitors installed only while a spatial capture runs.
    private var spatialEventMonitors: [Any] = []
    private var spatialCapturingWindow: OverlayWindow?
    private var spatialDraftPoints: [CGPoint] = []
    private var onSpatialDraftChanged: (([CGPoint]) -> Void)?
    private var onSpatialCaptureCompleted: ((CGRect?, SpatialGeometry.NormalizedSelection?) -> Void)?

    /// True between press and finalize/cancel of a spatial gesture.
    var isSpatialCaptureActive: Bool { spatialEventMonitors.isEmpty == false }

    /// Makes the cursor screen's overlay temporarily mouse-receiving and
    /// records the freehand drag in that overlay's local coordinates.
    /// `completion` receives (screenFrame, normalizedSelection) — both nil
    /// when the gesture was degenerate or cancelled via endSpatialCapture.
    func beginSpatialCapture(
        draftChanged: @escaping ([CGPoint]) -> Void,
        completion: @escaping (CGRect?, SpatialGeometry.NormalizedSelection?) -> Void
    ) {
        guard spatialEventMonitors.isEmpty else { return }

        onSpatialDraftChanged = draftChanged
        onSpatialCaptureCompleted = completion

        let mouseLocation = NSEvent.mouseLocation
        // Pick the window under the cursor; fall back to the first one.
        let targetWindow = overlayWindows.first { window in
            (window.screen?.frame ?? .zero).contains(mouseLocation)
        } ?? overlayWindows.first

        guard let targetWindow, let screenFrame = targetWindow.screen?.frame else {
            completion(nil, nil)
            return
        }

        spatialCapturingWindow = targetWindow
        spatialDraftPoints = []
        targetWindow.ignoresMouseEvents = false

        let toOverlayLocal: (NSPoint) -> CGPoint = { globalAppKitPoint in
            // Inverse of convertScreenPointToSwiftUICoordinates: y-down local.
            CGPoint(
                x: globalAppKitPoint.x - screenFrame.origin.x,
                y: screenFrame.height - (globalAppKitPoint.y - screenFrame.origin.y)
            )
        }

        spatialEventMonitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged]
        ) { [weak self] event in
            guard let self, event.window === targetWindow else { return event }
            let localPoint = toOverlayLocal(event.locationInWindow)
            self.spatialDraftPoints.append(localPoint)
            self.onSpatialDraftChanged?(self.spatialDraftPoints)
            return event
        })

        spatialEventMonitors.append(NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp]
        ) { [weak self] event in
            guard let self, event.window === targetWindow else { return event }
            let localPoint = toOverlayLocal(event.locationInWindow)
            if !self.spatialDraftPoints.isEmpty {
                self.spatialDraftPoints.append(localPoint)
            }
            self.finalizeSpatialGesture(screenFrame: screenFrame)
            return event
        })
    }

    /// Normal release path: finalize whatever was drawn.
    func finishSpatialCapture() {
        guard isSpatialCaptureActive else { return }
        let frame = spatialCapturingWindow?.screen?.frame
        finalizeSpatialGesture(screenFrame: frame ?? .zero)
    }

    /// Escape/teardown path: discard the gesture entirely.
    func endSpatialCapture() {
        tearDownSpatialMonitors()
    }

    private func finalizeSpatialGesture(screenFrame: CGRect) {
        let drawnPoints = spatialDraftPoints
        let frameSize = CGSize(width: screenFrame.width, height: screenFrame.height)

        let simplified = SpatialGeometry.ramerDouglasPeucker(points: drawnPoints, epsilon: 3.0)
        let selection = SpatialGeometry.normalize(
            polygonScreenLocal: simplified,
            frameSize: frameSize
        )

        let completedFrame = selection != nil ? screenFrame : nil
        let completion = onSpatialCaptureCompleted

        tearDownSpatialMonitors()
        completion?(completedFrame, selection)
    }

    private func tearDownSpatialMonitors() {
        spatialEventMonitors.forEach { NSEvent.removeMonitor($0) }
        spatialEventMonitors.removeAll()
        spatialCapturingWindow?.ignoresMouseEvents = true
        spatialCapturingWindow = nil
        spatialDraftPoints = []
    }

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)

            // Honors the "Show in screen recordings" preference: registering
            // both records the window and applies the current setting to it.
            // `assumeIsolated` because OverlayWindowManager is not itself
            // main-actor annotated, but every caller of showOverlay is —
            // AppKit window creation could not work otherwise.
            MainActor.assumeIsolated {
                AppPresencePreferences.shared.registerAmbientWindow(window)
            }

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }
}
