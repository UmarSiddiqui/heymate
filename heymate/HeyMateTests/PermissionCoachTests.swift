//
//  PermissionCoachTests.swift
//  HeyMateTests
//
//  The permission coach's moves, nudge schedule and switch finding.
//

import ApplicationServices
import CoreGraphics
import Testing
@testable import HeyMate

struct PermissionCoachTests {

    private func pose(_ phase: PermissionCoachCue.Phase, _ elapsed: Double) -> PermissionCoachMotion.Pose {
        PermissionCoachMotion.pose(phase, at: elapsed, reduceMotion: false)
    }

    @Test func guidingLandsAndTapsTheSwitch() {
        #expect(pose(.guiding, 0.12).pointing.scale < 0.9)
        let tap = pose(.guiding, 1.2 + 0.5 / 3)
        #expect(abs(tap.pointing.lean - 5) < 0.001)
        #expect(tap.pointing.tapRingProgress != nil)
        #expect(tap.offset == .zero)
    }

    @Test func slideDemoPressesSlidesRightAndComesBack() {
        let start = PermissionCoachMotion.loopStart
        let pressed = pose(.guiding, start + 0.15 * 1.4)
        #expect(abs(pressed.pointing.scale - 0.9) < 0.001)
        #expect(pressed.offset.dx < 0.5)

        let slid = pose(.guiding, start + 0.65 * 1.4)
        #expect(abs(slid.offset.dx - PermissionCoachMotion.dragDistance) < 0.001)
        #expect(slid.offset.dy == 0)

        let back = pose(.guiding, start + 1.4 - 0.001)
        #expect(back.offset.dx < 0.1)
        #expect(back.pointing.scale == 1)
    }

    @Test func waitingBobsSlowlyAndReplaysTheDemo() {
        let start = PermissionCoachMotion.loopStart
        let bobTop = pose(.guiding, start + 1.4 + 6.6 / 8)
        #expect(abs(bobTop.offset.dy + PermissionCoachMotion.bobAmplitude) < 0.001)
        #expect(bobTop.offset.dx == 0)
        // Stays within a couple of points the whole wait.
        for step in stride(from: 1.4, to: 8, by: 0.1) {
            let wait = pose(.guiding, start + step)
            #expect(abs(wait.offset.dy) <= PermissionCoachMotion.bobAmplitude + 0.001)
        }
        // The slide comes round again every loop.
        let again = pose(.guiding, start + 8 + 0.65 * 1.4)
        #expect(abs(again.offset.dx - PermissionCoachMotion.dragDistance) < 0.001)
    }

    @Test func successHopsWithARingThenRests() {
        let peak = pose(.success, 0.225)
        #expect(abs(peak.offset.dy + 10) < 0.001)
        #expect(peak.pointing.scale > 1)
        #expect(peak.successRingProgress != nil)
        #expect(pose(.success, 0.6).offset.dy < 0)
        #expect(pose(.success, 0.9).successRingProgress == nil)
        #expect(pose(.success, 1.05) == .rest)
    }

    @Test func recoveryWobblesThenTapsAgain() {
        #expect(pose(.recovery, 0.05).pointing.headingOffsetDegrees != 0)
        #expect(pose(.recovery, 0.05).offset == .zero)
        let tap = pose(.recovery, 0.7 + 0.5 / 3)
        #expect(abs(tap.pointing.lean - 5) < 0.001)
        #expect(tap.pointing.tapRingProgress != nil)
        #expect(pose(.recovery, 1.3) == .rest)
    }

    @Test func reduceMotionHoldsStillInEveryPhase() {
        for phase in [PermissionCoachCue.Phase.guiding, .success, .recovery] {
            for elapsed in [0.1, 0.25, 0.8, 1.4, 3, 6] {
                #expect(PermissionCoachMotion.pose(phase, at: elapsed, reduceMotion: true) == .rest)
            }
        }
    }

    @Test func nudgesAfterTwentySecondsThenEveryThirty() {
        #expect(!PermissionCoachTimeline.isRecoveryDue(waited: 19.9, nudgesShown: 0))
        #expect(PermissionCoachTimeline.isRecoveryDue(waited: 20, nudgesShown: 0))
        #expect(!PermissionCoachTimeline.isRecoveryDue(waited: 40, nudgesShown: 1))
        #expect(PermissionCoachTimeline.isRecoveryDue(waited: 50, nudgesShown: 1))
        #expect(PermissionCoachTimeline.giveUpAfter == 90)
    }

    @Test func captionsSayWhatToDoInEachPhase() {
        let guiding = PermissionCoachCue(permission: .accessibility, phase: .guiding, step: 1)
        #expect(guiding.caption.contains("HeyMate"))
        #expect(PermissionCoachCue(permission: .accessibility, phase: .success, step: 2).caption != guiding.caption)
        #expect(PermissionCoachCue(permission: .accessibility, phase: .recovery, step: 3).caption.contains("off and on"))
    }

    // MARK: Finding the switch

    private func element(_ role: String, _ label: String, _ frame: CGRect) -> AccessibleElement {
        AccessibleElement(role: role, label: label, title: nil, description: nil,
                          frame: frame, isEnabled: true, applicationName: "System Settings")
    }

    @Test func prefersHeyMatesOwnSwitch() {
        let row = element(kAXRowRole as String, "HeyMate", CGRect(x: 300, y: 400, width: 400, height: 28))
        let toggle = element(kAXCheckBoxRole as String, "HeyMate", CGRect(x: 660, y: 404, width: 26, height: 20))
        let other = element(kAXCheckBoxRole as String, "Terminal", CGRect(x: 660, y: 440, width: 26, height: 20))
        let window = CGRect(x: 200, y: 100, width: 700, height: 600)
        #expect(PermissionCoachAnchor.switchPoint(elements: [other, row, toggle], settingsWindow: window) == CGPoint(x: 673, y: 414))
        #expect(PermissionCoachAnchor.switchPoint(elements: [other, row], settingsWindow: window) == CGPoint(x: 672, y: 414))
    }

    @Test func fallsBackToTheSwitchColumnOfTheWindow() {
        let window = CGRect(x: 200, y: 100, width: 700, height: 600)
        #expect(PermissionCoachAnchor.switchPoint(elements: [], settingsWindow: window) == CGPoint(x: 856, y: 550))
        #expect(PermissionCoachAnchor.switchPoint(elements: [], settingsWindow: nil) == nil)
        let short = CGRect(x: 0, y: 0, width: 400, height: 220)
        #expect(PermissionCoachAnchor.estimatedSwitch(in: short) == CGPoint(x: 356, y: 110))
    }

    @Test func flipsWindowBoundsIntoAppKitSpace() {
        let bounds = CGRect(x: 100, y: 50, width: 700, height: 600)
        let frame = PermissionCoachAnchor.appKitFrame(fromWindowBounds: bounds, primaryDisplayHeight: 1000)
        #expect(frame == CGRect(x: 100, y: 350, width: 700, height: 600))
    }
}
