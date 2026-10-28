//
//  CompanionManager+Guidance.swift
//  HeyMate
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
    let id = UUID()
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

        let walkthroughID = walkthrough.id
        let walkthroughVersion = walkthrough.updatedAt
        let walkthroughChatID = currentChat.id
        let walkthroughMateID = activeMateID
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            // A click can land while the step is still being spoken; let
            // that turn finish rather than talking over it.
            for _ in 0..<150 {
                guard !Task.isCancelled, let self, self.activeWalkthrough?.id == walkthroughID, self.activeWalkthrough?.updatedAt == walkthroughVersion,
                      self.currentChat.id == walkthroughChatID, self.activeMateID == walkthroughMateID else { return }
                if !self.isResponseInFlight { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard !Task.isCancelled, let self, self.activeWalkthrough?.id == walkthroughID, self.activeWalkthrough?.updatedAt == walkthroughVersion,
                  self.currentChat.id == walkthroughChatID, self.activeMateID == walkthroughMateID, !self.isResponseInFlight else { return }
            self.sendTranscriptToClaudeWithScreenshot(
                transcript: "done — what's next?",
                shouldCaptureScreen: true
            )
        }
    }

    /// A new model replaces the window. A patch changes the one already showing,
    /// or the model in this same reply when both arrived together.
    private func modelToShow(from reply: GuidedReply) -> Model3DSpec? {
        if let model = reply.model3D {
            guard let patch = reply.modelPatch else { return model }
            return model.patched(remove: patch.remove, about: patch.about, explode: patch.explode, section: patch.section)
        }
        guard let patch = reply.modelPatch, let current = model3DWindowController.currentModel else { return nil }
        return current.patched(remove: patch.remove, about: patch.about, explode: patch.explode, section: patch.section)
    }

    // MARK: - A drawing told as it streams in

    /// A reply drawing an explanation is drawn and told while it is still arriving, as ReferenceRenderer does: the overlay
    /// opens at its first say() line, takes the program as it grows, and each line is spoken as soon as it is complete,
    /// its strokes drawn while it is heard.
    func streamExplainer(_ replySoFar: String, owner: ObjectIdentifier, screenCaptures: [ScreenSnapshot]) {
        guard explainerWindowController.dismissedStreamOwner != owner else { return }
        guard let (code, closed) = ExplainerParser.streamingProgram(in: replySoFar) else { return }
        let lines = ExplainerParser.sayLines(in: code)
        let explainer = explainerWindowController
        if explainer.streamOwner != owner {
            // Only a block that speaks is a drawing (code they asked for has no say() lines).
            guard !lines.isEmpty else { return }
            let screen = screenCaptures.first(where: \.isCursorScreen) ?? screenCaptures.first
            guard let frame = screen?.displayFrame ?? NSScreen.main?.frame else { return }
            explainer.beginStream(owner: owner, on: frame, canvas: screen.map { CGSize(width: $0.screenshotWidthInPixels, height: $0.screenshotHeightInPixels) }, screenshot: screen?.imageData)
            explainer.streamSpeaker = Task { [weak self] in await self?.tellStreamingExplainer() }
        }
        explainer.streamLines = lines
        explainer.streamDone = closed
        explainer.feed(code, done: closed)
    }

    /// Speaks the drawing's lines in order as they arrive, each one's strokes drawn while it is heard.
    private func tellStreamingExplainer() async {
        let explainer = explainerWindowController
        HeyMateLog.log("🖍️ Explainer streaming: first line arrived")
        var k = 0
        while !Task.isCancelled {
            guard k < explainer.streamLines.count else {
                if explainer.streamDone { break }
                try? await Task.sleep(nanoseconds: 60_000_000)
                continue
            }
            let words = GuidedReplyParser.strippingMarkdownEmphasis(GuidedReplyParser.strippingControlTags(from: explainer.streamLines[k]))
            explainer.lineStart(k)
            cursorCaptionText = words
            let startedAt = Date()
            if !isSilentModeEnabled {
                do { try await voiceSynthesisClient.speakText(words) } catch {
                    // Without voice the drawing still follows the sentence's reading time.
                    HeyMateLog.log("🖍️ Explainer line \(k) not spoken: \(error)")
                }
            }
            let minimum = isSilentModeEnabled || !voiceSynthesisClient.isPlaying ? CursorCaptionTiming.readingSeconds(for: words) : 0
            while !Task.isCancelled, voiceSynthesisClient.isPlaying || Date().timeIntervalSince(startedAt) < minimum {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            explainer.lineEnd(k)
            k += 1
        }
        guard !Task.isCancelled else { return }
        explainer.finish()
    }

    // MARK: - A drawing's buttons and actions

    /// A button the drawing put up was pressed (ReferenceRenderer's ScreenDrawingActionButtons): open a page, copy, or ask.
    func runDrawingButton(kind: String, value: Any?) {
        switch kind {
        case "open": openDrawingPage(value as? String)
        case "copy": copyForDrawing(value as? String, note: "Copied")
        case "ask":
            if let words = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty {
                sendTranscriptToClaudeWithScreenshot(transcript: words, shouldCaptureScreen: true)
            }
        case "handoff":
            if let payload = value as? [String: Any] { handOffFromDrawing(payload) }
            else if let task = value as? String { handOffFromDrawing(["task": task]) }
        default:
            HeyMateLog.log("🖍️ Drawing button \(kind) is not supported yet")
        }
    }

    /// A line's action, as it is heard. typeText is ReferenceRenderer's drive for one step: with computer use on it goes
    /// through HeyMate's own drive (its approval rules, and the user can take the screen back): click the field, type.
    /// Without it, the text goes on the clipboard to paste, as ReferenceRenderer does when a field refuses it.
    func runDrawingAction(role: String, text: String, at point: CGPoint?) {
        switch role {
        case "copy": copyForDrawing(text, note: "Copied")
        case "type":
            guard computerUseCoordinator.isEnabled, let point, !text.isEmpty else {
                copyForDrawing(text, note: "Copied — paste it with ⌘V")
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let reason = "Type \"\(text.prefix(80))\" into the field you pointed at."
                self.computerUseCoordinator.beginDrive()
                defer { self.computerUseCoordinator.endDrive() }
                let clicked = await self.computerUseCoordinator.perform(.clickPoint(point), statedReason: reason)
                HeyMateLog.log("🖍️ Drawing typeText click at \(Int(point.x)),\(Int(point.y)): \(clicked)")
                guard self.computerUseCoordinator.takeBackReason == nil else { return }
                let typed = await self.computerUseCoordinator.perform(.typeText(text), statedReason: reason)
                HeyMateLog.log("🖍️ Drawing typeText: \(typed)")
            }
        case "open": openDrawingPage(text)
        case "handoff":
            let payload = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            handOffFromDrawing(payload ?? ["task": text])
        default: HeyMateLog.log("🖍️ Drawing action \(role) is not supported yet")
        }
    }

    private func copyForDrawing(_ text: String?, note: String) {
        guard let text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        cursorCaptionText = note
    }

    /// Only web pages: a drawing never opens files or apps.
    private func openDrawingPage(_ address: String?) {
        guard let address, let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else { return }
        NSWorkspace.shared.open(url)
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
        screenCaptures: [ScreenSnapshot]
    ) async throws -> (actionOutcome: String?, lastPointedLocation: CGPoint?) {
        if !reply.visualActions.isEmpty, !screenCaptures.isEmpty {
            applyVisualActions(reply.visualActions, screenCaptures: screenCaptures)
        }
        if let shown = modelToShow(from: reply) {
            let screen = screenCaptures.first(where: \.isCursorScreen) ?? screenCaptures.first
            if let frame = screen?.displayFrame ?? NSScreen.main?.frame {
                model3DWindowController.show(shown, on: frame)
                if let windowFrame = model3DWindowController.windowFrame {
                    modelBuildEvent = ModelBuildEvent(
                        id: UUID(), windowFrame: windowFrame, partCount: shown.parts.count)
                }
            }
        }
        if let program = reply.explainerProgram, let speaker = explainerWindowController.streamSpeaker {
            // Drawn and told while it streamed in: the whole program is in now, and the reply ends when its last
            // line has been heard.
            explainerWindowController.streamLines = ExplainerParser.sayLines(in: program)
            explainerWindowController.feed(program, done: true)
            explainerWindowController.streamDone = true
            isGuidancePointerHeld = true
            dispatch(.beginSpeaking)
            await withTaskCancellationHandler { await speaker.value } onCancel: { speaker.cancel() }
            isGuidancePointerHeld = false
            try Task.checkCancellation()
            return (nil, nil)
        }
        if let program = reply.explainerProgram {
            let screen = screenCaptures.first(where: \.isCursorScreen) ?? screenCaptures.first
            if let frame = screen?.displayFrame ?? NSScreen.main?.frame {
                explainerWindowController.showOrContinue(program: program, on: frame,
                                               canvas: screen.map { CGSize(width: $0.screenshotWidthInPixels, height: $0.screenshotHeightInPixels) }, screenshot: screen?.imageData)
            }
        }
        let steps = reply.steps.filter { !$0.displayText.isEmpty || $0.pointsSomewhere }
        guard !steps.isEmpty else { return (nil, nil) }
        // The program's say() lines close the reply; line k draws while it is spoken.
        let firstExplainerStep = reply.explainerProgram == nil ? steps.count : steps.count - reply.explainerLineCount

        try Task.checkCancellation()
        let responseCompletion = currentResponseCompletion
        isGuidancePointerHeld = true
        defer {
            // A slow cancelled speech/action callback must not release
            // the pointer already held by a newer response.
            if currentResponseCompletion === responseCompletion { releaseGuidancePointer() }
        }

        // Without anything to point at there is nothing to keep in sync, so
        // the reply plays as before: start speaking and hand back.
        let pacesSteps = reply.pointingStepCount > 0 || reply.explainerProgram != nil
        let progressPrefix: String? = activeWalkthrough?.progressLabel
        let pointingStepCount = reply.pointingStepCount
        var pointingStepNumber = 0
        var outcomeLines: [String] = []
        var lastPointedLocation: CGPoint?
        var stepAnnotationIDs: Set<UUID> = []
        var hasBegunSpeaking = false
        var lastStepStartedAt = Date()

        for (stepIndex, step) in steps.enumerated() {
            try Task.checkCancellation()
            let explainerLine = stepIndex >= firstExplainerStep ? stepIndex - firstExplainerStep : nil
            if let explainerLine { explainerWindowController.lineStart(explainerLine) }

            if step.pointsSomewhere, let pointing = step.pointing {
                // Circles, arrows and cards build one picture across the
                // reply; a new point or box replaces the step before it.
                let addsToPicture: Bool
                switch pointing.visualGuidance {
                case .circle?, .arrow?, .card?: addsToPicture = true
                default: addsToPicture = false
                }
                if !addsToPicture {
                    removeAnnotations(withIDs: stepAnnotationIDs)
                    stepAnnotationIDs = []
                }
                let before = Set(activeAnnotations.map(\.id))
                applyPointingParseResult(pointing, screenCaptures: screenCaptures)
                stepAnnotationIDs.formUnion(Set(activeAnnotations.map(\.id)).subtracting(before))
                // Drawings last as long as their step, not a fixed TTL.
                extendAnnotations(withIDs: stepAnnotationIDs, by: 120)
                if pointing.coordinate != nil {
                    lastPointedLocation = pointingTarget?.location
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
            if let explainerLine { explainerWindowController.lineEnd(explainerLine) }

            if computerUseCoordinator.isEnabled,
               let outcome = await performComputerUseDirectives(in: step.text) {
                try Task.checkCancellation()
                outcomeLines.append(outcome)
                // The user took the screen back: the rest of the steps
                // were built on a screen they are now changing.
                if computerUseCoordinator.takeBackReason != nil { break }
            }
            try Task.checkCancellation()

            // Breath between steps so the next flight reads as a new step.
            if pacesSteps {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        if reply.explainerProgram != nil { explainerWindowController.finish() }
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
        screenCaptures: [ScreenSnapshot]
    ) async throws {
        let (actionOutcome, _) = try await playGuidedReply(
            reply,
            screenCaptures: screenCaptures
        )
        try Task.checkCancellation()
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
