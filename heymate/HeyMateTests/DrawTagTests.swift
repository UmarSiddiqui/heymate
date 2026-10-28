//
//  DrawTagTests.swift
//  HeyMateTests
//
//  Circles, arrows and cards a reply draws while it talks, and the json
//  drawing block that used to be stripped without ever being drawn.
//

import CoreGraphics
import Foundation
import Testing
@testable import HeyMate

struct DrawTagTests {

    @Test func circleAndArrowTagsBecomeNormalizedDrawings() {
        let circle = PointingTagParser.parse("this is the intake. [CIRCLE:500,250,50:intake:screen2]")
        #expect(circle.spokenText == "this is the intake.")
        #expect(circle.screenNumber == 2)
        #expect(circle.visualGuidance == .circle(center: CGPoint(x: 500, y: 250), radius: 50))
        let circleActions = PointingTagParser.visualActions(from: circle, screenshotPixelWidth: 1000, screenshotPixelHeight: 500)
        #expect(circleActions.first?.type == .circle)
        #expect(circleActions.first?.center == [0.5, 0.5])
        #expect(circleActions.first?.radius == [0.05, 0.1])

        let arrow = PointingTagParser.parse("air flows this way. [ARROW:100,100,900,400:air]")
        #expect(arrow.visualGuidance == .arrow(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 900, y: 400)))
        let arrowActions = PointingTagParser.visualActions(from: arrow, screenshotPixelWidth: 1000, screenshotPixelHeight: 500)
        #expect(arrowActions.first?.type == .arrow)
        #expect(arrowActions.first?.points == [[0.1, 0.2], [0.9, 0.8]])
    }

    @Test func cardTagReadsTitleLinesAndPhotoAndDrawsNothingOnTheOverlay() throws {
        let result = PointingTagParser.parse(
            "wrought iron, riveted. [CARD:Eiffel Tower | wrought iron: 7,300 t | | 2.5 million rivets | photo: eiffel tower]"
        )
        #expect(result.spokenText == "wrought iron, riveted.")
        guard case .card(let card)? = result.visualGuidance else {
            Issue.record("expected a card")
            return
        }
        #expect(card.title == "Eiffel Tower")
        #expect(card.lines == ["wrought iron: 7,300 t", "2.5 million rivets"])
        #expect(card.photoSubject == "eiffel tower")
        #expect(PointingTagParser.visualActions(from: result, screenshotPixelWidth: 100, screenshotPixelHeight: 100).isEmpty)
    }

    @Test func cardsKeepFiveLinesAndNeedATitle() {
        let card = DrawCard(tagBody: "Steps|1|2|3|4|5|6|7")
        #expect(card?.lines == ["1", "2", "3", "4", "5"])
        #expect(card?.photoSubject == nil)
        #expect(DrawCard(tagBody: " | photo:cat") == nil)
    }

    @Test func eachDrawingIsItsOwnStepSoItDrawsWithItsSentence() {
        let reply = GuidedReplyParser.parse(
            "this is the piston. [CIRCLE:400,300,40:piston] it pushes the crank. [ARROW:400,340,400,500:crank] here's the gist. [CARD:Four-stroke|intake|compression|power|exhaust]"
        )
        #expect(reply.steps.map(\.displayText) == ["this is the piston.", "it pushes the crank.", "here's the gist."])
        #expect(reply.pointingStepCount == 3)
        #expect(reply.spokenText.contains("[") == false)
    }

    @Test func halfArrivedDrawTagsAreNeverShownOrSpoken() {
        #expect(GuidedReplyParser.streamingDisplayText("this part. [CIRC") == "this part.")
        #expect(GuidedReplyParser.streamingDisplayText("the gist. [CARD:Four-stroke|int") == "the gist.")
        #expect(PointingTagParser.stripTrailingFragment("look. [ARROW:1,2") == "look.")
    }

    @Test func jsonDrawingBlockIsLiftedOutOfTheSpokenReply() {
        let reply = GuidedReplyParser.parse(
            "the error is on this line.\n```json\n{\"visualActions\": [{\"type\": \"highlight\", \"rect\": [0.1, 0.2, 0.5, 0.05]}]}\n```"
        )
        #expect(reply.spokenText == "the error is on this line.")
        #expect(reply.visualActions.map(\.type) == [.highlight])
    }

    @Test func wikipediaThumbnailIsReadFromThePageimagesResponse() throws {
        let body = #"{"batchcomplete":true,"query":{"pages":[{"pageid":9232,"title":"Eiffel Tower","thumbnail":{"source":"https://upload.wikimedia.org/eiffel.jpg","width":640,"height":900}}]}}"#
        #expect(DrawCardPhotoLookup.thumbnailURL(fromResponse: Data(body.utf8))?.absoluteString == "https://upload.wikimedia.org/eiffel.jpg")
        #expect(DrawCardPhotoLookup.thumbnailURL(fromResponse: Data(#"{"batchcomplete":true}"#.utf8)) == nil)
        let url = try #require(DrawCardPhotoLookup.searchURL(for: "eiffel tower"))
        #expect(url.host == "en.wikipedia.org")
        #expect(url.query?.contains("gsrsearch=eiffel%20tower") == true)
    }
}
