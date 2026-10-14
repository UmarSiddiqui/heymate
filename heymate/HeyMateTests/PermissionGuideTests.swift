//
//  PermissionGuideTests.swift
//  HeyMateTests
//

import Foundation
import Testing
@testable import HeyMate

struct PermissionGuideTests {

    @Test func allowAllAsksQuickPromptsBeforeSystemSettings() {
        let order = HeyMatePermission.allowAllOrder(includeExtras: false)
        #expect(Set(order) == Set(HeyMatePermission.core))
        let firstSettings = order.firstIndex { $0.isGrantedInSystemSettings } ?? order.count
        #expect(order.prefix(firstSettings).allSatisfy { !$0.isGrantedInSystemSettings })
        #expect(order.suffix(from: firstSettings).allSatisfy { $0.isGrantedInSystemSettings })
        #expect(HeyMatePermission.allowAllOrder(includeExtras: true).count == HeyMatePermission.allCases.count)
    }

    @Test func everyPermissionSaysWhatItDoesBothWays() {
        for permission in HeyMatePermission.allCases {
            #expect(permission.onText.hasPrefix("HeyMate") || permission.onText.contains("HeyMate"))
            #expect(!permission.offText.isEmpty)
            #expect(permission.onText != permission.offText)
            #expect(!permission.purpose.isEmpty)
        }
    }

    @Test func onlyAccessibilityAndInputMonitoringBreakShortcuts() {
        let breaking = HeyMatePermission.allCases.filter(\.breaksShortcuts)
        #expect(Set(breaking) == [.accessibility, .inputMonitoring])
        #expect(breaking.allSatisfy { $0.settingsHint?.contains($0.title) == true })
        #expect(HeyMatePermission.microphone.settingsHint == nil)
    }

    @Test func askingIsRememberedAcrossLaunches() throws {
        let suite = "heymate.permission-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!PermissionGuide.hasAsked(.inputMonitoring, defaults: defaults))
        PermissionGuide.markAsked(.inputMonitoring, defaults: defaults)
        #expect(PermissionGuide.hasAsked(.inputMonitoring, defaults: defaults))
        #expect(!PermissionGuide.hasAsked(.screenRecording, defaults: defaults))
    }
}
