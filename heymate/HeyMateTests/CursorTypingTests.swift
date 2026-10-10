//
//  CursorTypingTests.swift
//  HeyMateTests
//

import CoreGraphics
import Testing
@testable import HeyMate

struct CursorTypingTests {

    @Test func aKeyHidesTheCursorAndAPointerMoveShowsIt() {
        #expect(CursorTypingPolicy.hides(forKeyDown: nil) == false)
        #expect(CursorTypingPolicy.hides(forKeyDown: "") == false)
        #expect(CursorTypingPolicy.hides(forKeyDown: "a"))
        #expect(CursorTypingPolicy.hides(forKeyDown: " "))
        let origin = CGPoint(x: 10, y: 10)
        #expect(CursorTypingPolicy.shouldReveal(from: origin, to: CGPoint(x: 14, y: 10)) == false)
        #expect(CursorTypingPolicy.shouldReveal(from: origin, to: CGPoint(x: 16, y: 10)))
    }
}
