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
        let analytics = UsageAnalytics(defaults: preferences, apiKey: "phc_test", send: { _ in
            requests += 1
            return 200
        })
        analytics.configure()
        analytics.track(.userMessageSent(characterCount: 12), context: .userTyped)
        analytics.track(.aiResponseReceived(characterCount: 20), context: .userVoice)
        await Task.yield()
        #expect(!analytics.isOptedIn)
        #expect(preferences.string(forKey: UsageAnalytics.identityKey) == nil)
        #expect(analytics.pendingEvents.isEmpty)
        #expect(requests == 0)
    }

    @Test func missingKeyAndUnsafeHostStayInertEvenWithConsent() {
        for (key, host) in [("", "https://us.i.posthog.com"), ("$(POSTHOG_API_KEY)", "https://us.i.posthog.com"), ("phc_test", "http://example.com"), ("phx_secret", "https://us.i.posthog.com")] {
            let preferences = defaults()
            let analytics = UsageAnalytics(defaults: preferences, apiKey: key, host: host)
            analytics.setOptedIn(true)
            analytics.track(.userMessageSent(characterCount: 1))
            #expect(!analytics.isAvailable)
            #expect(analytics.pendingEvents.isEmpty)
            #expect(preferences.string(forKey: UsageAnalytics.identityKey) == nil)
        }
    }

    @Test func activeUseAndRetentionUseStableIDAcrossLaunches() async throws {
        let preferences = defaults()
        var requests: [URLRequest] = []
        let send: (URLRequest) async throws -> Int = { request in requests.append(request); return 200 }
        let first = UsageAnalytics(defaults: preferences, apiKey: "phc_test", version: "1.2.3", send: send)
        first.setOptedIn(true)
        first.track(.appOpened(version: "1.2.3"))
        first.track(.userMessageSent(characterCount: 12), context: .userTyped)
        first.track(.aiResponseReceived(characterCount: 24), context: .userTyped)
        let id = try #require(preferences.string(forKey: UsageAnalytics.identityKey))
        let returnVisit = UsageAnalytics(defaults: preferences, apiKey: "phc_test", version: "1.2.4",
                                        now: { Date(timeIntervalSince1970: 1_800_000_000) }, send: send)
        returnVisit.track(.userMessageSent(characterCount: 3), context: .userVoice)
        #expect(preferences.string(forKey: UsageAnalytics.identityKey) == id)
        for _ in 0..<50 where requests.count < 2 { await Task.yield() }
        #expect(requests.count == 2)
        let batches = try requests.map { try JSONSerialization.jsonObject(with: #require($0.httpBody)) as! [String: Any] }
        let events = batches.flatMap { $0["batch"] as! [[String: Any]] }
        #expect(events.filter { $0["event"] as? String == "active_use" }.count == 2)
        #expect(events.filter { $0["event"] as? String == "value_received" }.count == 1)
        #expect(Set(events.compactMap { $0["distinct_id"] as? String }) == [id])
        for event in events {
            let properties = event["properties"] as! [String: Any]
            #expect(properties["$process_person_profile"] as? Bool == false)
            #expect(properties["$geoip_disable"] as? Bool == true)
            #expect(Set(properties.keys).isSubset(of: ["app_version", "analytics_schema", "character_count", "$process_person_profile", "$geoip_disable", "source_event", "interaction_origin", "input_mode"]))
        }
    }

    @Test(arguments: AnalyticsInteractionContext.Origin.allCases, AnalyticsInteractionContext.InputMode.allCases)
    func contextAddsPropertiesWithoutAddingEvents(
        origin: AnalyticsInteractionContext.Origin,
        inputMode: AnalyticsInteractionContext.InputMode
    ) {
        let analytics = UsageAnalytics(defaults: defaults(), apiKey: "phc_test", send: { _ in 200 })
        analytics.setOptedIn(true)
        defer { analytics.setOptedIn(false) }
        let context = AnalyticsInteractionContext(origin: origin, inputMode: inputMode)
        analytics.track(.userMessageSent(characterCount: 12), context: context)
        analytics.track(.aiResponseReceived(characterCount: 24), context: context)
        let events = analytics.pendingEvents
        #expect(events.compactMap { $0["event"] as? String }
            == ["user_message_sent", "active_use", "ai_response_received", "value_received"])
        for event in events {
            let properties = event["properties"] as! [String: Any]
            #expect(properties["interaction_origin"] as? String == origin.rawValue)
            #expect(properties["input_mode"] as? String == inputMode.rawValue)
            #expect(properties["analytics_schema"] as? Int == 1)
            #expect(properties["$process_person_profile"] as? Bool == false)
            #expect(properties["$geoip_disable"] as? Bool == true)
        }
        #expect((events[1]["properties"] as? [String: Any])?["source_event"] as? String == "user_message_sent")
        #expect((events[3]["properties"] as? [String: Any])?["source_event"] as? String == "ai_response_received")
    }

    @Test func existingConsentAndInstallIDSurviveContextAddition() {
        let preferences = defaults()
        preferences.set(true, forKey: UsageAnalytics.consentKey)
        let existingID = UUID().uuidString
        preferences.set(existingID, forKey: UsageAnalytics.identityKey)
        let analytics = UsageAnalytics(defaults: preferences, apiKey: "phc_test", send: { _ in 200 })
        analytics.configure()
        analytics.track(.userMessageSent(characterCount: 12), context: .userTyped)
        #expect(analytics.isOptedIn)
        #expect(preferences.bool(forKey: UsageAnalytics.consentKey))
        #expect(preferences.string(forKey: UsageAnalytics.identityKey) == existingID)
        #expect(analytics.pendingEvents.allSatisfy { $0["distinct_id"] as? String == existingID })
        analytics.setOptedIn(false)
    }

    @Test func unclassifiedRepliesStayUnknownAndLifecycleEventsKeepTheirOwnOrigin() {
        let analytics = UsageAnalytics(defaults: defaults(), apiKey: "phc_test", send: { _ in 200 })
        analytics.setOptedIn(true)
        defer { analytics.setOptedIn(false) }
        analytics.track(.aiResponseReceived(characterCount: 1))
        AnalyticsInteractionScope.$current.withValue(.init(origin: .routine, inputMode: .none)) {
            analytics.track(.appOpened(version: "test"))
            analytics.track(.onboardingStepViewed(step: "permissions"))
            analytics.track(.notchOpened)
            // An explicit entry point takes priority over an inherited scope.
            analytics.track(.userMessageSent(characterCount: 2), context: .userTyped)
        }
        let properties = analytics.pendingEvents.map { $0["properties"] as! [String: Any] }
        #expect(properties.compactMap { $0["interaction_origin"] as? String }
            == ["unknown", "unknown", "automatic", "onboarding", "user", "user", "user", "user"])
        #expect(properties.compactMap { $0["input_mode"] as? String }
            == ["unknown", "unknown", "none", "none", "none", "none", "typed", "typed"])
    }

    @Test func overlappingResponsesAndChildTasksKeepInitiatingContext() async throws {
        var requests: [URLRequest] = []
        let analytics = UsageAnalytics(defaults: defaults(), apiKey: "phc_test", send: { request in
            requests.append(request)
            return 200
        })
        analytics.setOptedIn(true)
        defer { analytics.setOptedIn(false) }
        let (voiceReady, ready) = AsyncStream<Void>.makeStream()
        let (voiceMayFinish, finish) = AsyncStream<Void>.makeStream()
        let voice = AnalyticsInteractionScope.task(context: .userVoice) {
            analytics.track(.userMessageSent(characterCount: 101))
            ready.yield(())
            ready.finish()
            for await _ in voiceMayFinish { break }
            analytics.track(.aiResponseReceived(characterCount: 102))
            let child = Task {
                analytics.track(.elementPointed(.init(coordinate: CGPoint(x: 11, y: 22), elementLabel: "private label")))
                analytics.track(.error(.init(category: .responsePipeline,
                    error: NSError(domain: "test.response", code: 17,
                                   userInfo: [NSLocalizedDescriptionKey: "private error text"]))))
            }
            await child.value
        }
        let typed = AnalyticsInteractionScope.task(context: .userTyped) {
            for await _ in voiceReady { break }
            analytics.track(.userMessageSent(characterCount: 201))
            analytics.track(.aiResponseReceived(characterCount: 202))
            finish.yield(())
            finish.finish()
        }
        await typed.value
        await voice.value
        #expect(AnalyticsInteractionScope.current == nil)
        for _ in 0..<100 where !analytics.pendingEvents.isEmpty { await Task.yield() }
        #expect(analytics.pendingEvents.isEmpty)
        let batches = try requests.map { try JSONSerialization.jsonObject(with: #require($0.httpBody)) as! [String: Any] }
        let events = batches.flatMap { $0["batch"] as! [[String: Any]] }
        #expect(events.count == 10)
        #expect(Set(events.compactMap { $0["distinct_id"] as? String }).count == 1)
        for event in events {
            let properties = event["properties"] as! [String: Any]
            let count = properties["character_count"] as? Int ?? 0
            let expectedMode = count >= 200 ? "typed" : "voice"
            #expect(properties["interaction_origin"] as? String == "user")
            #expect(properties["input_mode"] as? String == expectedMode)
        }
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: events), as: UTF8.self)
        #expect(!encoded.contains("private label"))
        #expect(!encoded.contains("private error text"))
    }

    @Test func revokingConsentClearsQueueAndReoptInCreatesFreshID() async throws {
        let preferences = defaults()
        var requests = 0
        let analytics = UsageAnalytics(defaults: preferences, apiKey: "phc_test", send: { _ in
            requests += 1
            try await Task.sleep(for: .seconds(60))
            return 200
        })
        analytics.setOptedIn(true)
        analytics.track(.userMessageSent(characterCount: 10))
        let firstID = try #require(preferences.string(forKey: UsageAnalytics.identityKey))
        analytics.setOptedIn(false)
        analytics.track(.aiResponseReceived(characterCount: 20))
        await Task.yield()
        #expect(analytics.pendingEvents.isEmpty)
        #expect(preferences.string(forKey: UsageAnalytics.identityKey) == nil)
        #expect(!preferences.bool(forKey: UsageAnalytics.consentKey))
        #expect(requests == 0)
        analytics.setOptedIn(true)
        analytics.track(.userMessageSent(characterCount: 2))
        #expect(preferences.string(forKey: UsageAnalytics.identityKey) != firstID)
        analytics.setOptedIn(false)
    }
    @Test func optOutCancelsInFlightTransportAndDropsBacklog() async {
        let preferences = defaults()
        var requests = 0
        var cancelled = false
        let analytics = UsageAnalytics(defaults: preferences, apiKey: "phc_test", send: { _ in
            requests += 1
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled = true; throw error }
            return 200
        })
        analytics.setOptedIn(true)
        analytics.track(.userMessageSent(characterCount: 10))
        for _ in 0..<100 where requests == 0 { await Task.yield() }
        #expect(requests == 1)
        analytics.track(.userMessageSent(characterCount: 20))
        analytics.setOptedIn(false)
        for _ in 0..<100 where !cancelled { await Task.yield() }
        #expect(cancelled)
        #expect(analytics.pendingEvents.isEmpty)
        #expect(preferences.string(forKey: UsageAnalytics.identityKey) == nil)
        #expect(requests == 1)
    }
}
