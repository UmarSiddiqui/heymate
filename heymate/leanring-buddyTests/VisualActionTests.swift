//
//  VisualActionTests.swift
//  leanring-buddyTests
//
//  Tests for the structured visual-action layer: JSON extraction from model
//  output, validation/clamping, screen routing, and normalized → overlay-local
//  conversion (including negative-origin displays).
//

import CoreGraphics
import Foundation
import Testing
@testable import HeyMate

@MainActor
struct VisualActionTests {

    // MARK: - Parser

    @Test func extractsFencedJSONBlockAndStripsItFromSpokenText() {
        let response = """
        click the export button in the top right.
        ```json
        {"visualActions":[{"type":"circle","center":[0.5,0.5],"radius":[0.04,0.03],"label":"export"}]}
        ```
        """
        let result = VisualActionParser.extract(from: response)

        #expect(result.spokenText == "click the export button in the top right.")
        #expect(result.actions.count == 1)
        #expect(result.actions.first?.type == .circle)
        #expect(result.actions.first?.label == "export")
    }

    @Test func extractsBareJSONBlockWithoutFences() {
        let response = #"here is the button. {"visualActions":[{"type":"arrow","points":[[0.1,0.1],[0.4,0.6]]}]}"#
        let result = VisualActionParser.extract(from: response)

        #expect(result.spokenText == "here is the button.")
        #expect(result.actions.count == 1)
        #expect(result.actions.first?.type == .arrow)
    }

    @Test func plainResponsesPassThroughUnchanged() {
        let response = "no visuals here, and definitely no {\"visualActions\"} key."
        let result = VisualActionParser.extract(from: response)

        #expect(result.spokenText == response)
        #expect(result.actions.isEmpty)
    }

    @Test func malformedActionsAreDroppedValidOnesKept() {
        let json = """
        {"visualActions":[
            {"type":"polygon","points":[[0.1,0.1],[0.2,0.1]]},
            {"type":"circle","center":[0.3,0.3],"radius":[0.05,0.05]},
            {"type":"highlight","rect":[0.1,0.1,0.0,0.2]}
        ]}
        """
        let actions = VisualActionParser.extract(from: json).actions

        // polygon needs ≥3 points; highlight needs non-zero width — both dropped.
        #expect(actions.count == 1)
        #expect(actions.first?.type == .circle)
    }

    @Test func outOfRangeCoordinatesClampIntoUnitSquare() {
        let json = """
        {"visualActions":[{"type":"point","x":1.7,"y":-0.4},{"type":"clear"}]}
        """
        let validated = VisualActionParser
            .extract(from: json)
            .actions
            .compactMap(VisualActionParser.validate)

        let point = validated[0]
        #expect(point.x == 1)
        #expect(point.y == 0)
    }

    // MARK: - Resolver

    private static let mainDisplay = VisualActionResolver.ScreenGeometryInfo(
        id: "screen1",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        isCursorScreen: true
    )

    /// Display to the LEFT of the main display (negative origin).
    private static let leftDisplay = VisualActionResolver.ScreenGeometryInfo(
        id: "screen2",
        frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        isCursorScreen: false
    )

    @Test func normalizedPointsConvertToOverlayLocalCoordinates() {
        let action = VisualAction(
            type: .point, screenId: nil, x: 0.25, y: 0.75,
            points: nil, center: nil, radius: nil, rect: nil, label: nil, ttlMs: nil
        )

        let resolved = VisualActionResolver.resolve([action], screens: [Self.mainDisplay])
        #expect(resolved.count == 1)

        let annotation = resolved[0]
        #expect(annotation.center.x == 0.25 * 1512)
        #expect(annotation.center.y == 0.75 * 982)
        // Nil screenId routes to the cursor screen.
        #expect(annotation.screenFrame == Self.mainDisplay.frame)
    }

    @Test func explicitScreenIdRoutesToCorrectDisplay() {
        let action = VisualAction(
            type: .roundedRect, screenId: "screen2", x: nil, y: nil,
            points: nil, center: nil, radius: nil, rect: [0.1, 0.2, 0.3, 0.4], label: nil, ttlMs: nil
        )

        let resolved = VisualActionResolver.resolve([action], screens: [Self.mainDisplay, Self.leftDisplay])

        #expect(resolved[0].screenFrame == Self.leftDisplay.frame)
        #expect(resolved[0].rect.origin.x == 0.1 * 1920)   // local coords are display-relative
        #expect(resolved[0].rect.origin.y == 0.2 * 1080)
        #expect(resolved[0].rect.width == 0.3 * 1920)
        #expect(resolved[0].rect.height == 0.4 * 1080)
    }

    @Test func unknownScreenIdFallsBackToCursorScreen() {
        let action = VisualAction(
            type: .point, screenId: "screen99", x: 0.5, y: 0.5,
            points: nil, center: nil, radius: nil, rect: nil, label: nil, ttlMs: nil
        )

        let resolved = VisualActionResolver.resolve([action], screens: [Self.mainDisplay, Self.leftDisplay])
        #expect(resolved.count == 1)
        #expect(resolved[0].screenFrame == Self.mainDisplay.frame)
    }

    @Test func clearRemovesPriorAnnotationsInApplyOrder() {
        let circle = VisualAction(
            type: .circle, screenId: nil, x: nil, y: nil,
            points: nil, center: [0.5, 0.5], radius: [0.05, 0.05], rect: nil, label: nil, ttlMs: nil
        )
        let clear = VisualAction(
            type: .clear, screenId: nil, x: nil, y: nil,
            points: nil, center: nil, radius: nil, rect: nil, label: nil, ttlMs: nil
        )
        let arrow = VisualAction(
            type: .arrow, screenId: nil, x: nil, y: nil,
            points: [[0.1, 0.1], [0.9, 0.9]], center: nil, radius: nil, rect: nil, label: nil, ttlMs: nil
        )

        var annotations = VisualActionResolver.apply([circle], to: [], screens: [Self.mainDisplay])
        #expect(annotations.count == 1)

        annotations = VisualActionResolver.apply([clear, arrow], to: annotations, screens: [Self.mainDisplay])
        #expect(annotations.count == 1)
        #expect(annotations[0].kind == .arrow)
    }

    @Test func ttlRespectedPerActionWithFloor() {
        let fastAction = VisualAction(
            type: .point, screenId: nil, x: 0.5, y: 0.5,
            points: nil, center: nil, radius: nil, rect: nil, label: nil, ttlMs: 1500
        )
        let now = Date(timeIntervalSinceReferenceDate: 100_000)

        let resolved = VisualActionResolver.resolve(
            [fastAction],
            screens: [Self.mainDisplay],
            now: now
        )

        // 1500 ms TTL honored exactly when above the 1s floor.
        #expect(resolved[0].expiresAt.timeIntervalSince(now) == 1.5)
    }
}
