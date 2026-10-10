//
//  CompanionCursorView.swift
//  HeyMate
//
//  The floating cursor that rides beside the mouse pointer. Every screen
//  has its own overlay running this view; it draws the cursor only while
//  the pointer is on its screen, so the companion appears to follow it from
//  display to display.
//
//  While idle it trails the pointer. During a voice turn it becomes a level
//  meter, then a spinner. When a reply points at something, it flies there
//  on an arc, labels the spot, and flies back. It also launches from and
//  lands in the notch dock, and types the first-run welcome.
//

import AppKit
import SwiftUI

/// What the cursor is doing besides following the pointer.
enum CompanionCursorMode: Equatable {
    case following
    /// In the air: on the way to a target, or on the way back.
    case flying
    /// Parked beside a target with its label showing.
    case pointing
}

struct CompanionCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager

    /// Where the cursor sits relative to the system pointer while following.
    private static let pointerOffset = CGSize(width: 35, height: 25)
    /// Moving the pointer this far cancels a return flight.
    private static let returnCancelDistance: CGFloat = 100
    private static let welcomeMessage = "hey! i'm heymate"
    private static let pointingPhrases = [
        "right here!", "this one!", "over here!", "click this!", "here it is!", "found it!"
    ]

    @State private var position: CGPoint
    @State private var isPointerOnThisScreen: Bool
    @State private var cursorOpacity: Double = 0
    @State private var mode: CompanionCursorMode = .following
    @State private var headingDegrees = CompanionCursorShape.restingHeadingDegrees
    @State private var flightScale: CGFloat = 1
    @State private var isReturning = false
    @State private var isDockFlightActive = false
    /// Pointer position (overlay-local) when the current flight began.
    @State private var pointerAtFlightStart: CGPoint = .zero

    @State private var welcomeText = ""
    @State private var showsWelcome = true
    @State private var welcomeOpacity: Double = 0

    @State private var pointingLabel = ""
    @State private var pointingLabelOpacity: Double = 0
    @State private var pointingLabelScale: CGFloat = 1

    @State private var captionSize: CGSize = .zero

    @State private var trackingTimer: Timer?
    @State private var flightTimer: Timer?
    @State private var pointingTask: Task<Void, Never>?
    @State private var welcomeTask: Task<Void, Never>?
    @State private var typingMonitorInstalled = false

    init(screenFrame: CGRect, isFirstAppearance: Bool, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager
        // Start beside the pointer so the first frame is not drawn at (0, 0).
        let mouse = NSEvent.mouseLocation
        _position = State(initialValue: Self.followPosition(for: mouse, in: screenFrame))
        _isPointerOnThisScreen = State(initialValue: screenFrame.contains(mouse))
    }

    var body: some View {
        let _ = companionManager.themeColorHex
        ZStack {
            // Keeps the layer composited; invisible and click-through.
            Color.black.opacity(0.001)

            AnnotationCanvasView(annotations: companionManager.activeAnnotations, screenFrame: screenFrame)
                .frame(width: screenFrame.width, height: screenFrame.height)
                .allowsHitTesting(false)

            if isPointerOnThisScreen && !companionManager.spatialDraftPoints.isEmpty {
                SpatialDraftView(points: companionManager.spatialDraftPoints)
                    .frame(width: screenFrame.width, height: screenFrame.height)
                    .allowsHitTesting(false)
            }

            if isPointerOnThisScreen && showsWelcome && !welcomeText.isEmpty {
                CursorPillLabel(text: welcomeText)
                    .opacity(welcomeOpacity)
                    .besideCursor(at: position)
                    .animation(.easeOut(duration: 0.5), value: welcomeOpacity)
            }

            if isPointerOnThisScreen && companionManager.showOnboardingPrompt
                && !companionManager.onboardingPromptText.isEmpty {
                CursorPillLabel(text: companionManager.onboardingPromptText)
                    .opacity(companionManager.onboardingPromptOpacity)
                    .besideCursor(at: position)
                    .animation(.easeOut(duration: 0.4), value: companionManager.onboardingPromptOpacity)
            }

            if isVisibleOnThisScreen && !companionManager.cursorCaptionText.isEmpty {
                caption
            }

            if mode == .pointing && !pointingLabel.isEmpty && companionManager.cursorCaptionText.isEmpty {
                // Pops in from half size with a bright glow that settles.
                CursorPillLabel(text: pointingLabel, glow: 1 - pointingLabelScale)
                    .scaleEffect(pointingLabelScale)
                    .opacity(pointingLabelOpacity)
                    .besideCursor(at: position)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: pointingLabelScale)
                    .animation(.easeOut(duration: 0.5), value: pointingLabelOpacity)
            }

            // The position is sampled every frame, so it is not animated;
            // a spring here would run a full-screen transaction per sample.
            CompanionCursorGlyph(headingDegrees: headingDegrees, extraGlow: (flightScale - 1) * 20)
                .scaleEffect(flightScale)
                .opacity(showsArrow ? visibleOpacity : 0)
                .position(position)
                .animation(.easeIn(duration: 0.25), value: companionManager.voiceState)
                .animation(
                    mode == .flying ? nil : .spring(response: 0.42, dampingFraction: 0.72),
                    value: headingDegrees
                )

            // Built only while needed, so idle publishes don't lay them out.
            if isVisibleOnThisScreen && companionManager.voiceState == .listening {
                CompanionListeningMeter(audioPowerLevel: companionManager.currentAudioPowerLevel)
                    .opacity(visibleOpacity)
                    .position(position)
                    .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)
            }

            if isVisibleOnThisScreen && companionManager.voiceState == .processing {
                CompanionThinkingSpinner()
                    .opacity(visibleOpacity)
                    .position(position)
                    .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear(perform: appear)
        .onDisappear(perform: disappear)
        .onChange(of: companionManager.detectedElementScreenLocation) { _, target in
            guard let target, let display = companionManager.detectedElementDisplayFrame,
                  display == screenFrame || screenFrame.contains(CGPoint(x: display.midX, y: display.midY))
            else { return }
            flyToTarget(target)
        }
        .onChange(of: companionManager.cursorDockPhase) { _, phase in
            if phase == .returning && runsDockFlightOnThisScreen {
                flyIntoDock()
            } else if phase == .deployed {
                isDockFlightActive = false
                flightScale = 1
                cursorOpacity = 1
                headingDegrees = CompanionCursorShape.restingHeadingDegrees
            }
        }
    }

    /// The streamed reply beside the cursor, kept fully on screen.
    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress = companionManager.cursorCaptionProgress {
                Text(progress)
                    .font(DS.Fonts.caption.weight(.medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            Text(companionManager.cursorCaptionText)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textPrimary)
                .lineSpacing(2)
                .lineLimit(8)
        }
        .frame(maxWidth: 300, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(companionManager.themeColor.opacity(0.38), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.34), radius: 14, y: 7)
        )
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { captionSize = $0 }
        .position(captionPosition)
        .transition(.scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity))
        .animation(.easeOut(duration: 0.16), value: companionManager.cursorCaptionText.isEmpty)
        .allowsHitTesting(false)
    }

    private var captionPosition: CGPoint {
        let half = CGSize(width: captionSize.width / 2, height: captionSize.height / 2)
        let margin: CGFloat = 12
        return CGPoint(
            x: min(max(position.x + 20 + half.width, half.width + margin), screenFrame.width - half.width - margin),
            y: min(max(position.y + 22 + half.height, half.height + margin), screenFrame.height - half.height - margin)
        )
    }

    // MARK: - Visibility

    /// Only one cursor is ever visible: the one on the pointer's screen, or
    /// the one flying (another screen's overlay steps aside meanwhile).
    private var isVisibleOnThisScreen: Bool {
        if companionManager.cursorDockPhase.isTransitioning && isDockFlightActive { return true }
        switch mode {
        case .following:
            return companionManager.detectedElementScreenLocation == nil && isPointerOnThisScreen
        case .flying, .pointing:
            return true
        }
    }

    /// The arrow shows when idle, while a reply is spoken, and in dock flights;
    /// the meter and spinner stand in for it while listening and thinking.
    private var showsArrow: Bool {
        guard isVisibleOnThisScreen else { return false }
        switch companionManager.voiceState {
        case .idle, .responding: return true
        default: return companionManager.cursorDockPhase.isTransitioning
        }
    }

    /// Typing hides a following cursor; a flight or dock move stays visible.
    private var visibleOpacity: Double {
        let hiddenForTyping = companionManager.hidesCursorForTyping
            && mode == .following
            && !companionManager.cursorDockPhase.isTransitioning
        return hiddenForTyping ? 0 : cursorOpacity
    }

    // MARK: - Lifecycle

    private func appear() {
        let mouse = NSEvent.mouseLocation
        isPointerOnThisScreen = screenFrame.contains(mouse)
        position = Self.followPosition(for: mouse, in: screenFrame)
        startTrackingPointer()
        installTypingMonitor()

        if companionManager.cursorDockPhase == .launching && runsDockFlightOnThisScreen {
            showsWelcome = false
            flyOutOfDock()
        } else if isFirstAppearance && isPointerOnThisScreen {
            withAnimation(.easeIn(duration: 2)) { cursorOpacity = 1 }
            typeWelcome()
        } else {
            cursorOpacity = 1
        }
    }

    private func disappear() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        flightTimer?.invalidate()
        flightTimer = nil
        pointingTask?.cancel()
        welcomeTask?.cancel()
        removeTypingMonitor()
    }

    private func installTypingMonitor() {
        guard !typingMonitorInstalled else { return }
        typingMonitorInstalled = true
        let manager = companionManager
        CursorTypingMonitor.retain { event in
            guard CursorTypingPolicy.hides(forKeyDown: event.characters) else { return }
            MainActor.assumeIsolated {
                manager.hideCursorForTyping(anchor: NSEvent.mouseLocation)
            }
        }
    }

    private func removeTypingMonitor() {
        guard typingMonitorInstalled else { return }
        typingMonitorInstalled = false
        CursorTypingMonitor.release()
    }

    // MARK: - Following the pointer

    private func startTrackingPointer() {
        trackingTimer?.invalidate()
        trackingTimer = Self.frameTimer(interval: 0.016) { trackPointer() }
    }

    private func trackPointer() {
        let mouse = NSEvent.mouseLocation
        let onThisScreen = screenFrame.contains(mouse)
        // Writes only on change, so a still pointer costs no SwiftUI work.
        if onThisScreen != isPointerOnThisScreen { isPointerOnThisScreen = onThisScreen }

        // Dock flights own the position until the phase settles.
        if companionManager.cursorDockPhase.isTransitioning { return }

        switch mode {
        case .flying where isReturning:
            // Only the return flight gives way to the user moving the mouse.
            let local = localPoint(mouse)
            let moved = hypot(local.x - pointerAtFlightStart.x, local.y - pointerAtFlightStart.y)
            if moved > Self.returnCancelDistance { resumeFollowing() }
            return
        case .flying, .pointing:
            return
        case .following:
            break
        }

        companionManager.revealCursorIfPointerMoved(to: mouse)
        let next = Self.followPosition(for: mouse, in: screenFrame)
        if hypot(next.x - position.x, next.y - position.y) >= 0.5 {
            position = next
        }
    }

    // MARK: - Pointing at things

    private func flyToTarget(_ screenPoint: CGPoint) {
        // The welcome line finishes before anything else moves the cursor.
        guard !showsWelcome || welcomeText.isEmpty else { return }

        // Sit just below and to the right of the target, never off screen.
        let target = localPoint(screenPoint)
        let destination = CGPoint(
            x: min(max(target.x + 8, 20), screenFrame.width - 20),
            y: min(max(target.y + 12, 20), screenFrame.height - 20)
        )
        pointingTask?.cancel()
        pointerAtFlightStart = localPoint(NSEvent.mouseLocation)
        mode = .flying
        isReturning = false

        fly(to: destination) {
            guard mode == .flying else { return }
            beginPointing()
        }
    }

    private func beginPointing() {
        mode = .pointing
        headingDegrees = CompanionCursorShape.restingHeadingDegrees
        pointingLabel = ""
        pointingLabelOpacity = 1
        pointingLabelScale = 0.5

        let phrase = companionManager.detectedElementBubbleText
            ?? Self.pointingPhrases.randomElement()
            ?? "right here!"
        pointingTask?.cancel()
        pointingTask = Task { _ = try? await runPointing(phrase) }
    }

    /// Types the label, holds for at least 3 s (and for as long as a guided
    /// step is still being spoken), fades the label and flies back.
    private func runPointing(_ phrase: String) async throws {
        for (index, character) in phrase.enumerated() {
            guard mode == .pointing else { return }
            pointingLabel.append(character)
            if index == 0 { pointingLabelScale = 1 }
            try await Task.sleep(for: .milliseconds(Int.random(in: 30...60)))
        }

        let holdUntil = Date().addingTimeInterval(3)
        while Date() < holdUntil || companionManager.isGuidancePointerHeld {
            try await Task.sleep(for: .milliseconds(200))
            guard mode == .pointing else { return }
        }

        pointingLabelOpacity = 0
        try await Task.sleep(for: .milliseconds(500))
        guard mode == .pointing else { return }
        flyBackToPointer()
    }

    private func flyBackToPointer() {
        let mouse = NSEvent.mouseLocation
        pointerAtFlightStart = localPoint(mouse)
        mode = .flying
        isReturning = true
        fly(to: Self.followPosition(for: mouse, in: screenFrame)) {
            resumeFollowing()
        }
    }

    private func resumeFollowing() {
        flightTimer?.invalidate()
        flightTimer = nil
        pointingTask?.cancel()
        pointingTask = nil
        mode = .following
        isReturning = false
        headingDegrees = CompanionCursorShape.restingHeadingDegrees
        flightScale = 1
        pointingLabel = ""
        pointingLabelOpacity = 0
        pointingLabelScale = 1
        companionManager.clearDetectedElementLocation()
    }

    // MARK: - Notch dock

    /// The dock's launch bay in this overlay's coordinates. It may lie off
    /// this screen; each overlay flies the same path and AppKit clips it,
    /// which reads as one flight across displays.
    private var dockBayPosition: CGPoint {
        CursorDockGeometry.launchBayPosition(
            screenFrame: screenFrame,
            dockAnchorScreenPoint: companionManager.cursorDockAnchorScreenPoint
        )
    }

    private var runsDockFlightOnThisScreen: Bool {
        companionManager.cursorDockAnchorScreenPoint != nil || isPointerOnThisScreen
    }

    private var livePointerFollowPosition: CGPoint {
        Self.followPosition(for: NSEvent.mouseLocation, in: screenFrame)
    }

    /// Leaves the dock on the pointing arc, homing on the live pointer so it
    /// lands where the mouse is now rather than where it was at take-off.
    private func flyOutOfDock() {
        guard companionManager.cursorDockPhase == .launching else { return }
        isDockFlightActive = true
        position = dockBayPosition
        cursorOpacity = 1
        flightScale = 1
        headingDegrees = CompanionCursorShape.restingHeadingDegrees

        fly(to: livePointerFollowPosition, tracking: { livePointerFollowPosition }) {
            guard companionManager.cursorDockPhase == .launching else { return }
            isDockFlightActive = false
            headingDegrees = CompanionCursorShape.restingHeadingDegrees
            companionManager.completeCursorLaunchAnimation()
        }
    }

    /// Flies back into the dock, settles into the dock's resting pose, then
    /// hands over to the dock's own glyph in the same spot.
    private func flyIntoDock() {
        guard companionManager.cursorDockPhase == .returning else { return }
        isDockFlightActive = true

        fly(to: dockBayPosition, tracking: { dockBayPosition }) {
            guard companionManager.cursorDockPhase == .returning else { return }
            position = dockBayPosition
            headingDegrees = CompanionCursorShape.restingHeadingDegrees
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard companionManager.cursorDockPhase == .returning else { return }
                isDockFlightActive = false
                companionManager.completeCursorReturnAnimation()
            }
        }
    }

    // MARK: - Flight

    /// Flies along a `CursorFlight` arc, banking into the turn and swelling
    /// mid-air. `tracking` re-aims the landing every frame at a moving target.
    private func fly(
        to destination: CGPoint,
        tracking liveDestination: (() -> CGPoint)? = nil,
        onLanded: @escaping () -> Void
    ) {
        flightTimer?.invalidate()
        let flight = FlightInProgress(CursorFlight(from: position, to: destination))

        flightTimer = Self.frameTimer(interval: 1.0 / 60) {
            if let liveDestination { flight.path.retarget(to: liveDestination()) }
            let progress = (CACurrentMediaTime() - flight.startTime) / flight.path.duration
            guard progress < 1 else {
                flightTimer?.invalidate()
                flightTimer = nil
                position = flight.path.end
                flightScale = 1
                onLanded()
                return
            }
            let sample = flight.path.sample(at: progress)
            position = sample.position
            headingDegrees = sample.headingDegrees
            flightScale = sample.scale
        }
    }

    // MARK: - Welcome

    /// Fades the cursor in, types "hey! i'm heymate", holds it, then hands
    /// over to onboarding.
    private func typeWelcome() {
        welcomeTask?.cancel()
        welcomeTask = Task {
            do {
                try await Task.sleep(for: .seconds(2))
                withAnimation(.easeIn(duration: 0.4)) { welcomeOpacity = 1 }
                for character in Self.welcomeMessage {
                    welcomeText.append(character)
                    try await Task.sleep(for: .milliseconds(30))
                }
                try await Task.sleep(for: .seconds(2))
                welcomeOpacity = 0
                try await Task.sleep(for: .milliseconds(500))
                showsWelcome = false
                companionManager.continueOnboardingAfterWelcome()
            } catch {
                // The overlay went away mid-welcome; nothing left to do.
            }
        }
    }

    // MARK: - Coordinates

    /// AppKit screen point (origin bottom-left) to this overlay's top-left space.
    private func localPoint(_ screenPoint: CGPoint) -> CGPoint {
        CGPoint(x: screenPoint.x - screenFrame.minX, y: screenFrame.maxY - screenPoint.y)
    }

    private static func followPosition(for mouse: CGPoint, in screenFrame: CGRect) -> CGPoint {
        CGPoint(
            x: mouse.x - screenFrame.minX + pointerOffset.width,
            y: screenFrame.maxY - mouse.y + pointerOffset.height
        )
    }

    /// A repeating main-thread timer that keeps firing while a menu is open
    /// or a window is being dragged (common run loop modes).
    private static func frameTimer(interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

/// Mutable state for one flight, shared with its frame timer.
private final class FlightInProgress {
    var path: CursorFlight
    let startTime = CACurrentMediaTime()

    init(_ path: CursorFlight) {
        self.path = path
    }
}

private extension View {
    /// Places a label with its leading edge just right of the cursor and its
    /// middle level with it. No measuring pass, so it never jumps on the
    /// first frame.
    func besideCursor(at cursor: CGPoint) -> some View {
        frame(width: 0, height: 0, alignment: .leading)
            .position(x: cursor.x + 10, y: cursor.y + 18)
    }
}
