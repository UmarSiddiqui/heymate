//
//  CompanionManager+Onboarding.swift
//  HeyMate
//
//  The first-run introduction. New installs get the welcome tour window
//  (OnboardingWindow.swift); this file holds the CompanionManager side of
//  it: opening and finishing the tour, answering a question about the
//  screen in one shot, and speaking a line and waiting for it.
//
//  The older cursor-only introduction (welcome line → demo point → talk
//  prompt) still plays when the cursor is shown with `playingWelcome`.
//

import AppKit
import OSLog
import SwiftUI

extension CompanionManager {

    /// How long after the welcome the demo fires, and when the talk prompt
    /// follows it. The gap lets the cursor's flight and remark finish first.
    private static let demoDelay: Duration = .seconds(2)
    private static let talkPromptDelay: Duration = .seconds(9)
    private static let talkPromptVisibleFor: Duration = .seconds(10)

    // MARK: - Entry points

    /// Opens the welcome tour. A first run starts at the beginning, or
    /// where a quit left it; `restart` starts over (Settings › Replay).
    func openWelcomeTour(restart: Bool = false) {
        NotificationCenter.default.post(name: .heyMateDismissPanel, object: nil)
        HeyMateAnalytics.track(restart ? .onboardingReplayed : .onboardingStarted)
        // Replay starts from Settings, whose window can float above others
        // when it hangs from the notch; the tour should be on top.
        closeDesktopWindow()
        onboardingWindowController.show(restart: restart)
    }

    /// Kept for callers of the old setup card: both now open the tour.
    func triggerOnboarding() { openWelcomeTour() }
    func replayOnboarding() { openWelcomeTour(restart: true) }

    /// The tour's last step, or Skip. From here on the cursor appears at
    /// launch and the tour doesn't open by itself again.
    func finishWelcomeTour(openingHome: Bool) {
        onboardingTranscriptSink = nil
        hasCompletedOnboarding = true
        HeyMateAnalytics.track(.onboardingVideoCompleted)
        if allPermissionsGranted && isCursorCompanionEnabled && !isOverlayVisible {
            showCursorOverlay()
        }
        if openingHome {
            openDesktopWindow(section: .chat)
            cue(.homeReveal)
        }
    }

    // MARK: - Speaking

    /// Says `line` in HeyMate's voice and returns once it has finished, so
    /// the tour can wait for its own narration. Gives up after `timeout`.
    func speakAndWait(_ line: String, timeout: Duration = .seconds(12)) async {
        guard !line.isEmpty else { return }
        do {
            try await voiceSynthesisClient.speakText(line)
        } catch {
            HeyMateLog.log("⚠️ Welcome tour TTS failed: \(error.localizedDescription)")
            return
        }
        let deadline = ContinuousClock.now + timeout
        while voiceSynthesisClient.isPlaying, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    func stopSpeaking() {
        voiceSynthesisClient.stopPlayback()
    }

    // MARK: - One-shot screen answers

    /// Answers `request` about the cursor's screen in one sentence, flies
    /// the cursor to what it is about, and says the answer. Used by the
    /// welcome tour so a practice question never turns into an agent job.
    /// With `aboutSelection`, the region the person marked is the subject.
    /// Returns what was said, or nil when nothing could be answered.
    func answerTourQuestion(_ request: String, aboutSelection: Bool) async -> String? {
        guard !isFrontmostAppScreenExcluded else {
            HeyMateLog.log("🛡️ Welcome tour: frontmost app excluded — skipping capture")
            return nil
        }
        do {
            CaptureAudit.shared.recordCaptureAttempt(context: CaptureAudit.Context.onboardingDemoInteraction)
            let captures = try await ScreenCapture.allScreens()
            let screen: ScreenSnapshot
            if aboutSelection {
                guard let frame = spatialSelectionScreenFrame,
                      let selected = captures.first(where: { $0.displayFrame == frame }) else { return nil }
                screen = selected
            } else {
                guard let cursorScreen = captures.first(where: \.isCursorScreen) else { return nil }
                screen = cursorScreen
            }
            let label = screen.label
                + " (image dimensions: \(screen.screenshotWidthInPixels)x\(screen.screenshotHeightInPixels) pixels)"
            var prompt = request
            if aboutSelection, let selection = spatialSelectionPromptFragment() {
                prompt += "\n\n" + selection
            }
            let (reply, _) = try await activeConversationClient.analyzeImageStreaming(
                images: [(data: screen.imageData, label: label)],
                systemPrompt: CompanionPrompts.welcomeTourAnswer,
                conversationHistory: [],
                userPrompt: prompt,
                onTextChunk: { _ in }
            )
            let parsed = Self.parsePointingCoordinates(from: reply)
            let spoken = parsed.spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pixel = parsed.coordinate {
                pointingTarget = CursorPointingTarget(
                    location: globalPoint(forScreenshotPixel: pixel, in: screen),
                    displayFrame: screen.displayFrame,
                    caption: spoken.isEmpty ? nil : spoken
                )
            }
            if aboutSelection { clearSpatialSelection() }
            guard !spoken.isEmpty else { return nil }
            await speakAndWait(spoken)
            return spoken
        } catch {
            HeyMateLog.log("⚠️ Welcome tour answer failed: \(error)")
            return nil
        }
    }

    /// ReferenceRenderer's drawn "here's how I'd help you" step: one real turn, drawn on their screen, carrying the tour's note
    /// and what they said in the interview. Returns once it has been drawn and said, or false when it never started.
    func runDrawnTourStep(_ request: String, interview: [OnboardingInterviewLine], name: String?) async -> Bool {
        guard !isFrontmostAppScreenExcluded else { return false }
        let told = interview.map { ($0.speaker == .user ? (name ?? "Them") : "HeyMate") + ": " + $0.text }
            .joined(separator: "\n")
        pendingTurnNote = CompanionPrompts.drawnTourStep(interview: told, talkKeys: PushToTalkShortcut.talk.displayText)
        sendTranscriptToClaudeWithScreenshot(transcript: request, shouldCaptureScreen: true)
        let began = ContinuousClock.now
        var started = false
        while ContinuousClock.now - began < .seconds(300) {
            try? await Task.sleep(for: .milliseconds(250))
            let busy = state != .idle || isResponseInFlight
            if busy { started = true } else if started { break }
            if !started, ContinuousClock.now - began > .seconds(10) { break }
        }
        pendingTurnNote = nil
        HeyMateLog.log("🖍️ Drawn tour step \(started ? "drawn" : "never started")")
        return started
    }

    /// Called by the cursor once its welcome line has faded.
    func continueOnboardingAfterWelcome() {
        onboardingIntroTask?.cancel()
        onboardingIntroTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.demoDelay)
                HeyMateAnalytics.track(.onboardingDemoTriggered)
                self?.performOnboardingDemoInteraction()

                try await Task.sleep(for: Self.talkPromptDelay - Self.demoDelay)
                HeyMateAnalytics.track(.onboardingVideoCompleted)
                try await self?.typeOutTalkPrompt()
            } catch {
                // Cancelled: a replay started over, or the user began talking.
            }
        }
    }

    /// Fades the talk prompt away, for instance because the user did what
    /// it asked. Safe to call when it isn't showing.
    func dismissOnboardingPrompt() {
        onboardingIntroTask?.cancel()
        onboardingIntroTask = nil
        guard showOnboardingPrompt else { return }
        withAnimation(.easeOut(duration: 0.3)) { onboardingPromptOpacity = 0 }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, self.onboardingPromptOpacity == 0 else { return }
            self.showOnboardingPrompt = false
            self.onboardingPromptText = ""
        }
    }

    // MARK: - Talk prompt

    /// Types the prompt beside the cursor a letter at a time, names the
    /// shortcut the user actually has set, and fades it out if ignored.
    private func typeOutTalkPrompt() async throws {
        let message = "press \(PushToTalkShortcut.talk.displayText) and introduce yourself"
        onboardingPromptText = ""
        onboardingPromptOpacity = 0
        showOnboardingPrompt = true
        withAnimation(.easeIn(duration: 0.4)) { onboardingPromptOpacity = 1 }

        for character in message {
            try await Task.sleep(for: .milliseconds(30))
            onboardingPromptText.append(character)
        }

        try await Task.sleep(for: Self.talkPromptVisibleFor)
        withAnimation(.easeOut(duration: 0.3)) { onboardingPromptOpacity = 0 }
        try await Task.sleep(for: .milliseconds(350))
        showOnboardingPrompt = false
        onboardingPromptText = ""
    }

    // MARK: - Demo

    /// Shows one screenshot of the cursor's screen to the model, which picks
    /// something to remark on, and flies the cursor there with that remark.
    func performOnboardingDemoInteraction() {
        // Never talk over a reply that is still being worked out.
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            // Privacy: an excluded app on screen means no screenshot at all.
            guard !isFrontmostAppScreenExcluded else {
                HeyMateLog.log("🛡️ Onboarding demo: frontmost app excluded — skipping capture")
                return
            }
            do {
                CaptureAudit.shared.recordCaptureAttempt(context: CaptureAudit.Context.onboardingDemoInteraction)
                // Only the cursor's screen, so the model can't choose
                // something on a monitor the cursor isn't on.
                guard let screen = try await ScreenCapture.allScreens().first(where: \.isCursorScreen) else {
                    HeyMateLog.log("🎯 Onboarding demo: no cursor screen found")
                    return
                }
                let label = screen.label
                    + " (image dimensions: \(screen.screenshotWidthInPixels)x\(screen.screenshotHeightInPixels) pixels)"
                let (reply, _) = try await activeConversationClient.analyzeImageStreaming(
                    images: [(data: screen.imageData, label: label)],
                    systemPrompt: CompanionPrompts.onboardingDemo,
                    conversationHistory: [],
                    userPrompt: CompanionPrompts.onboardingDemoRequest,
                    onTextChunk: { _ in }
                )

                let parsed = Self.parsePointingCoordinates(from: reply)
                guard let pixel = parsed.coordinate else {
                    HeyMateLog.log("🎯 Onboarding demo: no element to point at")
                    return
                }
                // The remark rides along as the cursor's label instead of a
                // stock pointing phrase.
                pointingTarget = CursorPointingTarget(
                    location: globalPoint(forScreenshotPixel: pixel, in: screen),
                    displayFrame: screen.displayFrame,
                    caption: parsed.spokenText
                )

                let telemetry = ScreenPointingTelemetrySummary(
                    coordinate: pixel,
                    elementLabel: parsed.elementLabel,
                    commentary: parsed.spokenText
                )
                Self.screenPointingLogger.info(
                    "Onboarding pointing x=\(telemetry.x, privacy: .public) y=\(telemetry.y, privacy: .public) labelCharacters=\(telemetry.labelCharacterCount, privacy: .public) commentaryCharacters=\(telemetry.commentaryCharacterCount, privacy: .public)"
                )
            } catch {
                HeyMateLog.log("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
