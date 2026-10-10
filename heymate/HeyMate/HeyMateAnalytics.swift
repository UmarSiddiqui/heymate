//
//  HeyMateAnalytics.swift
//  HeyMate
//
//  Opt-in product analytics. Every event HeyMate can send is a case of
//  `HeyMateAnalytics.Event`, so the full list of names and properties is
//  readable in one place and checked by the privacy tests. Nothing here
//  ever carries user text: transcripts, replies and screen labels are
//  reduced to counts before they reach an event.
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

    enum Event {
        case appOpened(version: String)
        case onboardingStarted
        case onboardingReplayed
        case onboardingVideoCompleted
        case onboardingDemoTriggered
        case permissionGranted(String)
        case allPermissionsGranted
        case pushToTalkStarted
        case pushToTalkReleased
        case userMessageSent(characterCount: Int)
        case aiResponseReceived(characterCount: Int)
        case elementPointed(ScreenPointingTelemetrySummary)
        case error(AnalyticsErrorSummary)

        var name: String {
            switch self {
            case .appOpened: return "app_opened"
            case .onboardingStarted: return "onboarding_started"
            case .onboardingReplayed: return "onboarding_replayed"
            case .onboardingVideoCompleted: return "onboarding_video_completed"
            case .onboardingDemoTriggered: return "onboarding_demo_triggered"
            case .permissionGranted: return "permission_granted"
            case .allPermissionsGranted: return "all_permissions_granted"
            case .pushToTalkStarted: return "push_to_talk_started"
            case .pushToTalkReleased: return "push_to_talk_released"
            case .userMessageSent: return "user_message_sent"
            case .aiResponseReceived: return "ai_response_received"
            case .elementPointed: return "element_pointed"
            case .error(let summary): return summary.category.eventName
            }
        }

        var properties: [String: Any]? {
            switch self {
            case .appOpened(let version): return ["app_version": version]
            case .permissionGranted(let permission): return ["permission": permission]
            case .userMessageSent(let count), .aiResponseReceived(let count):
                return ["character_count": count]
            case .elementPointed(let summary): return summary.analyticsProperties
            case .error(let summary): return summary.analyticsProperties
            case .onboardingStarted, .onboardingReplayed, .onboardingVideoCompleted,
                 .onboardingDemoTriggered, .allPermissionsGranted,
                 .pushToTalkStarted, .pushToTalkReleased:
                return nil
            }
        }
    }

    /// Set once by `configure()`. Builds without a PostHog key in Info.plist
    /// (the default) never set it, so `track` is a no-op for them.
    private static var isEnabled = false

    static func configure() {
        guard let apiKey = AppBundleConfiguration.stringValue(forKey: "POSTHOG_API_KEY") else { return }
        let host = AppBundleConfiguration.stringValue(forKey: "POSTHOG_HOST") ?? "https://us.i.posthog.com"
        PostHogSDK.shared.setup(PostHogConfig(apiKey: apiKey, host: host))
        isEnabled = true
    }

    static func track(_ event: Event) {
        guard isEnabled else { return }
        PostHogSDK.shared.capture(event.name, properties: event.properties)
    }

    static func trackAppOpened() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        track(.appOpened(version: version))
    }
}
