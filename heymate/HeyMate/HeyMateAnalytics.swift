//
//  HeyMateAnalytics.swift
//  HeyMate
//
//  Centralized PostHog analytics wrapper. All event names and properties
//  are defined here so instrumentation is consistent and easy to audit.
//

import Foundation
import PostHog

/// Numeric-only projection of model-derived screen text. The original label and
/// commentary are deliberately discarded during initialization so neither can
/// be passed to PostHog or unified logging by accident.
struct ScreenPointingTelemetrySummary {
    let x: Int
    let y: Int
    let labelCharacterCount: Int
    let commentaryCharacterCount: Int

    init(
        coordinate: CGPoint?,
        elementLabel: String?,
        commentary: String? = nil
    ) {
        x = coordinate.map { Int($0.x) } ?? -1
        y = coordinate.map { Int($0.y) } ?? -1
        labelCharacterCount = elementLabel?.count ?? 0
        commentaryCharacterCount = commentary?.count ?? 0
    }

    var analyticsProperties: [String: Any] {
        [
            "x": x,
            "y": y,
            "label_character_count": labelCharacterCount
        ]
    }
}

enum AnalyticsErrorCategory: String {
    case responsePipeline = "response_pipeline"
    case textToSpeech = "text_to_speech"

    var eventName: String {
        switch self {
        case .responsePipeline: return "response_error"
        case .textToSpeech: return "tts_error"
        }
    }
}

/// Bounded error metadata for analytics and logs. `localizedDescription` and
/// NSError userInfo are intentionally never retained.
struct AnalyticsErrorSummary {
    private static let maximumDomainLength = 80
    private static let allowedDomainCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "._-"))

    let category: AnalyticsErrorCategory
    let domain: String
    let code: Int

    init(category: AnalyticsErrorCategory, error: Error) {
        let nsError = error as NSError
        self.category = category
        domain = Self.boundedDomain(nsError.domain)
        code = nsError.code
    }

    var analyticsProperties: [String: Any] {
        [
            "category": category.rawValue,
            "error_domain": domain,
            "error_code": code
        ]
    }

    private static func boundedDomain(_ rawDomain: String) -> String {
        let domain = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty,
              domain.unicodeScalars.allSatisfy(allowedDomainCharacters.contains) else {
            return "other"
        }
        return String(domain.prefix(maximumDomainLength))
    }
}

enum HeyMateAnalytics {

    // MARK: - Setup

    /// PostHog is opt-in for HeyMate builds: keys are read from the app
    /// bundle's Info.plist (POSTHOG_API_KEY / POSTHOG_HOST). When absent —
    /// the default — every tracking call below is a safe no-op.
    private static var isEnabled = false

    static func configure() {
        guard let apiKey = AppBundleConfiguration.stringValue(forKey: "POSTHOG_API_KEY"),
              !apiKey.isEmpty else {
            isEnabled = false
            return
        }

        let config = PostHogConfig(
            apiKey: apiKey,
            host: AppBundleConfiguration.stringValue(forKey: "POSTHOG_HOST") ?? "https://us.i.posthog.com"
        )
        PostHogSDK.shared.setup(config)
        isEnabled = true
    }

    // MARK: - App Lifecycle

    /// Fired once on every app launch in applicationDidFinishLaunching.
    static func trackAppOpened() {
        guard isEnabled else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        PostHogSDK.shared.capture("app_opened", properties: [
            "app_version": version
        ])
    }

    // MARK: - Onboarding

    /// User clicked the Start button to begin onboarding for the first time.
    static func trackOnboardingStarted() {
        guard isEnabled else { return }
        PostHogSDK.shared.capture("onboarding_started")
    }

    /// User clicked "Watch Onboarding Again" from the panel footer.
    static func trackOnboardingReplayed() {
        guard isEnabled else { return }
        PostHogSDK.shared.capture("onboarding_replayed")
    }

    /// The onboarding intro finished playing to the end.
    static func trackOnboardingVideoCompleted() {
        guard isEnabled else { return }
        PostHogSDK.shared.capture("onboarding_video_completed")
    }

    /// The onboarding demo interaction where HeyMate points at something.
    static func trackOnboardingDemoTriggered() {
        guard isEnabled else { return }
        PostHogSDK.shared.capture("onboarding_demo_triggered")
    }

    // MARK: - Permissions

    /// All required permissions (accessibility, screen recording, mic) are granted.
    static func trackAllPermissionsGranted() {
        guard isEnabled else { return }
        PostHogSDK.shared.capture("all_permissions_granted")
    }

    /// A single permission was granted. Called when polling detects a change.
    static func trackPermissionGranted(permission: String) {
        guard isEnabled else { return }
        PostHogSDK.shared.capture("permission_granted", properties: [
            "permission": permission
        ])
    }

    // MARK: - Voice Interaction

    /// User pressed the push-to-talk shortcut (control+option) to start talking.
    static func trackPushToTalkStarted() {
        guard isEnabled else { return }
        PostHogSDK.shared.capture("push_to_talk_started")
    }

    /// User released the shortcut — transcript is being finalized.
    static func trackPushToTalkReleased() {
        guard isEnabled else { return }
        PostHogSDK.shared.capture("push_to_talk_released")
    }

    /// Transcription completed and the user's message is being sent to the AI.
    /// Privacy invariant: only the character count is reported — never the
    /// transcript itself.
    static func trackUserMessageSent(transcript: String) {
        guard isEnabled else { return }
        PostHogSDK.shared.capture("user_message_sent", properties: [
            "character_count": transcript.count
        ])
    }

    /// The AI responded and the response is being spoken via TTS.
    /// Privacy invariant: only the character count is reported — never the
    /// response text itself.
    static func trackAIResponseReceived(response: String) {
        guard isEnabled else { return }
        PostHogSDK.shared.capture("ai_response_received", properties: [
            "character_count": response.count
        ])
    }

    /// Claude's response included a [POINT:x,y:label] coordinate tag. Only its
    /// numeric projection is reported; screen-derived text never leaves the Mac.
    static func trackElementPointed(_ summary: ScreenPointingTelemetrySummary) {
        guard isEnabled else { return }
        PostHogSDK.shared.capture(
            "element_pointed",
            properties: summary.analyticsProperties
        )
    }

    // MARK: - Errors

    /// An error occurred in a bounded pipeline category. Only category,
    /// sanitized domain, and numeric code are sent — never descriptions or
    /// upstream response bodies.
    static func trackError(_ summary: AnalyticsErrorSummary) {
        guard isEnabled else { return }
        PostHogSDK.shared.capture(
            summary.category.eventName,
            properties: summary.analyticsProperties
        )
    }
}
