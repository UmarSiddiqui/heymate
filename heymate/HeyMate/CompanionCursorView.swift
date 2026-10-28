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
    /// Building a drawing stroke by stroke, driven by the choreographer.
    case drawing
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
    /// Settle, tap and inspect moves layered on the parked cursor.
    @State private var pointingPose = CursorPointingMotion.Pose.rest
    /// The spot being pointed at, and the unit step from the cursor toward it.
    @State private var pointingSpot: CGPoint = .zero
    @State private var leanDirection = CGVector(dx: -0.55, dy: -0.83)
    @State private var pointingMotionTimer: Timer?
    /// Permission coach moves (slide demo, wait bob, success hop), timed
    /// from landing or from the coach's latest phase change.
    @State private var coachPose = PermissionCoachMotion.Pose.rest
    @State private var coachPhaseStartedAt = CACurrentMediaTime()

    /// Reply speed while thinking, sampled from the streamed text.
    @State private var workTempo = CursorWorkPace.Tempo.calm
    @State private var paceTracker = PaceTracker()
    @State private var paceTimer: Timer?
    /// Banks a few degrees toward the way the pointer is moving.
    @State private var followTilt: Double = 0
    /// A slow breath while the pointer rests and nothing is happening.
    @State private var isBreathing = false
    @State private var pointerRestingSince = CACurrentMediaTime()
    @AppStorage(CompanionAppearancePreference.idleAnimationsKey) private var idleAnimations = true
    private static let breathDelay: TimeInterval = 3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var captionSize: CGSize = .zero

    /// Settings › Voice › Captions while HeyMate talks: the reply sits at
    /// the bottom of the screen like subtitles instead of beside the cursor.
    nonisolated static let bottomCaptionsPreferenceKey = "captionsAtBottomOfScreen"
    @AppStorage(Self.bottomCaptionsPreferenceKey) private var showsBottomCaptions = false
    /// Gap between the subtitles and the bottom of the screen.
    private static let bottomCaptionInset: CGFloat = 72

    @State private var trackingTimer: Timer?
    @State private var flightTimer: Timer?
    @State private var pointingTask: Task<Void, Never>?
    @State private var welcomeTask: Task<Void, Never>?
    @State private var typingMonitorInstalled = false
    /// Runs the pen-down build when a reply draws on this screen.
    @StateObject private var choreographer = DrawingChoreographer()

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

            AnnotationCanvasView(
                annotations: companionManager.activeAnnotations,
                screenFrame: screenFrame,
                progressOverrides: choreographer.frame.progressByID.isEmpty
                    ? nil : choreographer.frame.progressByID
            )
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
            if let ring = pointingPose.tapRingProgress, isVisibleOnThisScreen {
                Circle()
                    .stroke(companionManager.themeColor, lineWidth: 1.5)
                    .frame(width: 30, height: 30)
                    .scaleEffect(0.4 + 1.2 * ring)
                    .opacity((1 - ring) * 0.8)
                    .position(pointingSpot)
                    .allowsHitTesting(false)
            }

            if let ring = coachPose.successRingProgress, isVisibleOnThisScreen {
                Circle()
                    .stroke(DS.Colors.success, lineWidth: 2)
                    .frame(width: 34, height: 34)
                    .scaleEffect(0.5 + 1.3 * ring)
                    .opacity((1 - ring) * 0.85)
                    .position(position)
                    .allowsHitTesting(false)
            }

            CompanionCursorGlyph(
                headingDegrees: headingDegrees + pointingPose.headingOffsetDegrees + (mode == .following ? followTilt : 0),
                extraGlow: (flightScale - 1) * 20
            )
                .scaleEffect(breathes ? 1.05 : 1)
                .offset(y: breathes ? -1.4 : 0)
                .animation(
                    breathes ? .easeInOut(duration: 1.25).repeatForever(autoreverses: true) : .easeOut(duration: 0.3),
                    value: breathes
                )
                .scaleEffect(flightScale * pointingPose.scale)
                .opacity(showsArrow ? visibleOpacity : 0)
                .position(
                    x: position.x + leanDirection.dx * pointingPose.lean + coachPose.offset.dx,
                    y: position.y + leanDirection.dy * pointingPose.lean + coachPose.offset.dy
                )
                .animation(.easeIn(duration: 0.25), value: companionManager.voiceState)
                .animation(
                    mode == .flying || mode == .drawing ? nil : .spring(response: 0.42, dampingFraction: 0.72),
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
                CompanionThinkingSpinner(
                    tempo: workTempo,
                    activity: CursorActivityKind.classify(companionManager.mateAgentActivity.last?.text)
                )
                    .opacity(visibleOpacity)
                    .position(position)
                    .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear(perform: appear)
        .onDisappear(perform: disappear)
        .onChange(of: companionManager.pointingTarget) { _, target in
            guard let target else { return }
            // A drawing in progress hands off to pointing when it drains.
            guard mode != .drawing else { return }
            let display = target.displayFrame
            guard display == screenFrame || screenFrame.contains(CGPoint(x: display.midX, y: display.midY)) else { return }
            // A coach phase change at the same switch reacts in place
            // instead of flying a zero-length hop first.
            if mode == .pointing, companionManager.permissionCoachCue != nil {
                let local = localPoint(target.location)
                if hypot(local.x - pointingSpot.x, local.y - pointingSpot.y) < 4 { return }
            }
            flyToTarget(target.location)
        }
        .onChange(of: companionManager.permissionCoachCue) { _, cue in
            guard let cue, mode == .pointing else { return }
            coachPhaseStartedAt = CACurrentMediaTime()
            pointingTask?.cancel()
            pointingTask = nil
            pointingLabel = cue.caption
            pointingLabelOpacity = 1
            pointingLabelScale = 0.5
            DispatchQueue.main.async { pointingLabelScale = 1 }
            pointingTask = Task { _ = try? await holdThenReturn() }
        }
        .onChange(of: companionManager.modelBuildEvent) { _, event in
            beginModelBuild(event)
        }
        .onChange(of: companionManager.pendingDrawingBatch) { _, batch in
            beginDrawing(batch)
        }
        .onChange(of: choreographer.frame) { _, frame in
            applyDrawingFrame(frame)
        }
        .onChange(of: companionManager.activeAnnotations.isEmpty) { _, isEmpty in
            guard isEmpty, mode == .drawing else { return }
            choreographer.cancel()
            resumeFollowing()
        }
        .onChange(of: reduceMotion) { _, reduceMotion in
            choreographer.reduceMotion = reduceMotion
        }
        .onChange(of: companionManager.voiceState) { _, state in
            state == .processing ? startPaceSampling() : stopPaceSampling()
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

    /// The streamed reply beside the cursor, kept fully on screen. As
    /// bottom captions it is wider, centred, and keeps only the newest
    /// lines so it reads like subtitles rather than a page.
    private var caption: some View {
        VStack(alignment: showsBottomCaptions ? .center : .leading, spacing: 4) {
            if let progress = companionManager.cursorCaptionProgress {
                Text(progress)
                    .font(DS.Fonts.caption.weight(.medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            Text(companionManager.cursorCaptionText)
                .font(showsBottomCaptions ? DS.Fonts.reading : DS.Fonts.body)
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(showsBottomCaptions ? .center : .leading)
                .lineSpacing(2)
                .lineLimit(showsBottomCaptions ? 3 : 8)
                .truncationMode(showsBottomCaptions ? .head : .tail)
        }
        .frame(
            maxWidth: showsBottomCaptions
                ? max(80, min(720, screenFrame.width - 80))
                : max(80, min(300, screenFrame.width - 50)),
            alignment: showsBottomCaptions ? .center : .leading
        )
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
        .transition(.scale(scale: 0.92, anchor: showsBottomCaptions ? .bottom : .topLeading).combined(with: .opacity))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: companionManager.cursorCaptionText.isEmpty)
        .allowsHitTesting(false)
    }

    private var captionPosition: CGPoint {
        let half = CGSize(width: captionSize.width / 2, height: captionSize.height / 2)
        if showsBottomCaptions {
            return CGPoint(
                x: screenFrame.width / 2,
                y: max(half.height, screenFrame.height - Self.bottomCaptionInset - half.height)
            )
        }
        let margin: CGFloat = 12
        let desiredX = position.x + captionSize.width + 20 > screenFrame.width - margin
            ? position.x - 20 - half.width : position.x + 20 + half.width
        let desiredY = position.y + captionSize.height + 22 > screenFrame.height - margin
            ? position.y - 22 - half.height : position.y + 22 + half.height
        return CGPoint(
            x: min(max(desiredX, half.width + margin), max(half.width + margin, screenFrame.width - half.width - margin)),
            y: min(max(desiredY, half.height + margin), max(half.height + margin, screenFrame.height - half.height - margin))
        )
    }

    // MARK: - Visibility

    /// Only one cursor is ever visible: the one on the pointer's screen, or
    /// the one flying (another screen's overlay steps aside meanwhile).
    private var isVisibleOnThisScreen: Bool {
        if companionManager.cursorDockPhase.isTransitioning && isDockFlightActive { return true }
        switch mode {
        case .following:
            return companionManager.pointingTarget == nil && isPointerOnThisScreen
        case .flying, .pointing, .drawing:
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
        stopPointingMotion()
        stopPaceSampling()
        welcomeTask?.cancel()
        choreographer.cancel()
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
            if moved > Self.returnCancelDistance {
                resumeFollowing()
                // Blink out and back at the pointer so the snap reads as a choice.
                if !reduceMotion {
                    cursorOpacity = 0.2
                    withAnimation(.easeOut(duration: 0.3)) { cursorOpacity = 1 }
                }
            }
            return
        case .flying, .pointing, .drawing:
            return
        case .following:
            break
        }

        companionManager.revealCursorIfPointerMoved(to: mouse)
        let next = Self.followPosition(for: mouse, in: screenFrame)
        let step = CGVector(dx: next.x - position.x, dy: next.y - position.y)
        let moved = hypot(step.dx, step.dy) >= 0.5
        if moved { position = next }
        updateFollowTilt(horizontalStep: moved ? step.dx : 0)
        updateBreathing(pointerMoved: moved)
    }

    /// Eases toward a lean of up to 8° in the direction of travel, and
    /// back to upright when the pointer stops. Writes only on real change.
    private func updateFollowTilt(horizontalStep: CGFloat) {
        let target = reduceMotion ? 0 : min(max(Double(horizontalStep) * 0.5, -8), 8)
        var next = followTilt + (target - followTilt) * 0.2
        if abs(next) < 0.05 && target == 0 { next = 0 }
        if abs(next - followTilt) > 0.05 || (next == 0 && followTilt != 0) { followTilt = next }
    }

    /// Starts a slow breath after the pointer has rested for a few seconds
    /// with nothing else going on; any movement stops it at once.
    private func updateBreathing(pointerMoved: Bool) {
        let now = CACurrentMediaTime()
        if pointerMoved { pointerRestingSince = now }
        let shouldBreathe = !pointerMoved
            && !reduceMotion
            && idleAnimations
            && isPointerOnThisScreen
            && companionManager.voiceState == .idle
            && !companionManager.hidesCursorForTyping
            && !companionManager.cursorDockPhase.isTransitioning
            && now - pointerRestingSince >= Self.breathDelay
        if shouldBreathe != isBreathing { isBreathing = shouldBreathe }
    }

    // MARK: - Work pace

    /// Samples reply speed four times a second; only a tempo change
    /// reaches SwiftUI.
    private func startPaceSampling() {
        stopPaceSampling()
        let tracker = paceTracker
        tracker.pace.sample(textLength: companionManager.streamingAssistantText.count, at: CACurrentMediaTime())
        paceTimer = Self.frameTimer(interval: 0.25) {
            tracker.pace.sample(textLength: companionManager.streamingAssistantText.count, at: CACurrentMediaTime())
            if tracker.pace.tempo != workTempo { workTempo = tracker.pace.tempo }
        }
    }

    private func stopPaceSampling() {
        paceTimer?.invalidate()
        paceTimer = nil
        paceTracker.pace = CursorWorkPace()
        if workTempo != .calm { workTempo = .calm }
    }

    private var breathes: Bool { isBreathing && mode == .following }

    // MARK: - Choreographed drawing

    /// Starts (or extends) a pen-down build for the strokes that belong to
    /// this screen. The choreographer owns position and ink progress until
    /// the queue drains.
    private func beginDrawing(_ batch: [ResolvedAnnotation]) {
        let strokes = batch
            .filter { $0.screenFrame == screenFrame }
            .map(DrawingStrokeSampler.stroke(for:))
        guard !strokes.isEmpty else { return }
        HeyMateLog.log("beginDrawing: \(strokes.count) strokes on \(Int(screenFrame.width))x\(Int(screenFrame.height))", category: "Drawing")

        choreographer.reduceMotion = reduceMotion
        flightTimer?.invalidate()
        flightTimer = nil
        pointingTask?.cancel()
        stopPointingMotion()
        pointingLabel = ""
        pointingLabelOpacity = 0
        mode = .drawing
        isReturning = false
        choreographer.enqueue(strokes, from: position)
    }

    /// Mirrors one choreographer frame into the cursor's pose, and hands off
    /// to pointing or pointer-follow when the build is done.
    private func applyDrawingFrame(_ frame: DrawingFrameState) {
        guard mode == .drawing else { return }
        position = frame.cursorPosition
        headingDegrees = frame.headingDegrees
        // Pen-down reads as pressure: the glyph settles slightly onto the page.
        flightScale = frame.penIsDown ? 1 - 0.12 * frame.pressDepth : 1

        guard !frame.isActive else { return }
        flightScale = 1
        headingDegrees = CompanionCursorShape.restingHeadingDegrees
        if let target = companionManager.pointingTarget {
            flyToTarget(target.location)
        } else {
            resumeFollowing()
        }
    }

    /// Taps the buddy across the model window's stage in the same rhythm the
    /// parts pop in, so it reads as the thing assembling the model.
    private func beginModelBuild(_ event: ModelBuildEvent?) {
        guard let event, screenFrame.contains(CGPoint(x: event.windowFrame.midX, y: event.windowFrame.midY)) else { return }

        // AppKit global frame → this overlay's top-left coordinates.
        let local = CGRect(
            x: event.windowFrame.minX - screenFrame.minX,
            y: screenFrame.maxY - event.windowFrame.maxY,
            width: event.windowFrame.width,
            height: event.windowFrame.height
        )
        let count = max(1, min(event.partCount, 30))
        let taps: [DrawingStroke] = (0..<count).map { index in
            let spread = count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0.5
            let spot = CGPoint(
                x: local.minX + local.width * (0.18 + 0.64 * spread),
                // The stage sits between the header and the footer strip.
                y: local.minY + local.height * 0.48
            )
            return DrawingStroke(id: UUID(), role: .tap, points: [spot],
                                 duration: Model3DSceneBuilder.buildStagger)
        }

        choreographer.reduceMotion = reduceMotion
        flightTimer?.invalidate()
        flightTimer = nil
        mode = .drawing
        isReturning = false
        choreographer.enqueue(taps, from: position)
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
        stopPointingMotion()
        pointingSpot = target
        let toward = CGVector(dx: target.x - destination.x, dy: target.y - destination.y)
        let length = hypot(toward.dx, toward.dy)
        if length > 0.5 { leanDirection = CGVector(dx: toward.dx / length, dy: toward.dy / length) }
        pointerAtFlightStart = localPoint(NSEvent.mouseLocation)
        mode = .flying
        isReturning = false
        followTilt = 0
        isBreathing = false

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

        let phrase = companionManager.pointingTarget?.caption
            ?? Self.pointingPhrases.randomElement()
            ?? "right here!"
        coachPhaseStartedAt = CACurrentMediaTime()
        pointingTask?.cancel()
        pointingTask = Task { _ = try? await runPointing(phrase) }
        startPointingMotion(CursorPointingMotion(caption: "\(phrase) \(companionManager.cursorCaptionText)"))
    }

    /// Samples the parked moves by time since landing. Writes only when the
    /// pose changes, so the rests between moves cost no SwiftUI work.
    private func startPointingMotion(_ motion: CursorPointingMotion) {
        stopPointingMotion()
        guard !reduceMotion else { return }
        let landedAt = CACurrentMediaTime()
        pointingMotionTimer = Self.frameTimer(interval: 1.0 / 60) {
            guard mode == .pointing else {
                stopPointingMotion()
                return
            }
            if let cue = companionManager.permissionCoachCue {
                let coach = PermissionCoachMotion.pose(
                    cue.phase,
                    at: CACurrentMediaTime() - coachPhaseStartedAt,
                    reduceMotion: reduceMotion
                )
                if coach != coachPose { coachPose = coach }
                if coach.pointing != pointingPose { pointingPose = coach.pointing }
                return
            }
            if coachPose != .rest { coachPose = .rest }
            let pose = motion.pose(
                at: CACurrentMediaTime() - landedAt,
                isHeld: companionManager.isGuidancePointerHeld,
                reduceMotion: reduceMotion
            )
            if pose != pointingPose { pointingPose = pose }
        }
    }

    private func stopPointingMotion() {
        pointingMotionTimer?.invalidate()
        pointingMotionTimer = nil
        if pointingPose != .rest { pointingPose = .rest }
        if coachPose != .rest { coachPose = .rest }
    }

    /// Types the label, then holds and flies back.
    private func runPointing(_ phrase: String) async throws {
        for (index, character) in phrase.enumerated() {
            guard mode == .pointing else { return }
            pointingLabel.append(character)
            if index == 0 { pointingLabelScale = 1 }
            try await Task.sleep(for: .milliseconds(Int.random(in: 30...60)))
        }
        try await holdThenReturn()
    }

    /// Holds for at least 3 s, and while a guided step or the permission
    /// coach still needs the buddy here, then fades the label and flies back.
    private func holdThenReturn() async throws {
        let holdUntil = Date().addingTimeInterval(3)
        while Date() < holdUntil
            || companionManager.isGuidancePointerHeld
            || companionManager.permissionCoachCue != nil {
            try await Task.sleep(for: .milliseconds(200))
            guard mode == .pointing else { return }
        }

        pointingLabelOpacity = 0
        try await Task.sleep(for: .milliseconds(500))
        guard mode == .pointing else { return }
        flyBackToPointer()
    }

    private func flyBackToPointer() {
        stopPointingMotion()
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
        stopPointingMotion()
        mode = .following
        isReturning = false
        headingDegrees = CompanionCursorShape.restingHeadingDegrees
        flightScale = 1
        pointingLabel = ""
        pointingLabelOpacity = 0
        pointingLabelScale = 1
        companionManager.clearPointingTarget()
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

/// Reply-speed sampling state, kept out of SwiftUI so samples that don't
/// change the tempo cost nothing.
private final class PaceTracker {
    var pace = CursorWorkPace()
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
