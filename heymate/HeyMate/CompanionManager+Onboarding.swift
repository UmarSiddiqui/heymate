//
//  CompanionManager+Onboarding.swift
//  HeyMate
//
//  The first-run introduction. Once the cursor's welcome line has played,
//  HeyMate looks at the screen and points at something real (the "it can
//  see my screen" moment), then types out how to start talking.
//
//      welcome (CompanionCursorView) → demo point → talk prompt → fades out
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

    /// From the sign-in screen's Start button: the first ever run.
    func triggerOnboarding() {
        NotificationCenter.default.post(name: .heyMateDismissPanel, object: nil)
        // From now on the cursor appears at launch instead of the Start button.
        hasCompletedOnboarding = true
        HeyMateAnalytics.track(.onboardingStarted)
        showCursorOverlay(playingWelcome: true)
    }

    /// From Settings: the same introduction again.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .heyMateDismissPanel, object: nil)
        HeyMateAnalytics.track(.onboardingReplayed)
        showCursorOverlay(playingWelcome: true)
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
