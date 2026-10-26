import Foundation
import Testing
@testable import HeyMate

struct NotchUsageTests {
    @Test func codexKeepsZeroAndBothWindows() throws {
        let data = Data(#"{"rate_limit":{"primary_window":{"used_percent":0,"reset_at":1900000000},"secondary_window":{"used_percent":72,"reset_at":1900500000}}}"#.utf8)
        let windows = try NotchUsageParser.parse(data, provider: .codex)
        #expect(windows.count == 2)
        #expect(windows[0].usedPercent == 0)
        #expect(windows[1].fraction == 0.72)
        #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1900000000))
    }
    @Test func missingFieldsDoNotTurnIntoZeroUsage() {
        for provider in NotchUsageProvider.allCases {
            #expect(throws: (any Error).self) { try NotchUsageParser.parse(Data("{}".utf8), provider: provider) }
        }
        #expect(throws: (any Error).self) {
            try NotchUsageParser.parse(Data(#"{"rate_limit":{"primary_window":{"used_percent":true}}}"#.utf8), provider: .codex)
        }
    }
    @Test func claudeSupportsFractionalResetTimesAndMissingWindow() throws {
        let windows = try NotchUsageParser.parse(Data(#"{"five_hour":{"utilization":23.5,"resets_at":"2030-01-01T12:00:00.000Z"},"seven_day":null}"#.utf8), provider: .claude)
        #expect(windows.count == 1)
        #expect(windows[0].usedPercent == 23.5)
        #expect(windows[0].resetsAt != nil)
    }
    @Test func cursorUsesAutoAndAPINotBlendedPercentage() throws {
        let windows = try NotchUsageParser.parse(Data(#"{"individualUsage":{"plan":{"autoPercentUsed":0,"apiPercentUsed":42,"totalPercentUsed":21}},"billingCycleEnd":"2030-01-01T12:00:00Z"}"#.utf8), provider: .cursor)
        #expect(windows.map(\.usedPercent) == [0, 42])
        #expect(windows[0].id == "auto")
    }
    @Test func cursorTeamLimitIsRatioAndOverageRingIsBounded() throws {
        let windows = try NotchUsageParser.parse(Data(#"{"individualUsage":{"overall":{"used":120,"limit":100}}}"#.utf8), provider: .cursor)
        #expect(windows[0].usedPercent == 120)
        #expect(windows[0].fraction == 1)
    }
    @Test func readingsBecomeStaleWhenOldOrResetPasses() {
        let now = Date(timeIntervalSince1970: 1800000000)
        let window = NotchUsageWindow(id: "test", title: "Test", usedPercent: 95, resetsAt: now.addingTimeInterval(60))
        let reading = NotchUsageReading(windows: [window], fetchedAt: now)
        #expect(!reading.isStale(at: now))
        #expect(reading.isStale(at: now.addingTimeInterval(61)))
        let old = NotchUsageReading(windows: [], fetchedAt: now.addingTimeInterval(-301))
        #expect(old.isStale(at: now))
    }
    @MainActor @Test func legacyMicroAppsNeverStartFromSavedPreferences() {
        let defaults = UserDefaults(suiteName: "notch-tests-\(UUID())")!
        defaults.set(NotchMicroApp.allCases.map(\.rawValue), forKey: NotchActivityCenter.enabledMicroAppsPreferenceKey)
        let center = NotchActivityCenter(userDefaults: defaults)
        #expect(center.enabledMicroApps == [.shelf])
        #expect(!center.shelfPresentation.isVisible)
        center.setEnabled(true, for: .clipboard)
        #expect(!center.isEnabled(.clipboard))
        #expect(center.clipboardStore.entries.isEmpty)
    }
    @MainActor @Test func customSourceReadsPercentOrUsedOverLimit() throws {
        NotchCustomProviderRegistry.set([
            NotchCustomProviderSpec(id: "custom.a", name: "Gateway", url: "https://example.com/u", percentPath: "data.pct", resetPath: "data.reset"),
            NotchCustomProviderSpec(id: "custom.b", name: "Proxy", url: "https://example.com/u", usedPath: "items.0.used", limitPath: "items.0.limit")
        ])
        let a = try NotchUsageParser.parse(Data(#"{"data":{"pct":"42.5","reset":1900000000000}}"#.utf8), provider: .init(rawValue: "custom.a"))
        #expect(a[0].usedPercent == 42.5)
        #expect(a[0].resetsAt == Date(timeIntervalSince1970: 1900000000))
        let b = try NotchUsageParser.parse(Data(#"{"items":[{"used":30,"limit":120}]}"#.utf8), provider: .init(rawValue: "custom.b"))
        #expect(b[0].usedPercent == 25)
        #expect(throws: (any Error).self) { try NotchUsageParser.parse(Data("{}".utf8), provider: .init(rawValue: "custom.a")) }
    }
    @Test func customSourceRefusesPlainHTTPOffLocalhost() {
        #expect(NotchCustomProviderSpec(id: "x", name: "n", url: "http://example.com/u", percentPath: "p").endpoint == nil)
        #expect(NotchCustomProviderSpec(id: "x", name: "n", url: "http://localhost:8080/u", percentPath: "p").endpoint != nil)
        #expect(NotchCustomProviderSpec(id: "x", name: "n", url: "https://u:p@example.com/", percentPath: "p").endpoint == nil)
    }
}
