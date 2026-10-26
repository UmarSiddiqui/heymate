import AppKit
import SwiftUI
import Testing
@testable import HeyMate

@Suite(.serialized)
struct NotchCodenotchIntegrationTests {
    private func data(_ text: String) -> Data { Data(text.utf8) }
    private func fixture() -> NotchUsageReading {
        .init(windows: [.init(id: "session", title: "Session", usedPercent: 25, resetsAt: nil)], fetchedAt: Date())
    }
    @Test func allAdvertisedProvidersHaveRealReadersAndUniqueIDs() {
        let ids = NotchUsageProvider.allCases.map(\.rawValue)
        #expect(ids.count == 12)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("gemini"))
        #expect(ids.contains("antigravity"))
        #expect(!ids.contains("minimax")) // Unintegrated providers are not placeholders.
    }
    @Test func antigravityGroupedQuotasInvertRemainingAndKeepOrder() throws {
        let windows = CNAntigravityQuotaParser.parse(data(#"{"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"weekly","remainingFraction":0.25,"displayName":"Weekly Limit"},{"bucketId":"session","remaining":{"case":"remainingFraction","value":0.8},"displayName":"Five Hour Limit"}]}]}}"#), now: Date())
        let reading = try NotchCodenotchReader.reading(windows)
        #expect(reading.windows.map(\.id) == ["Gemini Models::session", "Gemini Models::weekly"])
        #expect(abs((reading.windows.first?.usedPercent ?? -1) - 20) < 0.001)
        #expect(reading.windows.last?.usedPercent == 75)
    }
    @Test func invalidAntigravityQuotaNeverBecomesZero() {
        #expect(CNAntigravityQuotaParser.parse(data(#"{"buckets":[{"modelId":"gemini-pro","remainingFraction":2}]}"#), now: Date()).isEmpty)
        #expect(throws: (any Error).self) { try NotchCodenotchReader.reading([]) }
    }
    @Test func countedMetricsNeverInventAnArc() throws {
        let reading = try NotchCodenotchReader.reading([.init(id: "requests", label: "Requests", used: 17)])
        #expect(reading.windows[0].usedPercent == nil)
        #expect(reading.windows[0].fraction == nil)
        #expect(reading.windows[0].headline() == "17 used")
        let count = NotchUsageWindow(id: "tokens", title: "Today", usedPercent: nil, resetsAt: nil, valueText: "42 tokens", fidelity: .derived)
        #expect(count.headline(remaining: true) == "~42 tokens")
    }
    @Test func cachedReadingRemainsBackwardCompatibleAndPrivate() throws {
        let old = data(#"{"windows":[{"id":"p","title":"Session","usedPercent":32}],"fetchedAt":1000}"#)
        let decoded = try JSONDecoder().decode(NotchUsageReading.self, from: old)
        #expect(decoded.windows[0].usedPercent == 32)
        #expect(decoded.windows[0].fidelity == nil)
        let runtime = NotchUsageReading(windows: decoded.windows, fetchedAt: Date(), runtimeDetails: ["private-model-name"])
        let text = String(decoding: try JSONEncoder().encode(runtime), as: UTF8.self)
        #expect(!text.contains("private-model-name"))
        #expect(!text.contains("runtimeDetails"))
    }
    @Test func percentagesKeepSubPercentReadingsAndRemainingMath() {
        let window = NotchUsageWindow(id: "p", title: "Session", usedPercent: 0.3, resetsAt: nil)
        #expect(window.headline() == "0.3%")
        #expect(window.headline(remaining: true) == "99.7%")
        #expect(CNUsageBand.band(for: 0.95) == .critical)
    }
    @MainActor @Test func oldSettingsMigrateWithoutEnablingNewProviders() throws {
        let suite = "cn-migrate-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["codex", "claude", "cursor"], forKey: "heymate.notch.usageProviders.v1")
        let store = NotchUsageStore(defaults: defaults)
        #expect(store.enabled == [.codex, .claude, .cursor])
        #expect(store.showsIdleUsage)
        #expect(!store.showsRemaining)
        #expect(!store.showsWeeklyRing)
        #expect(!store.reducesMotion)
        store.showsIdleUsage = false
        store.showsRemaining = true
        store.showsWeeklyRing = true
        store.reducesMotion = true
        store.setIdleVisible(false, provider: .codex)
        store.moveProvider(.cursor, offset: -1)
        let reloaded = NotchUsageStore(defaults: defaults)
        #expect(reloaded.enabled == store.enabled)
        #expect(reloaded.idleProviders.isEmpty)
        #expect(reloaded.displayedProviders.count == 3) // Intentional Usage access remains.
        #expect(reloaded.showsRemaining && reloaded.showsWeeklyRing && reloaded.reducesMotion)
        reloaded.showsIdleUsage = true
        #expect(!reloaded.idleProviders.contains(.codex))
        #expect(reloaded.providers[1] == .cursor)
    }
    @MainActor @Test func connectedCustomSourcesKeepTheirCacheAndOverviewPlace() throws {
        let suite = "cn-custom-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = NotchCustomProviderSpec(id: "custom.previous", name: "Existing gateway", url: "https://example.com/usage", percentPath: "percent")
        defaults.set(try JSONEncoder().encode([source]), forKey: "heymate.notch.customUsageProviders.v1")
        defaults.set(["codex", source.id], forKey: "heymate.notch.usageProviders.v1")
        defaults.set(try JSONEncoder().encode(fixture()), forKey: "heymate.notch.usage.\(source.id)")
        let store = NotchUsageStore(defaults: defaults)
        let custom = NotchUsageProvider(rawValue: source.id)
        #expect(store.enabled.contains(custom))
        #expect(store.readings[custom]?.windows.first?.usedPercent == 25)
        #expect(Array(store.overviewProviders.prefix(2)) == [.codex, custom])
        #expect(store.customProviders.first?.name == source.name)
    }
    @MainActor @Test func headlineAndWeeklyBlockingAreIndependentFromDisplayPreference() throws {
        let suite = "cn-headline-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["kimi", "codex"], forKey: "heymate.notch.usageProviders.v1")
        let reading = try NotchCodenotchReader.reading([
            .init(id: "weekly", label: "Weekly", usedFraction: 1),
            .init(id: "rolling", label: "5h", usedFraction: 0.2)
        ])
        defaults.set(try JSONEncoder().encode(reading), forKey: "heymate.notch.usage.kimi")
        let store = NotchUsageStore(defaults: defaults)
        #expect(store.headline(.kimi)?.usedPercent == 20)
        #expect(store.isBlocked(.kimi))
        #expect(store.weeklyWindow(.kimi) == nil)
        store.showsWeeklyRing = true
        #expect(store.weeklyWindow(.kimi)?.usedPercent == 100)
        store.ringOrder = .remaining
        // Unknown Codex must remain after a known-but-blocked quota.
        #expect(store.displayedProviders == [.kimi, .codex])
    }
    @Test func quotaGroupIDsStayUniqueAndCountsRejectOverflow() throws {
        let reading = try NotchCodenotchReader.reading([
            .init(id: "session", group: "Gemini", label: "Session", usedFraction: 0.2),
            .init(id: "session", group: "Claude", label: "Session", usedFraction: 0.4)
        ])
        #expect(Set(reading.windows.map(\.id)).count == 2)
        #expect(throws: (any Error).self) {
            try CNReadBudget.scan { CNCount.add(Int.max, 1) }
        }
    }
    @Test func quotaBooleansAndMissingNumeratorsAreUnavailable() {
        #expect(throws: (any Error).self) {
            try CNOpenCodeUsage.windows(fromJSON: #"{"usage":{"rolling":{"percent":true}}}"#)
        }
        #expect(throws: (any Error).self) {
            try CNGitHubCopilotUsage.windows(from: data(#"{"quota_snapshots":{"premium_interactions":{"entitlement":100}}}"#))
        }
    }
    @MainActor @Test func refreshTargetsOnlyRequestedProviderAndDisableDropsLateResult() async throws {
        let suite = "cn-refresh-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["codex", "gemini"], forKey: "heymate.notch.usageProviders.v1")
        let counter = FetchCounter()
        let reading = fixture()
        let store = NotchUsageStore(defaults: defaults, fetchReading: { provider, interactive, _ in
            await counter.add(provider, interactive: interactive)
            try await Task.sleep(for: .milliseconds(60))
            return reading
        })
        store.refresh(.gemini)
        await waitUntil { !store.refreshing.contains(.gemini) }
        let calls = await counter.calls
        #expect(calls == [.gemini])
        #expect(store.readings[.gemini] != nil)
        #expect(store.readings[.codex] == nil)
        store.refresh(.codex)
        store.setEnabled(false, provider: .codex)
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.readings[.codex] == nil)
        #expect(store.status[.codex] == nil)
        #expect(defaults.data(forKey: "heymate.notch.usage.codex") == nil)
        store.stop()
    }
    @MainActor @Test func persistedBackoffPreventsRequestsEvenOnExplicitRefresh() async {
        let suite = "cn-backoff-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["kimi"], forKey: "heymate.notch.usageProviders.v1")
        defaults.set(Date().addingTimeInterval(300).timeIntervalSince1970, forKey: "heymate.notch.usageRetry.kimi")
        let counter = FetchCounter(), reading = fixture()
        let store = NotchUsageStore(defaults: defaults, fetchReading: { provider, interactive, _ in
            await counter.add(provider, interactive: interactive); return reading
        })
        store.refresh(.kimi, interactive: true)
        #expect(await counter.calls.isEmpty)
        #expect(store.status[.kimi]?.contains("Rate limited") == true)
        store.stop()
    }
    @MainActor @Test func authFailureClearsCacheButTransientFailurePreservesIt() async throws {
        let suite = "cn-errors-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["kimi"], forKey: "heymate.notch.usageProviders.v1")
        defaults.set(try JSONEncoder().encode(fixture()), forKey: "heymate.notch.usage.kimi")
        let transient = NotchUsageStore(defaults: defaults, fetchReading: { _, _, _ in throw NotchUsageFailure.unavailable })
        transient.refresh(.kimi)
        await waitUntil { !transient.refreshing.contains(.kimi) }
        #expect(transient.readings[.kimi] != nil)
        let auth = NotchUsageStore(defaults: defaults, fetchReading: { _, _, _ in throw CNUsageProviderError.needsAuth })
        auth.refresh(.kimi)
        await waitUntil { !auth.refreshing.contains(.kimi) }
        #expect(auth.readings[.kimi] == nil)
        #expect(defaults.data(forKey: "heymate.notch.usage.kimi") == nil)
        transient.stop(); auth.stop()
    }
    @Test func retryAfterHonorsSecondsAndHTTPDates() {
        let url = URL(string: "https://api.kimi.com")!, now = Date(timeIntervalSince1970: 0)
        let seconds = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "600"])
        #expect(NotchCodenotchReader.retryAfter(seconds, now: now) == 600)
        let date = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "Thu, 01 Jan 1970 00:10:00 GMT"])
        #expect(NotchCodenotchReader.retryAfter(date, now: now) == 600)
    }
    @Test func antigravityDiscoveryRejectsUnrelatedLanguageServers() {
        let unrelated = "123 /Applications/Other.app/language_server --csrf_token secret"
        #expect(CNAntigravityBridge.discover(processTable: unrelated, listeningPorts: { _ in [9000] }) == nil)
        let own = "123 /Applications/Antigravity.app/Contents/Resources/language_server --csrf_token fixture"
        let endpoint = CNAntigravityBridge.discover(processTable: own, listeningPorts: { _ in [9000] })
        #expect(endpoint?.ports == [9000])
        #expect(endpoint?.csrfToken == "fixture")
    }
    @Test func antigravityWaitsExpireWithoutProcessEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-activity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("transcript.jsonl")
        try data(#"{"type":"USER_INPUT"}"#).write(to: transcript)
        #expect(CNAntigravityActivityMonitor.session(trajectory: transcript, modified: Date().addingTimeInterval(-300), staleAfter: 45, now: Date()) == nil)
    }
    @Test func scanBudgetRejectsOversizeAndNeverReturnsPartialTotals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-limit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.jsonl")
        try Data(repeating: 32, count: 8 * 1024 * 1024 + 1).write(to: file)
        #expect(throws: (any Error).self) {
            try CNReadBudget.scan { _ = try? CNReadBudget.data(file); return 0 }
        }
    }
    @Test func upstreamSpringSettlesAndHasSingleRestrainedOvershoot() {
        #expect(CNNotchMotion.progress(0, expanding: true) == 0)
        #expect(CNNotchMotion.progress(1, expanding: true) == 1)
        let values = (0...100).map { CNNotchMotion.progress(CGFloat($0) / 100, expanding: true) }
        #expect((values.max() ?? 0) > 1)
        #expect((values.max() ?? 0) < 1.06)
        #expect(CNNotchMotion.respectingReduceMotion(CNNotchMotion.unfold, true) == nil)
    }
    @Test func upstreamShapeCarriesItsGeometryThroughAnimation() {
        var shape = CNSideNotchShape(edge: .top, cornerRadius: 8, filletRadius: 0, filletDepth: 0)
        let target = CNSideNotchShape(edge: .top, cornerRadius: 24, filletRadius: 10, filletDepth: 10)
        shape.animatableData = target.animatableData
        #expect(shape.cornerRadius == 24 && shape.filletRadius == 10)
        let path = shape.path(in: CGRect(x: 0, y: 0, width: 600, height: 164))
        #expect(!path.isEmpty)
        #expect(path.boundingRect.width <= 600.01 && path.boundingRect.height <= 164.01)
    }
    @MainActor @Test func compactRingsAndFluidShapeRender() throws {
        let content = VStack(spacing: 18) {
            HStack(spacing: 18) {
                ForEach(Array(NotchUsageProvider.allCases.enumerated()), id: \.element.id) { index, provider in
                    VStack(spacing: 6) {
                        NotchUsageRing(provider: provider,
                            window: .init(id: "sample", title: "Session", usedPercent: index == 4 ? nil : Double(index * 8), resetsAt: nil,
                                          valueText: index == 4 ? "1200 tokens" : nil, fidelity: index == 4 ? .derived : nil),
                            size: 32, activity: CNActivitySummary(sessions: [.init(id: "sample", name: provider.name, detail: "Fixture", state: [.busy, .waiting, .success][index % 3], waitingFor: nil, since: Date())]), reducesMotion: true)
                        Text(provider.name).font(.system(size: 10)).foregroundStyle(.white)
                    }
                }
            }
            CNSideNotchShape(edge: .top, cornerRadius: 24, filletRadius: 10, filletDepth: 10)
                .fill(.white.opacity(0.15)).frame(width: 620, height: 70)
        }.padding(20).frame(width: 1000, height: 190).background(Color.black)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let cgImage = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 5000)
        try png.write(to: URL(fileURLWithPath: "/tmp/heymate-codenotch-core-preview.png"))
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

private actor FetchCounter {
    var calls: [NotchUsageProvider] = []
    var interactiveCalls: [Bool] = []
    func add(_ provider: NotchUsageProvider, interactive: Bool) { calls.append(provider); interactiveCalls.append(interactive) }
}
