//
//  CursorPointingMotionTests.swift
//  HeyMateTests
//
//  The settle, tap and inspect moves the cursor makes while parked beside
//  a target.
//

import CoreGraphics
import Testing
@testable import HeyMate

struct CursorPointingMotionTests {

    @Test func landingSquashesThenSettlesAtRest() {
        let motion = CursorPointingMotion(caption: "right here!")
        #expect(motion.pose(at: 0, isHeld: false, reduceMotion: false).scale == 1)
        #expect(motion.pose(at: 0.12, isHeld: false, reduceMotion: false).scale < 0.9)
        #expect(motion.pose(at: 0.245, isHeld: false, reduceMotion: false).scale > 1.03)
        #expect(motion.pose(at: 0.36, isHeld: false, reduceMotion: false) == .rest)
    }

    @Test func tapsOnlyWhenTheLineAsksForAClick() {
        #expect(CursorPointingMotion(caption: "Click Save").taps)
        #expect(CursorPointingMotion(caption: "then PRESS return").taps)
        #expect(CursorPointingMotion(caption: "tap the tab").taps)
        #expect(!CursorPointingMotion(caption: "this one!").taps)
        #expect(!CursorPointingMotion(caption: nil).taps)
    }

    @Test func tapPressesInAndSpreadsARing() {
        let motion = CursorPointingMotion(caption: "click this!")
        #expect(motion.pose(at: 1.1, isHeld: false, reduceMotion: false) == .rest)
        let pressed = motion.pose(at: 1.2 + 0.5 / 3, isHeld: false, reduceMotion: false)
        #expect(abs(pressed.lean - 5) < 0.001)
        #expect(abs(pressed.scale - 0.86) < 0.001)
        #expect(pressed.tapRingProgress != nil)
        #expect(motion.pose(at: 1.8, isHeld: false, reduceMotion: false) == .rest)

        let quiet = CursorPointingMotion(caption: "found it!")
        #expect(quiet.pose(at: 1.4, isHeld: false, reduceMotion: false) == .rest)
    }

    @Test func loopNudgesAndInspectsOnlyWhileHeld() {
        let motion = CursorPointingMotion(caption: "this one")
        let nudge = 1.7 + 2.35
        let inspect = 1.7 + 2.7
        #expect(motion.pose(at: nudge, isHeld: true, reduceMotion: false).lean > 2.9)
        #expect(motion.pose(at: inspect, isHeld: true, reduceMotion: false).headingOffsetDegrees != 0)
        #expect(motion.pose(at: nudge, isHeld: false, reduceMotion: false) == .rest)
        // Repeats every 3.4 s.
        #expect(motion.pose(at: nudge + 3.4, isHeld: true, reduceMotion: false).lean > 2.9)
        #expect(motion.pose(at: 1.7 + 1, isHeld: true, reduceMotion: false) == .rest)
    }

    @Test func reduceMotionHoldsStill() {
        let motion = CursorPointingMotion(caption: "click here")
        for elapsed in [0.1, 1.4, 4.0] {
            #expect(motion.pose(at: elapsed, isHeld: true, reduceMotion: true) == .rest)
        }
    }
}
