//
//  DoubleTapDetectorTests.swift
//  HeyMateTests
//
//  The timing rules behind the ctrl-ctrl and fn+ctrl double-tap shortcuts.
//

import Foundation
import Testing
@testable import HeyMate

struct DoubleTapDetectorTests {

    /// Presses and releases the modifier set, returning whether the release
    /// completed a double tap.
    private func tap(_ detector: inout DoubleTapDetector, at time: TimeInterval, holding: TimeInterval = 0.1) -> Bool {
        _ = detector.modifiersChanged(requiredSetHeld: true, at: time)
        return detector.modifiersChanged(requiredSetHeld: false, at: time + holding)
    }

    @Test func twoQuickTapsFireOnce() {
        var detector = DoubleTapDetector()
        #expect(!tap(&detector, at: 0))
        #expect(tap(&detector, at: 0.3))
    }

    @Test func threeTapsAreOneDoubleTapPlusAStray() {
        var detector = DoubleTapDetector()
        #expect(!tap(&detector, at: 0))
        #expect(tap(&detector, at: 0.3))
        #expect(!tap(&detector, at: 0.6))
    }

    @Test func slowSecondTapStartsAFreshPair() {
        var detector = DoubleTapDetector()
        #expect(!tap(&detector, at: 0))
        #expect(!tap(&detector, at: 1.0))
        #expect(tap(&detector, at: 1.3))
    }

    @Test func aHoldIsNotATap() {
        var detector = DoubleTapDetector()
        #expect(!tap(&detector, at: 0, holding: 0.8))
        #expect(!tap(&detector, at: 1.0))
    }

    @Test func aChordInBetweenCancelsThePair() {
        var detector = DoubleTapDetector()
        #expect(!tap(&detector, at: 0))
        _ = detector.modifiersChanged(requiredSetHeld: true, at: 0.2)
        detector.keyPressed()  // ctrl+C
        #expect(!detector.modifiersChanged(requiredSetHeld: false, at: 0.25))
        #expect(!tap(&detector, at: 0.4))
        #expect(tap(&detector, at: 0.6))
    }

    @Test func repeatedHeldReportsAreIgnored() {
        var detector = DoubleTapDetector()
        _ = detector.modifiersChanged(requiredSetHeld: true, at: 0)
        _ = detector.modifiersChanged(requiredSetHeld: true, at: 0.05)
        #expect(!detector.modifiersChanged(requiredSetHeld: false, at: 0.1))
        #expect(tap(&detector, at: 0.3))
    }

    @Test func resetForgetsTheFirstTap() {
        var detector = DoubleTapDetector()
        #expect(!tap(&detector, at: 0))
        detector.reset()
        #expect(!tap(&detector, at: 0.3))
    }
}
