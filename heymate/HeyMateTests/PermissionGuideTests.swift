//
//  PermissionGuideTests.swift
//  HeyMateTests
//

import Foundation
import Testing
@testable import HeyMate

struct PermissionGuideTests {

    @Test func setupAsksMicrophoneThenScreenRecordingThenAccessibility() {
        #expect(HeyMatePermission.setupOrder(needsSpeechRecognition: false)
            == [.microphone, .screenRecording, .accessibility])
    }

    @Test func speechRecognitionJoinsSetupOnlyForApplesEngine() {
        #expect(HeyMatePermission.setupOrder(needsSpeechRecognition: true)
            == [.microphone, .speech, .screenRecording, .accessibility])
        #expect(!SpeechToTextProviders.needsSpeechRecognitionPermission(for: .onDevice))
        #expect(!SpeechToTextProviders.needsSpeechRecognitionPermission(for: .elevenLabs))
    }

    @Test func setupLeavesCalendarRemindersContactsAndNotificationsForFirstUse() {
        for needsSpeech in [false, true] {
            let setup = HeyMatePermission.setupOrder(needsSpeechRecognition: needsSpeech)
            #expect(Set(setup).isDisjoint(with: HeyMatePermission.extras))
        }
        #expect(Set(HeyMatePermission.extras) == [.notifications, .calendar, .reminders, .contacts])
    }

    @Test func allowAllAsksQuickPromptsBeforeSystemSettings() {
        let order = HeyMatePermission.allowAllOrder(includeExtras: false, needsSpeechRecognition: true)
        #expect(order == [.microphone, .speech, .screenRecording, .accessibility])
        let firstSettings = order.firstIndex { $0.isGrantedInSystemSettings } ?? order.count
        #expect(order.prefix(firstSettings).allSatisfy { !$0.isGrantedInSystemSettings })
        #expect(order.suffix(from: firstSettings).allSatisfy { $0.isGrantedInSystemSettings })
        #expect(HeyMatePermission.allowAllOrder(includeExtras: true, needsSpeechRecognition: true).count
            == HeyMatePermission.allCases.count)
        #expect(!HeyMatePermission.allowAllOrder(includeExtras: true, needsSpeechRecognition: false).contains(.speech))
    }

    @Test func inputMonitoringIsNeverAskedFor() {
        #expect(!HeyMatePermission.allCases.map(\.rawValue).contains("inputMonitoring"))
        #expect(HeyMatePermission.allCases.allSatisfy { $0.settingsAnchor != "Privacy_ListenEvent" })
        for permission in HeyMatePermission.allCases {
            #expect(!permission.purpose.contains("Input Monitoring"))
            #expect(!permission.onText.contains("Input Monitoring"))
            #expect(!permission.offText.contains("Input Monitoring"))
            #expect(!permission.privacyNote.contains("Input Monitoring"))
        }
    }

    @Test func everyPermissionSaysWhatItDoesBothWays() {
        for permission in HeyMatePermission.allCases {
            #expect(permission.onText.hasPrefix("HeyMate") || permission.onText.contains("HeyMate"))
            #expect(!permission.offText.isEmpty)
            #expect(permission.onText != permission.offText)
            #expect(!permission.purpose.isEmpty)
        }
    }

    @Test func onlyAccessibilityBreaksShortcuts() {
        let breaking = HeyMatePermission.allCases.filter(\.breaksShortcuts)
        #expect(breaking == [.accessibility])
        #expect(breaking.allSatisfy { $0.settingsHint?.contains($0.title) == true })
        #expect(HeyMatePermission.microphone.settingsHint == nil)
    }

    @Test func askingIsRememberedAcrossLaunches() throws {
        let suite = "heymate.permission-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!PermissionGuide.hasAsked(.accessibility, defaults: defaults))
        PermissionGuide.markAsked(.accessibility, defaults: defaults)
        #expect(PermissionGuide.hasAsked(.accessibility, defaults: defaults))
        #expect(!PermissionGuide.hasAsked(.screenRecording, defaults: defaults))
    }
}
