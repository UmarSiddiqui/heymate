//
//  CompanionManager+Guidance.swift
//  leanring-buddy
//
//  Step-by-step on-screen guidance. A reply with several [POINT:] tags is
//  played one step at a time: the buddy flies to step one, the caption shows
//  step one, the voice says step one, and only then does it move on.
//
//  A walkthrough ([PLAN:a|b|c]) spans turns. HeyMate remembers the plan and
//  the current step, waits for the user to click what it pointed at (or say
//  "next"), takes a fresh look at the screen, and guides the next step.
//

import AppKit
import Foundation

/// A multi-turn plan the model is guiding the user through.
struct GuidedWalkthrough: Equatable {
    var goal: String
    var steps: [String]
    /// 0-based index of the step being guided now.
    var currentStepIndex: Int
    var updatedAt: Date
    /// Turns HeyMate started on its own (after a click or an action), so a
    /// walkthrough that never converges cannot loop forever.
    var automaticContinuations: Int = 0

    static let idleExpirySeconds: TimeInterval = 15 * 60

    var isExpired: Bool {
        Date().timeIntervalSince(updatedAt) > Self.idleExpirySeconds
    }

    var maximumAutomaticContinuations: Int {
        steps.count + 3
    }

    var progressLabel: String {
        "step \(min(currentStepIndex + 1, steps.count)) of \(steps.count)"
    }

    /// Context handed to the model on every turn while the plan is active.
    var promptBlock: String {
        let numbered = steps.enumerated()
            .map { index, step in "\(index + 1). \(step)\(index == currentStepIndex ? "  <- current" : "")" }
            .joined(separator: "\n")
        return """
        active walkthrough — you are guiding the user through: \(goal)
        plan:
        \(numbered)
        the user is on step \(currentStepIndex + 1) of \(steps.count). look at the screen now. if the current step is already done, move on to the next one. guide ONE step only: say it in a sentence, point at it, and write [STEP:n] with that step's number. if the user says go back, repeat, or skip, adjust n. if the screen shows something unexpected, help them recover first. if every step is done, say so and write [PLAN:done]. if they want to stop, write [PLAN:done].
        """
    }
}

extension CompanionManager {

    /// How close (in points) a click must land to the pointed target to
    /// count as the user doing the step.
    nonisolated static let walkthroughClickRadius: CGFloat = 90

    // MARK: - Walkthrough state

    /// Applies [PLAN] / [STEP] directives from a finished reply.
    func applyWalkthroughDirectives(_ directives: [WalkthroughDirective], goal: String) {
        if activeWalkthrough?.isExpired == true {
            endWalkthrough()
        }
        for directive in directives {
            switch directive {
            case .plan(let steps):
                activeWalkthrough = GuidedWalkthrough(
                    goal: goal,
                    steps: steps,
                    currentStepIndex: 0,
                    updatedAt: Date()
                )
            case .step(let number):
                guard var walkthrough = activeWalkthrough else { continue }
                walkthrough.currentStepIndex = min(max(number - 1, 0), max(walkthrough.steps.count - 1, 0))
                walkthrough.updatedAt = Date()
                activeWalkthrough = walkthrough
            case .done:
                endWalkthrough()
            }
        }
    }

    /// Seen live: on the last step the model says "that worked" without
    /// writing [PLAN:done]. A reply on the final step that points at nothing
    /// and names no step means the walkthrough is over.
    func endWalkthroughIfFinished(by reply: GuidedReply) {
        guard let walkthrough = activeWalkthrough,
              walkthrough.currentStepIndex >= walkthrough.steps.count - 1,
              reply.pointingStepCount == 0,
              !reply.walkthroughDirectives.contains(where: {
                  if case .step = $0 { return true }
                  if case .plan = $0 { return true }
                  return false
              }) else { return }
        endWalkthrough()
    }

    func endWalkthrough() {
        disarmWalkthroughClickMonitor()
        activeWalkthrough = nil
    }

    /// Prompt context for the turn being built, or nil without a plan.
    func walkthroughPromptBlock() -> String? {
        guard let walkthrough = activeWalkthrough else { return nil }
        guard !walkthrough.isExpired else {
            endWalkthrough()
            return nil
        }
        return walkthrough.promptBlock
    }

    /// After a step is guided, wait for the user to click near what the
    /// buddy pointed at, then take a fresh look and guide the next step.
    func armWalkthroughClickMonitor(target: CGPoint?) {
        disarmWalkthroughClickMonitor()
        guard activeWalkthrough != nil, let target else { return }
        walkthroughClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            let clickLocation = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self else { return }
                let distance = hypot(clickLocation.x - target.x, clickLocation.y - target.y)
                guard distance <= Self.walkthroughClickRadius else { return }
                self.disarmWalkthroughClickMonitor()
                self.continueWalkthroughAutomatically(after: 0.9)
            }
        }
    }

    func disarmWalkthroughClickMonitor() {
        if let walkthroughClickMonitor {
            NSEvent.removeMonitor(walkthroughClickMonitor)
        }
        walkthroughClickMonitor = nil
    }

    /// Starts the next walkthrough turn on HeyMate's own initiative, after
    /// the UI has had a moment to settle from the click or action.
    func continueWalkthroughAutomatically(after delaySeconds: TimeInterval) {
        guard var walkthrough = activeWalkthrough else { return }
        guard walkthrough.automaticContinuations < walkthrough.maximumAutomaticContinuations else {
            HeyMateLog.log("🧭 Walkthrough: automatic continuation limit reached")
            return
        }
        walkthrough.automaticContinuations += 1
        walkthrough.updatedAt = Date()
        activeWalkthrough = walkthrough

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            // A click can land while the step is still being spoken; let
            // that turn finish rather than talking over it.
            for _ in 0..<150 {
                guard let self, self.activeWalkthrough != nil else { return }
                if !self.isResponseInFlight { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard let self, self.activeWalkthrough != nil, !self.isResponseInFlight else { return }
            self.sendTranscriptToClaudeWithScreenshot(
                transcript: "done — what's next?",
                shouldCaptureScreen: true
            )
        }
    }

    /// Escape: stop the guided sequence and forget the plan.
    func cancelGuidance() {
        guard activeWalkthrough != nil || isGuidancePointerHeld else { return }
        endWalkthrough()
        if isGuidancePointerHeld {
            // Cancels the turn and returns state to idle; a bare task cancel
            // would leave the pipeline showing Speaking.
            cancelInFlightChatTurn()
        }
        isGuidancePointerHeld = false
        cursorCaptionProgress = nil
        cursorCaptionText = ""
    }

    // MARK: - Step playback

    /// Points, shows, and says each step in turn, running any [ACT:]
    /// directives after the step that names them. Returns the computer-use
    /// outcome lines and the last place the buddy pointed.
    func playGuidedReply(
        _ reply: GuidedReply,
        screenCaptures: [CompanionScreenCapture]
    ) async throws -> (actionOutcome: String?, lastPointedLocation: CGPoint?) {
        let steps = reply.steps.filter { !$0.displayText.isEmpty || $0.pointsSomewhere }
        guard !steps.isEmpty else { return (nil, nil) }

        isGuidancePointerHeld = true
        defer { releaseGuidancePointer() }

        // Without anything to point at there is nothing to keep in sync, so
        // the reply plays as before: start speaking and hand back.
        let pacesSteps = reply.pointingStepCount > 0
        let progressPrefix: String? = activeWalkthrough?.progressLabel
        let pointingStepCount = reply.pointingStepCount
        var pointingStepNumber = 0
        var outcomeLines: [String] = []
        var lastPointedLocation: CGPoint?
        var stepAnnotationIDs: Set<UUID> = []
        var hasBegunSpeaking = false
        var lastStepStartedAt = Date()

        for step in steps {
            try Task.checkCancellation()

            if step.pointsSomewhere, let pointing = step.pointing {
                removeAnnotations(withIDs: stepAnnotationIDs)
                let before = Set(activeAnnotations.map(\.id))
                applyPointingParseResult(pointing, screenCaptures: screenCaptures)
                stepAnnotationIDs = Set(activeAnnotations.map(\.id)).subtracting(before)
                // Drawings last as long as their step, not a fixed TTL.
                extendAnnotations(withIDs: stepAnnotationIDs, by: 120)
                if pointing.coordinate != nil {
                    lastPointedLocation = detectedElementScreenLocation
                    // Listen from the moment the buddy points: people click
                    // as soon as they see the target, not after the voice.
                    armWalkthroughClickMonitor(target: lastPointedLocation)
                }
                pointingStepNumber += 1
            }

            let words = step.displayText
            cursorCaptionTask?.cancel()
            cursorCaptionTask = nil
            cursorCaptionProgress = progressPrefix
                ?? (pointingStepCount > 1 && step.pointsSomewhere
                    ? "\(pointingStepNumber) of \(pointingStepCount)"
                    : nil)
            if !words.isEmpty {
                cursorCaptionText = words
            }

            let stepStartedAt = Date()
            if !words.isEmpty {
                try await voiceSynthesisClient.speakText(words)
                try Task.checkCancellation()
                if !hasBegunSpeaking {
                    hasBegunSpeaking = true
                    dispatch(.beginSpeaking)
                }
            }

            // Hold the step until it has been heard, or read when silent.
            if pacesSteps {
                let minimumSeconds = isSilentModeEnabled || !voiceSynthesisClient.isPlaying
                    ? CursorCaptionTiming.readingSeconds(for: words)
                    : 0
                while voiceSynthesisClient.isPlaying
                        || Date().timeIntervalSince(stepStartedAt) < minimumSeconds {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            lastStepStartedAt = stepStartedAt

            if computerUseCoordinator.isEnabled,
               let outcome = await performComputerUseDirectives(in: step.text) {
                outcomeLines.append(outcome)
            }

            // Breath between steps so the next flight reads as a new step.
            if pacesSteps {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        let lastWords = steps.last(where: { !$0.displayText.isEmpty })?.displayText ?? ""
        lingerCursorCaption(
            lastWords,
            keepingProgress: cursorCaptionProgress,
            shownAt: lastStepStartedAt,
            speechAlreadyEnded: pacesSteps && hasBegunSpeaking
        )
        retireAnnotations(withIDs: stepAnnotationIDs, after: 3)

        let outcome = outcomeLines.isEmpty ? nil : outcomeLines.joined(separator: "\n")
        return (outcome, lastPointedLocation)
    }

    private func releaseGuidancePointer() {
        isGuidancePointerHeld = false
    }

    // MARK: - Step drawings

    private func removeAnnotations(withIDs ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        activeAnnotations.removeAll { ids.contains($0.id) }
    }

    private func extendAnnotations(withIDs ids: Set<UUID>, by seconds: TimeInterval) {
        guard !ids.isEmpty else { return }
        let expiry = Date().addingTimeInterval(seconds)
        activeAnnotations = activeAnnotations.map { annotation in
            guard ids.contains(annotation.id) else { return annotation }
            return ResolvedAnnotation(
                id: annotation.id,
                kind: annotation.kind,
                screenFrame: annotation.screenFrame,
                points: annotation.points,
                center: annotation.center,
                radius: annotation.radius,
                rect: annotation.rect,
                label: annotation.label,
                expiresAt: expiry
            )
        }
    }

    private func retireAnnotations(withIDs ids: Set<UUID>, after seconds: TimeInterval) {
        guard !ids.isEmpty else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.removeAnnotations(withIDs: ids)
        }
    }
}

extension CompanionManager {
    /// Plays a finished reply step by step, reports what any actions did,
    /// and sets up the next walkthrough step.
    func playGuidedTurn(
        _ reply: GuidedReply,
        screenCaptures: [CompanionScreenCapture]
    ) async throws {
        let (actionOutcome, _) = try await playGuidedReply(
            reply,
            screenCaptures: screenCaptures
        )
        if let actionOutcome {
            appendAssistantMessage(actionOutcome)
        }

        guard activeWalkthrough != nil else { return }
        if let actionOutcome, !actionOutcome.contains("I won't") {
            // HeyMate did the step itself; look again and keep going.
            disarmWalkthroughClickMonitor()
            continueWalkthroughAutomatically(after: 1.2)
        }
        // Otherwise the click monitor armed when the buddy pointed is
        // already listening, and "next" by voice works too.
    }
}
