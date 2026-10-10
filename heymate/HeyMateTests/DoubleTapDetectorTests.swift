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
        let fired1 = tap(&detector, at: 0)
        #expect(!fired1)
        let fired2 = tap(&detector, at: 0.3)
        #expect(fired2)
    }

    @Test func threeTapsAreOneDoubleTapPlusAStray() {
        var detector = DoubleTapDetector()
        let fired3 = tap(&detector, at: 0)
        #expect(!fired3)
        let fired4 = tap(&detector, at: 0.3)
        #expect(fired4)
        let fired5 = tap(&detector, at: 0.6)
        #expect(!fired5)
    }

    @Test func slowSecondTapStartsAFreshPair() {
        var detector = DoubleTapDetector()
        let fired6 = tap(&detector, at: 0)
        #expect(!fired6)
        let fired7 = tap(&detector, at: 1.0)
        #expect(!fired7)
        let fired8 = tap(&detector, at: 1.3)
        #expect(fired8)
    }

    @Test func aHoldIsNotATap() {
        var detector = DoubleTapDetector()
        let fired9 = tap(&detector, at: 0, holding: 0.8)
        #expect(!fired9)
        let fired10 = tap(&detector, at: 1.0)
        #expect(!fired10)
    }

    @Test func aChordInBetweenCancelsThePair() {
        var detector = DoubleTapDetector()
        let fired11 = tap(&detector, at: 0)
        #expect(!fired11)
        _ = detector.modifiersChanged(requiredSetHeld: true, at: 0.2)
        detector.keyPressed()  // ctrl+C
        let fired12 = detector.modifiersChanged(requiredSetHeld: false, at: 0.25)
        #expect(!fired12)
        let fired13 = tap(&detector, at: 0.4)
        #expect(!fired13)
        let fired14 = tap(&detector, at: 0.6)
        #expect(fired14)
    }

    @Test func repeatedHeldReportsAreIgnored() {
        var detector = DoubleTapDetector()
        _ = detector.modifiersChanged(requiredSetHeld: true, at: 0)
        _ = detector.modifiersChanged(requiredSetHeld: true, at: 0.05)
        let fired15 = detector.modifiersChanged(requiredSetHeld: false, at: 0.1)
        #expect(!fired15)
        let fired16 = tap(&detector, at: 0.3)
        #expect(fired16)
    }

    @Test func resetForgetsTheFirstTap() {
        var detector = DoubleTapDetector()
        let fired17 = tap(&detector, at: 0)
        #expect(!fired17)
        detector.reset()
        let fired18 = tap(&detector, at: 0.3)
        #expect(!fired18)
    }
}
