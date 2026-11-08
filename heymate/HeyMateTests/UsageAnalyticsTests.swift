import Foundation
import Testing
@testable import HeyMate

@MainActor
struct UsageAnalyticsTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "analytics-tests-\(UUID().uuidString)")!
    }

    @Test func noConsentMeansNoIdentityNoQueueNoNetwork() async {
        let preferences = defaults()
        var requests = 0
        let analytics = UsageAnalytics(defaults: preferences, apiKey: "phc_test", privacyReviewed: true, send: { _ in
            requests += 1
            return 200
        })
        analytics.configure()
        analytics.track(.diagnostic(feature: .mate, outcome: .reused, count: 12))
        analytics.track(.diagnostic(feature: .lesson, outcome: .modelReportedComplete, count: 20))
        await Task.yield()
        #expect(!analytics.isOptedIn)
        #expect(preferences.string(forKey: UsageAnalytics.identityKey) == nil)
        #expect(analytics.pendingEvents.isEmpty)
        #expect(requests == 0)
    }

    @Test func missingKeyAndUnsafeHostStayInertEvenWithConsent() {
        for (key, host) in [("", "https://us.i.posthog.com"), ("$(POSTHOG_API_KEY)", "https://us.i.posthog.com"), ("phc_test", "http://example.com"), ("phx_secret", "https://us.i.posthog.com")] {
            let preferences = defaults()
            let analytics = UsageAnalytics(defaults: preferences, apiKey: key, host: host, privacyReviewed: true)
            analytics.setOptedIn(true)
            analytics.track(.diagnostic(feature: .mate, outcome: .reused, count: 1))
            #expect(!analytics.isAvailable)
            #expect(analytics.pendingEvents.isEmpty)
            #expect(preferences.string(forKey: UsageAnalytics.identityKey) == nil)
        }
    }

    @Test func mateReuseUsesStableIDAcrossLaunches() async throws {
        let preferences = defaults()
        var requests: [URLRequest] = []
        let send: (URLRequest) async throws -> Int = { request in requests.append(request); return 200 }
        let first = UsageAnalytics(defaults: preferences, apiKey: "phc_test", version: "1.2.3", privacyReviewed: true, send: send)
        first.setOptedIn(true)
        first.track(.diagnostic(feature: .setup, outcome: .completed))
        first.track(.diagnostic(feature: .mate, outcome: .reused, count: 12))
        first.track(.diagnostic(feature: .lesson, outcome: .modelReportedComplete, count: 24))
        let id = try #require(preferences.string(forKey: UsageAnalytics.identityKey))
        let returnVisit = UsageAnalytics(defaults: preferences, apiKey: "phc_test", version: "1.2.4", privacyReviewed: true,
                                        now: { Date(timeIntervalSince1970: 1_800_000_000) }, send: send)
        returnVisit.track(.diagnostic(feature: .mate, outcome: .reused, count: 3))
        #expect(preferences.string(forKey: UsageAnalytics.identityKey) == id)
        for _ in 0..<50 where requests.count < 2 { await Task.yield() }
        #expect(requests.count == 2)
        let batches = try requests.map { try JSONSerialization.jsonObject(with: #require($0.httpBody)) as! [String: Any] }
        let events = batches.flatMap { $0["batch"] as! [[String: Any]] }
        #expect(events.filter { $0["event"] as? String == "mate_outcome" }.count == 2)
        #expect(events.filter { $0["event"] as? String == "lesson_outcome" }.count == 1)
        #expect(Set(events.compactMap { $0["distinct_id"] as? String }) == [id])
        for event in events {
            let properties = event["properties"] as! [String: Any]
            #expect(properties["$process_person_profile"] as? Bool == false)
            #expect(properties["$geoip_disable"] as? Bool == true)
            #expect(Set(properties.keys).isSubset(of: ["app_version", "os_version", "analytics_schema", "diagnostics_category", "feature", "outcome", "provider", "failure_category", "count", "duration_ms", "$process_person_profile", "$geoip_disable"]))
        }
    }

    @Test func revokingConsentClearsQueueAndReoptInCreatesFreshID() async throws {
        let preferences = defaults()
        var requests = 0
        let analytics = UsageAnalytics(defaults: preferences, apiKey: "phc_test", privacyReviewed: true, send: { _ in
            requests += 1
            try await Task.sleep(for: .seconds(60))
            return 200
        })
        analytics.setOptedIn(true)
        analytics.track(.diagnostic(feature: .mate, outcome: .reused, count: 10))
        let firstID = try #require(preferences.string(forKey: UsageAnalytics.identityKey))
        analytics.setOptedIn(false)
        analytics.track(.diagnostic(feature: .lesson, outcome: .modelReportedComplete, count: 20))
        await Task.yield()
        #expect(analytics.pendingEvents.isEmpty)
        #expect(preferences.string(forKey: UsageAnalytics.identityKey) == nil)
        #expect(!preferences.bool(forKey: UsageAnalytics.consentKey))
        #expect(requests == 0)
        analytics.setOptedIn(true)
        analytics.track(.diagnostic(feature: .mate, outcome: .reused, count: 2))
        #expect(preferences.string(forKey: UsageAnalytics.identityKey) != firstID)
        analytics.setOptedIn(false)
    }
    @Test func optOutCancelsInFlightTransportAndDropsBacklog() async {
        let preferences = defaults()
        var requests = 0
        var cancelled = false
        let analytics = UsageAnalytics(defaults: preferences, apiKey: "phc_test", privacyReviewed: true, send: { _ in
            requests += 1
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled = true; throw error }
            return 200
        })
        analytics.setOptedIn(true)
        analytics.track(.diagnostic(feature: .mate, outcome: .reused, count: 10))
        for _ in 0..<100 where requests == 0 { await Task.yield() }
        #expect(requests == 1)
        analytics.track(.diagnostic(feature: .mate, outcome: .reused, count: 20))
        analytics.setOptedIn(false)
        for _ in 0..<100 where !cancelled { await Task.yield() }
        #expect(cancelled)
        #expect(analytics.pendingEvents.isEmpty)
        #expect(preferences.string(forKey: UsageAnalytics.identityKey) == nil)
        #expect(requests == 1)
    }
}
