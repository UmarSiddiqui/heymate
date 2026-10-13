//
//  PermissionWalkthroughTests.swift
//  HeyMateTests
//

import CoreGraphics
import Testing
@testable import HeyMate

@MainActor
struct PermissionWalkthroughTests {

    @Test func walksEveryCorePermissionWhenNothingIsOn() {
        let steps = PermissionWalkthroughPlan.steps(alreadyGranted: [])
        #expect(steps == HeyMatePermission.allowAllOrder(includeExtras: false))
    }

    @Test func skipsPermissionsThatAreAlreadyOn() {
        let steps = PermissionWalkthroughPlan.steps(alreadyGranted: [.microphone, .screenRecording, .calendar])
        #expect(!steps.contains(.microphone))
        #expect(!steps.contains(.screenRecording))
        #expect(steps.contains(.speech))
        #expect(steps.allSatisfy(HeyMatePermission.core.contains))
    }

    @Test func nothingToWalkWhenEveryCorePermissionIsOn() {
        #expect(PermissionWalkthroughPlan.steps(alreadyGranted: Set(HeyMatePermission.core)).isEmpty)
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
