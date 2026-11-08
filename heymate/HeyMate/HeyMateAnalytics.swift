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
import Combine

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
        case notchOpened
        case onboardingStarted
        case onboardingReplayed
        case onboardingVideoCompleted
        case onboardingDemoTriggered
        case onboardingSkipped
        case onboardingStepViewed(step: String)
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
            case .notchOpened: return "notch_opened"
            case .onboardingStarted: return "onboarding_started"
            case .onboardingReplayed: return "onboarding_replayed"
            case .onboardingVideoCompleted: return "onboarding_video_completed"
            case .onboardingDemoTriggered: return "onboarding_demo_triggered"
            case .onboardingSkipped: return "onboarding_skipped"
            case .onboardingStepViewed: return "onboarding_step_viewed"
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
            case .notchOpened: return nil
            case .onboardingStepViewed(let step): return ["step": step]
            case .permissionGranted(let permission): return ["permission": permission]
            case .userMessageSent(let count), .aiResponseReceived(let count):
                return ["character_count": count]
            case .elementPointed(let summary): return summary.analyticsProperties
            case .error(let summary): return summary.analyticsProperties
            case .onboardingStarted, .onboardingReplayed, .onboardingVideoCompleted,
                 .onboardingDemoTriggered, .onboardingSkipped, .allPermissionsGranted,
                 .pushToTalkStarted, .pushToTalkReleased:
                return nil
            }
        }
    }

    static let shared = UsageAnalytics()
    static func configure() { shared.configure() }
    static func track(_ event: Event) { shared.track(event) }
    static func trackAppOpened() {
        track(.appOpened(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"))
    }
}

/// Consent is checked before creating an identity, queue, or network session.
/// Send only our explicit event schema, without SDK autocapture or device enrichment.
@MainActor
final class UsageAnalytics: ObservableObject {
    static let consentKey = "heymate.analytics.optIn.v1"
    static let identityKey = "heymate.analytics.installID.v1"
    static let disclosure = "Share usage counts and return visits with HeyMate via PostHog, linked by a random install ID. No messages, screenshots, files, or account details. Off by default; change this any time in Privacy & Data."

    @Published private(set) var isOptedIn: Bool
    var isAvailable: Bool { apiKey != nil && endpoint != nil }
    private let defaults: UserDefaults
    private let apiKey: String?
    private let endpoint: URL?
    private let version: String
    private let now: () -> Date
    private let sendOverride: ((URLRequest) async throws -> Int)?
    private var session: URLSession?
    private var worker: Task<Void, Never>?
    private(set) var pendingEvents: [[String: Any]] = []
    private var generation = UUID()

    init(defaults: UserDefaults = .standard,
         apiKey: String? = AppBundleConfiguration.stringValue(forKey: "POSTHOG_API_KEY"),
         host: String? = AppBundleConfiguration.stringValue(forKey: "POSTHOG_HOST"),
         version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
         now: @escaping () -> Date = Date.init,
         send: ((URLRequest) async throws -> Int)? = nil) {
        self.defaults = defaults
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.apiKey = key.hasPrefix("phc_") || key.hasPrefix("ph_project_") ? key : nil
        // Only the two documented ingestion hosts. Never send to an arbitrary build URL.
        let host = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = host.isEmpty ? "https://us.i.posthog.com" : host
        self.endpoint = ["https://us.i.posthog.com", "https://eu.i.posthog.com"].contains(base)
            ? URL(string: base + "/batch/") : nil
        self.version = version
        self.now = now
        self.sendOverride = send
        self.isOptedIn = defaults.bool(forKey: Self.consentKey)
    }

    func configure() {
        // No initialization, identifier creation, or network traffic until an event
        // follows consent. Also forget any identity left by a previous opt-out.
        if !isOptedIn { defaults.removeObject(forKey: Self.identityKey) }
    }

    func setOptedIn(_ enabled: Bool) {
        guard !enabled || !isOptedIn else { return }
        isOptedIn = enabled
        defaults.set(enabled, forKey: Self.consentKey)
        if !enabled {
            generation = UUID()
            worker?.cancel()
            worker = nil
            session?.invalidateAndCancel()
            session = nil
            pendingEvents.removeAll()
            defaults.removeObject(forKey: Self.identityKey)
        }
    }

    func track(_ event: HeyMateAnalytics.Event) {
        guard isOptedIn, isAvailable else { return }
        let id = defaults.string(forKey: Self.identityKey) ?? UUID().uuidString
        defaults.set(id, forKey: Self.identityKey)
        var properties = event.properties ?? [:]
        properties["app_version"] = version
        properties["analytics_schema"] = 1
        properties["$process_person_profile"] = false
        properties["$geoip_disable"] = true
        let timestamp = ISO8601DateFormatter().string(from: now())
        func append(_ name: String, _ properties: [String: Any]) {
            pendingEvents.append(["event": name, "distinct_id": id,
                                  "properties": properties, "timestamp": timestamp,
                                  "uuid": UUID().uuidString])
        }
        append(event.name, properties)
        // Only deliberate interactions count. Never infer use from idle polling.
        var activityProperties = properties
        activityProperties["source_event"] = event.name
        switch event {
        case .userMessageSent, .notchOpened:
            append("active_use", activityProperties)
        default: break
        }
        switch event {
        case .aiResponseReceived:
            append("value_received", activityProperties)
        default: break
        }
        // Bounded, memory-only queue. Never replay pre-consent history.
        if pendingEvents.count > 100 { pendingEvents.removeFirst(pendingEvents.count - 100) }
        startWorker()
    }

    private func startWorker() {
        guard worker == nil else { return }
        let token = generation
        worker = Task { [weak self] in
            guard let self else { return }
            var retryDelay: UInt64 = 2
            while !Task.isCancelled, self.isOptedIn, self.generation == token, !self.pendingEvents.isEmpty {
                let batch = Array(self.pendingEvents.prefix(20))
                guard let endpoint = self.endpoint, let apiKey = self.apiKey else { break }
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.timeoutInterval = 15
                request.httpBody = try? JSONSerialization.data(withJSONObject: ["api_key": apiKey, "batch": batch])
                do {
                    let status: Int
                    if let send = self.sendOverride {
                        status = try await send(request)
                    } else {
                        if self.session == nil {
                            let configuration = URLSessionConfiguration.ephemeral
                            configuration.httpCookieStorage = nil
                            configuration.urlCache = nil
                            self.session = URLSession(configuration: configuration)
                        }
                        let (_, response) = try await self.session!.data(for: request)
                        status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    }
                    guard self.generation == token, !Task.isCancelled else { return }
                    if (200..<300).contains(status) || ((400..<500).contains(status) && status != 429) {
                        let sentIDs = Set(batch.compactMap { $0["uuid"] as? String })
                        self.pendingEvents.removeAll { sentIDs.contains($0["uuid"] as? String ?? "") }
                        retryDelay = 2
                        continue
                    }
                } catch { /* Network errors carry no user text into telemetry. */ }
                do { try await Task.sleep(nanoseconds: retryDelay * 1_000_000_000) }
                catch { break }
                retryDelay = min(retryDelay * 2, 60)
            }
            if self.generation == token { self.worker = nil }
        }
    }
}
