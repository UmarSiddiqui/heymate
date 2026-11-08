//
//  PermissionWalkthroughTests.swift
//  HeyMateTests
//

import CoreGraphics
import SwiftUI
import Testing
@testable import HeyMate

@MainActor
struct PermissionWalkthroughTests {

    @Test func walksMicrophoneScreenRecordingAccessibilityWhenNothingIsOn() {
        let steps = PermissionWalkthroughPlan.steps(alreadyGranted: [], needsSpeechRecognition: false)
        #expect(steps == [.microphone, .screenRecording, .accessibility])
    }

    @Test func addsSpeechRecognitionAfterMicrophoneOnlyForApplesEngine() {
        let steps = PermissionWalkthroughPlan.steps(alreadyGranted: [], needsSpeechRecognition: true)
        #expect(steps == [.microphone, .speech, .screenRecording, .accessibility])
    }

    @Test func skipsPermissionsThatAreAlreadyOn() {
        let steps = PermissionWalkthroughPlan.steps(
            alreadyGranted: [.microphone, .screenRecording, .calendar],
            needsSpeechRecognition: false
        )
        #expect(steps == [.accessibility])
    }

    @Test func nothingToWalkWhenEverySetupPermissionIsOn() {
        let setup = HeyMatePermission.setupOrder(needsSpeechRecognition: false)
        #expect(PermissionWalkthroughPlan.steps(alreadyGranted: Set(setup), needsSpeechRecognition: false).isEmpty)
    }

    @Test func neverWalksFirstUsePermissions() {
        let steps = PermissionWalkthroughPlan.steps(alreadyGranted: [], needsSpeechRecognition: true)
        #expect(Set(steps).isDisjoint(with: HeyMatePermission.extras))
    }

    @Test func everyPermissionHasAPrivacyNote() {
        for permission in HeyMatePermission.allCases {
            #expect(!permission.privacyNote.isEmpty)
        }
    }

    @Test func helloStrokeStaysInsideItsFrame() {
        let rect = CGRect(x: 0, y: 0, width: 140, height: 100)
        let bounds = HeyMateHelloShape().path(in: rect).boundingRect
        #expect(!bounds.isEmpty)
        #expect(rect.insetBy(dx: -1, dy: -1).contains(bounds))
    }
}
