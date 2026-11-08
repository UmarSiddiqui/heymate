import Foundation

@main struct DiagnosticsProbe {
    @MainActor static func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(condition(), "Diagnostics worker did not settle")
    }

    @MainActor static func main() async throws {
        let suite = "heymate-diagnostics-probe-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let destination = URL(string: CommandLine.arguments[2])!
        let secret = "PRIVATE_prompt_reply_audio_clipboard_account_token_https://private.example/Users/Private"
        precondition(DiagnosticsSchema.version("1.2.3\n") == "unknown")
        precondition(DiagnosticsSchema.version("1.2.3") == "1.2.3")
        var requests: [URLRequest] = []
        let send: (URLRequest) async throws -> Int = { request in
            requests.append(request)
            var local = request
            local.url = destination
            let (_, response) = try await URLSession.shared.data(for: local)
            return (response as! HTTPURLResponse).statusCode
        }
        let product = UsageAnalytics(defaults: defaults, apiKey: "phc_synthetic", version: secret,
                                     privacyReviewed: true, send: send)
        let crash = UsageAnalytics(defaults: defaults, category: .crash, apiKey: "phc_synthetic",
                                   privacyReviewed: true, send: send)
        let report: [String: Any] = [
            "exception": ["type": "EXC_BAD_ACCESS", "message": secret, "stack": secret],
            "bundleInfo": ["CFBundleShortVersionString": secret, "CFBundleIdentifier": "com.heymate.app"],
            "prompts": secret, "reply": secret, "path": secret, "url": secret,
            "sdk_metadata": ["email": secret, "token": secret, "breadcrumbs": [secret]]
        ]
        product.configure(); crash.configure()
        product.track(.diagnostic(feature: .setup, outcome: .completed))
        crash.track(.crash(CrashDiagnosticSummary(envelope: report)))
        crash.collectCrashReports(directory: root)
        try await Task.sleep(for: .milliseconds(20))
        precondition(requests.isEmpty && product.pendingEvents.isEmpty && crash.pendingEvents.isEmpty)
        precondition(defaults.string(forKey: UsageAnalytics.identityKey) == nil)
        _ = try product.previewData(); _ = try crash.previewData()
        precondition(defaults.string(forKey: UsageAnalytics.identityKey) == nil)
        print("PASS default-off: no network, queue or identity; preview stays local")

        for (key, host, reviewed) in [("", "https://us.i.posthog.com", true),
                                     ("phc_synthetic", "https://private.example", true),
                                     ("phc_synthetic", "https://us.i.posthog.com", false)] {
            let inert = UsageAnalytics(defaults: defaults, apiKey: key, host: host,
                                       privacyReviewed: reviewed, send: send)
            inert.setOptedIn(true)
            inert.track(.diagnostic(feature: .setup, outcome: .completed))
            precondition(!inert.isAvailable && inert.pendingEvents.isEmpty)
            inert.setOptedIn(false)
        }
        precondition(requests.isEmpty)
        print("PASS missing destination, unsafe host and missing review stay inert")

        product.setOptedIn(true)
        precondition(!crash.isOptedIn)
        // Legacy broad tracking cannot leak a dynamic property into schema v2.
        product.track(.onboardingStepViewed(step: secret))
        product.track(.permissionGranted(secret))
        product.track(.appOpened(version: secret))
        product.track(.error(AnalyticsErrorSummary(category: .responsePipeline,
            error: NSError(domain: secret, code: 500, userInfo: [NSLocalizedDescriptionKey: secret]))))
        precondition(product.pendingEvents.isEmpty)
        defaults.set(secret, forKey: UsageAnalytics.identityKey)
        product.track(.diagnostic(feature: .setup, outcome: .failed, provider: .codex,
                                  failure: .provider, count: Int.max, durationMilliseconds: -10))
        try await settle { requests.count == 1 && product.pendingEvents.isEmpty }
        let productID = defaults.string(forKey: UsageAnalytics.identityKey)!
        precondition(UUID(uuidString: productID) != nil)
        crash.setOptedIn(true)
        crash.track(.crash(CrashDiagnosticSummary(envelope: report)))
        try await settle { requests.count == 2 && crash.pendingEvents.isEmpty }
        precondition(defaults.string(forKey: "heymate.crashes.installID.v1") != productID)
        let reopened = UsageAnalytics(defaults: defaults, apiKey: "phc_synthetic", privacyReviewed: true)
        let reopenedCrash = UsageAnalytics(defaults: defaults, category: .crash, apiKey: "phc_synthetic", privacyReviewed: true)
        precondition(reopened.isOptedIn && reopenedCrash.isOptedIn)
        product.setOptedIn(false)
        precondition(crash.isOptedIn)
        let preview = try crash.previewData()
        try preview.write(to: root.appendingPathComponent("sanitized-preview.json"))
        for data in requests.compactMap(\.httpBody) + [preview] {
            let text = String(decoding: data, as: UTF8.self)
            precondition(!text.contains("PRIVATE") && !text.contains("private.example") && !text.contains("/Users/"))
        }
        print("PASS independent persisted consent/IDs, allowlisted schema, hostile metadata redaction and export")

        // Real transport to a local-only collector already received both synthetic
        // envelopes above. Nothing in this probe contacts an ingestion service.
        precondition(requests.count == 2)
        print("PASS synthetic product and crash summaries reached development collector after consent")

        crash.setOptedIn(false)
        var currentTime = Date(timeIntervalSince1970: 1_800_000_000)
        var captured = 0
        let collection = UsageAnalytics(defaults: defaults, category: .crash, apiKey: "phc_synthetic",
            privacyReviewed: true, now: { currentTime }, send: { _ in captured += 1; return 200 })
        collection.setOptedIn(true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
        func writeReport(_ name: String, offset: TimeInterval, bundle: String = "com.heymate.app") throws {
            var value = report
            value["captureTime"] = formatter.string(from: currentTime.addingTimeInterval(offset))
            value["bundleInfo"] = ["CFBundleIdentifier": bundle, "CFBundleShortVersionString": "1.2.3"]
            var bytes = Data("{\"sdk_metadata\":\"PRIVATE\"}\n".utf8)
            bytes.append(try JSONSerialization.data(withJSONObject: value))
            try bytes.write(to: root.appendingPathComponent(name))
        }
        try writeReport("HeyMate-old.ips", offset: -1)
        try writeReport("HeyMate-new.ips", offset: 1)
        try writeReport("HeyMate-other.ips", offset: 1, bundle: "com.other.app")
        try writeReport("HeyMateSpeechRunner-new.ips", offset: 1)
        currentTime = currentTime.addingTimeInterval(2)
        collection.collectCrashReports(directory: root)
        try await settle { captured == 1 && collection.pendingEvents.isEmpty }
        collection.collectCrashReports(directory: root)
        try await Task.sleep(for: .milliseconds(20))
        precondition(captured == 1)
        collection.setOptedIn(false)
        collection.setOptedIn(true)
        collection.collectCrashReports(directory: root)
        try await Task.sleep(for: .milliseconds(20))
        precondition(captured == 1)
        collection.setOptedIn(false)
        print("PASS crash collection: own new reports only, no historical replay or duplicate sends")

        var started = false
        var cancelled = false
        let slow = UsageAnalytics(defaults: defaults, apiKey: "phc_synthetic", privacyReviewed: true, send: { _ in
            started = true
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled = true; throw error }
            return 200
        })
        slow.setOptedIn(true)
        slow.track(.diagnostic(feature: .mate, outcome: .reused))
        try await settle { started }
        slow.track(.diagnostic(feature: .lesson, outcome: .ended))
        slow.setOptedIn(false)
        try await settle { cancelled }
        precondition(slow.pendingEvents.isEmpty && defaults.string(forKey: UsageAnalytics.identityKey) == nil)
        let before = requests.count
        slow.track(.diagnostic(feature: .setup, outcome: .completed))
        try await Task.sleep(for: .milliseconds(20))
        precondition(requests.count == before)
        print("PASS opt-out: in-flight cancellation, backlog/ID removal, no future sends")
    }
}
