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

enum DiagnosticsProvider: String, CaseIterable {
    case codex, claudeCode, openCode, customAPI, onDevice, unknown
}

enum DiagnosticsFeature: String { case setup, lesson, mate }
enum DiagnosticsOutcome: String {
    case completed, skipped, failed, reused, ended, expired
    case modelReportedComplete = "model_reported_complete"
}
enum DiagnosticsFailure: String { case none, permission, provider, speech, unknown }

/// Numeric versions only. Build/SDK metadata is untrusted, even if it happens
/// to contain letters and digits that look like a harmless identifier.
enum DiagnosticsSchema {
    static func version(_ text: String) -> String {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count), parts.allSatisfy({
            (1...4).contains($0.count) && $0.allSatisfy { "0123456789".contains($0) }
        }) else { return "unknown" }
        return text
    }
    static var osVersion: String {
        let value = ProcessInfo.processInfo.operatingSystemVersion
        return "\(value.majorVersion).\(value.minorVersion).\(value.patchVersion)"
    }
}

struct CrashDiagnosticSummary {
    enum Kind: String { case badAccess = "bad_access", badInstruction = "bad_instruction", abort, resource, other }
    let kind: Kind
    let appVersion: String

    /// Reconstruct a fresh envelope; do not mutate/redact an SDK dictionary.
    /// Unknown keys, stack frames, account/device identifiers and error text
    /// are discarded by construction.
    init(envelope: [String: Any]) {
        let exception = envelope["exception"] as? [String: Any] ?? [:]
        switch exception["type"] as? String {
        case "EXC_BAD_ACCESS": kind = .badAccess
        case "EXC_BAD_INSTRUCTION": kind = .badInstruction
        case "EXC_CRASH": kind = .abort
        case "EXC_RESOURCE": kind = .resource
        default: kind = .other
        }
        let bundle = envelope["bundleInfo"] as? [String: Any] ?? [:]
        appVersion = DiagnosticsSchema.version(bundle["CFBundleShortVersionString"] as? String ?? "")
    }
    var properties: [String: Any] { ["failure_category": kind.rawValue, "crash_app_version": appVersion] }
}

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
        case diagnostic(feature: DiagnosticsFeature, outcome: DiagnosticsOutcome,
                        provider: DiagnosticsProvider = .unknown, failure: DiagnosticsFailure = .none,
                        count: Int = 0, durationMilliseconds: Int = 0)
        case crash(CrashDiagnosticSummary)
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
            case .diagnostic(let feature, _, _, _, _, _): return feature.rawValue + "_outcome"
            case .crash: return "crash_report"
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
            case .diagnostic(let feature, let outcome, let provider, let failure, let count, let duration):
                return ["feature": feature.rawValue, "outcome": outcome.rawValue, "provider": provider.rawValue,
                        "failure_category": failure.rawValue, "count": min(max(count, 0), 10_000),
                        "duration_ms": min(max(duration, 0), 3_600_000)]
            case .crash(let summary): return summary.properties
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
    static let crashes = UsageAnalytics(category: .crash,
        apiKey: AppBundleConfiguration.stringValue(forKey: "CRASH_DIAGNOSTICS_API_KEY"),
        host: AppBundleConfiguration.stringValue(forKey: "CRASH_DIAGNOSTICS_HOST"))
    static func configure() {
        shared.configure()
        crashes.configure()
        crashes.collectCrashReports()
    }
    static func track(_ event: Event) { shared.track(event) }
    static func trackAppOpened() {
        track(.appOpened(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"))
    }
}

/// Consent is checked before creating an identity, queue, or network session.
/// Send only our explicit event schema, without SDK autocapture or device enrichment.
@MainActor
final class UsageAnalytics: ObservableObject {
    enum Category: String { case product, crash }
    static let consentKey = "heymate.analytics.optIn.v1"
    static let identityKey = "heymate.analytics.installID.v1"
    static let disclosure = "Share setup outcomes, model-reported lesson completion and mate reuse counts with HeyMate via PostHog. Includes app/OS versions, provider category and a random product install ID. No chats, screens, audio, paths or accounts. Off by default; declining changes no features."
    static let crashDisclosure = "On the next launch, share a summary of new HeyMate macOS crash reports: app/OS versions and a fixed failure category. No stack traces, memory, raw error text or account details. Uses a separate random crash install ID. Off by default; independent of product diagnostics."

    @Published private(set) var isOptedIn: Bool
    var isAvailable: Bool { privacyReviewed && apiKey != nil && endpoint != nil }
    let category: Category
    private var consentKey: String { category == .product ? Self.consentKey : "heymate.crashes.optIn.v1" }
    private var identityKey: String { category == .product ? Self.identityKey : "heymate.crashes.installID.v1" }
    private var sinceKey: String { "heymate.diagnostics.\(category.rawValue).since.v1" }
    private var cursorKey: String { "heymate.diagnostics.\(category.rawValue).cursor.v1" }
    private let privacyReviewed: Bool
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
    private var lastPreviewEvent: [String: Any]?

    init(defaults: UserDefaults = .standard, category: Category = .product,
         apiKey: String? = AppBundleConfiguration.stringValue(forKey: "POSTHOG_API_KEY"),
         host: String? = AppBundleConfiguration.stringValue(forKey: "POSTHOG_HOST"),
         version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
         privacyReviewed: Bool = AppBundleConfiguration.stringValue(forKey: "DIAGNOSTICS_PRIVACY_REVIEWED") == "v2",
         now: @escaping () -> Date = Date.init,
         send: ((URLRequest) async throws -> Int)? = nil) {
        self.defaults = defaults
        self.category = category
        self.privacyReviewed = privacyReviewed
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.apiKey = key.hasPrefix("phc_") || key.hasPrefix("ph_project_") ? key : nil
        // Only the two documented ingestion hosts. Never send to an arbitrary build URL.
        let host = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = host.isEmpty ? "https://us.i.posthog.com" : host
        self.endpoint = ["https://us.i.posthog.com", "https://eu.i.posthog.com"].contains(base)
            ? URL(string: base + "/batch/") : nil
        self.version = DiagnosticsSchema.version(version)
        self.now = now
        self.sendOverride = send
        self.isOptedIn = defaults.bool(forKey: category == .product ? Self.consentKey : "heymate.crashes.optIn.v1")
    }

    func configure() {
        // No initialization, identifier creation, or network traffic until an event
        // follows consent. Also forget any identity left by a previous opt-out.
        if !isOptedIn { defaults.removeObject(forKey: identityKey) }
    }

    func setOptedIn(_ enabled: Bool) {
        guard !enabled || !isOptedIn else { return }
        isOptedIn = enabled
        defaults.set(enabled, forKey: consentKey)
        if enabled { defaults.set(now().timeIntervalSince1970, forKey: sinceKey) }
        if !enabled {
            generation = UUID()
            worker?.cancel()
            worker = nil
            session?.invalidateAndCancel()
            session = nil
            pendingEvents.removeAll()
            defaults.removeObject(forKey: identityKey)
            defaults.removeObject(forKey: sinceKey)
            defaults.removeObject(forKey: cursorKey)
            lastPreviewEvent = nil
        }
    }

    func track(_ event: HeyMateAnalytics.Event) {
        guard isOptedIn, isAvailable else { return }
        // Legacy instrumentation remains source compatible but cannot upload.
        // This deliberately starts with three product features, not every tap.
        switch (category, event) {
        case (.product, .diagnostic), (.crash, .crash): break
        default: return
        }
        let id = defaults.string(forKey: identityKey).flatMap(UUID.init(uuidString:))?.uuidString ?? UUID().uuidString
        defaults.set(id, forKey: identityKey)
        var properties = event.properties ?? [:]
        properties["app_version"] = version
        properties["os_version"] = DiagnosticsSchema.osVersion
        properties["analytics_schema"] = 2
        properties["diagnostics_category"] = category.rawValue
        properties["$process_person_profile"] = false
        properties["$geoip_disable"] = true
        let timestamp = ISO8601DateFormatter().string(from: now())
        func append(_ name: String, _ properties: [String: Any]) {
            pendingEvents.append(["event": name, "distinct_id": id,
                                  "properties": properties, "timestamp": timestamp,
                                  "uuid": UUID().uuidString])
        }
        append(event.name, properties)
        lastPreviewEvent = pendingEvents.last
        // Bounded, memory-only queue. Never replay pre-consent history.
        if pendingEvents.count > 100 { pendingEvents.removeFirst(pendingEvents.count - 100) }
        startWorker()
    }

    /// Preview is local and available even when no destination is configured.
    /// It excludes the public ingestion key and never creates an install ID.
    func previewData() throws -> Data {
        let example: HeyMateAnalytics.Event = category == .product
            ? .diagnostic(feature: .setup, outcome: .completed)
            : .crash(CrashDiagnosticSummary(envelope: [:]))
        var properties = example.properties ?? [:]
        properties["app_version"] = version
        properties["os_version"] = DiagnosticsSchema.osVersion
        properties["analytics_schema"] = 2
        properties["diagnostics_category"] = category.rawValue
        properties["$process_person_profile"] = false
        properties["$geoip_disable"] = true
        let exampleEvent: [String: Any] = ["event": example.name, "properties": properties,
                                          "distinct_id": "preview-only", "timestamp": "example", "uuid": "preview-only"]
        return try JSONSerialization.data(withJSONObject: [
            "category": category.rawValue, "consented": isOptedIn, "configured": isAvailable,
            "destination": endpoint?.absoluteString ?? "unconfigured", "example": lastPreviewEvent == nil,
            "payload": lastPreviewEvent ?? exampleEvent
        ], options: [.prettyPrinted, .sortedKeys])
    }

    /// macOS owns crash capture. Read only our own new .ips reports, then
    /// reconstruct the small allowlisted summary. No crash SDK is initialized.
    func collectCrashReports(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports")) {
        guard category == .crash, isOptedIn, isAvailable else { return }
        let since = defaults.double(forKey: sinceKey)
        // Legacy/absent consent epochs must not upload historical reports.
        guard since > 0 else { defaults.set(now().timeIntervalSince1970, forKey: sinceKey); return }
        let cursor = max(since, defaults.double(forKey: cursorKey))
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])) ?? []
        var reports: [(Date, CrashDiagnosticSummary)] = []
        for file in files where file.lastPathComponent.hasPrefix("HeyMate-") && file.pathExtension == "ips" {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 2_097_152,
                  let data = try? Data(contentsOf: file), let newline = data.firstIndex(of: 10),
                  let report = try? JSONSerialization.jsonObject(with: Data(data[(newline + 1)...])) as? [String: Any],
                  let bundle = report["bundleInfo"] as? [String: Any],
                  bundle["CFBundleIdentifier"] as? String == "com.heymate.app",
                  let timestamp = report["captureTime"] as? String else { continue }
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
            guard let date = format.date(from: timestamp), date.timeIntervalSince1970 > cursor,
                  date <= now() else { continue }
            reports.append((date, CrashDiagnosticSummary(envelope: report)))
        }
        for (date, summary) in reports.sorted(by: { $0.0 < $1.0 }).suffix(20) {
            track(.crash(summary))
            defaults.set(date.timeIntervalSince1970, forKey: cursorKey)
        }
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
                request.setValue("HeyMate-Diagnostics/2", forHTTPHeaderField: "User-Agent")
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
                            configuration.urlCredentialStorage = nil
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
