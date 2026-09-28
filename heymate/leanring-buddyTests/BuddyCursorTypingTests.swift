//
//  BuddyCursorTypingTests.swift
//  leanring-buddyTests
//

import CoreGraphics
import Testing
@testable import HeyMate

struct BuddyCursorTypingTests {

    @Test func aKeyHidesTheCursorAndAPointerMoveShowsIt() {
        #expect(BuddyCursorTypingPolicy.hides(forKeyDown: nil) == false)
        #expect(BuddyCursorTypingPolicy.hides(forKeyDown: "") == false)
        #expect(BuddyCursorTypingPolicy.hides(forKeyDown: "a"))
        #expect(BuddyCursorTypingPolicy.hides(forKeyDown: " "))
        let origin = CGPoint(x: 10, y: 10)
        #expect(BuddyCursorTypingPolicy.shouldReveal(from: origin, to: CGPoint(x: 14, y: 10)) == false)
        #expect(BuddyCursorTypingPolicy.shouldReveal(from: origin, to: CGPoint(x: 16, y: 10)))
    }
}
