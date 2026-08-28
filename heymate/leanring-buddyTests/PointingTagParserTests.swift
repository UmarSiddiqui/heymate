//
//  PointingTagParserTests.swift
//  leanring-buddyTests
//

import CoreGraphics
import Foundation
import Testing
@testable import HeyMate

struct PointingTagParserTests {

    @Test func parsesPointTagAndStripsSpokenText() {
        let result = PointingTagParser.parse(
            "see the inspector up there. [POINT:1100,42:color inspector]"
        )
        #expect(result.spokenText == "see the inspector up there.")
        #expect(result.coordinate == CGPoint(x: 1100, y: 42))
        #expect(result.elementLabel == "color inspector")
        #expect(result.screenNumber == nil)
        #expect(result.visualGuidance == nil)
    }

    @Test func parsesPointNoneAndOtherScreen() {
        let none = PointingTagParser.parse("html is a markup language. [POINT:none]")
        #expect(none.spokenText == "html is a markup language.")
        #expect(none.coordinate == nil)
        #expect(none.elementLabel == "none")

        let other = PointingTagParser.parse(
            "that's on the other monitor. [POINT:400,300:terminal:screen2]"
        )
        #expect(other.screenNumber == 2)
        #expect(other.coordinate == CGPoint(x: 400, y: 300))
    }

    @Test func parsesNegativePointCoordinates() {
        // A model pointing at a half-offscreen element near the captured
        // image edge can emit a negative coordinate; the tag must still
        // parse (and be stripped from the spoken text) — downstream
        // ScreenCoordinateMath clamps it to the edge.
        let result = PointingTagParser.parse(
            "it's peeking off the left edge. [POINT:-24,310:close button]"
        )
        #expect(result.spokenText == "it's peeking off the left edge.")
        #expect(result.coordinate == CGPoint(x: -24, y: 310))
        #expect(result.elementLabel == "close button")
    }

    @Test func parsesRectangleAndScribbleTags() {
        let rectangle = PointingTagParser.parse(
            "that is the block to focus on. [RECT:10,20,300,140:error block:screen2]"
        )
        #expect(rectangle.spokenText == "that is the block to focus on.")
        #expect(rectangle.coordinate == nil)
        #expect(rectangle.elementLabel == "error block")
        #expect(rectangle.screenNumber == 2)
        #expect(rectangle.visualGuidance == .rectangle(CGRect(x: 10, y: 20, width: 300, height: 140)))

        let scribble = PointingTagParser.parse(
            "trace this path here. [SCRIBBLE:1,2; 30,40;50,60:flight path]"
        )
        #expect(scribble.spokenText == "trace this path here.")
        #expect(scribble.elementLabel == "flight path")
        #expect(scribble.visualGuidance == .scribble([
            CGPoint(x: 1, y: 2),
            CGPoint(x: 30, y: 40),
            CGPoint(x: 50, y: 60)
        ]))
    }

    @Test func stripTrailingFragmentDropsPartialVisualTags() {
        #expect(
            PointingTagParser.stripTrailingFragment("that area there. [RECT:10,20")
                == "that area there."
        )
        #expect(
            PointingTagParser.stripTrailingFragment("trace here. [SCRIBBLE:1,2;")
                == "trace here."
        )
        #expect(
            PointingTagParser.stripTrailingFragment("look there. [POINT:12")
                == "look there."
        )
        #expect(
            PointingTagParser.stripTrailingFragment("literal bracket [note")
                == "literal bracket [note"
        )
    }

    @Test func rectangleBecomesAHighlightVisualAction() {
        let parsed = PointingTagParser.parse("[RECT:100,50,200,100:box]")
        let actions = PointingTagParser.visualActions(
            from: parsed,
            screenshotPixelWidth: 1000,
            screenshotPixelHeight: 500
        )
        #expect(actions.count == 1)
        #expect(actions.first?.type == .highlight)
        #expect(actions.first?.rect == [0.1, 0.1, 0.2, 0.2])
        #expect(actions.first?.label == "box")
    }
}
