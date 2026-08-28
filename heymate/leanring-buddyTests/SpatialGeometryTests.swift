//
//  SpatialGeometryTests.swift
//  leanring-buddyTests
//
//  Tests for freehand-spatial-selection math: RDP simplification and
//  normalized polygon/bounds production (including degenerate gestures).
//

import CoreGraphics
import Testing
@testable import HeyMate

@MainActor
struct SpatialGeometryTests {

    // MARK: - Ramer–Douglas–Peucker

    @Test func straightLineCollapsesToEndpoints() {
        let denseLine = (0..<50).map { CGPoint(x: CGFloat($0), y: 10) }
        let simplified = SpatialGeometry.ramerDouglasPeucker(points: denseLine, epsilon: 2)

        #expect(simplified.count == 2)
        #expect(simplified.first == CGPoint(x: 0, y: 10))
        #expect(simplified.last == CGPoint(x: 49, y: 10))
    }

    @Test func cornerIsPreserved() {
        // An L-shape: many samples along two legs meeting at a right angle.
        var points = (0..<20).map { CGPoint(x: CGFloat($0), y: 0) }
        points += (1..<20).map { CGPoint(x: 19, y: CGFloat($0)) }

        let simplified = SpatialGeometry.ramerDouglasPeucker(points: points, epsilon: 2)
        #expect(simplified.count == 3)
        #expect(simplified.contains(CGPoint(x: 19, y: 0)))
    }

    @Test func tinyInputsPassThroughUnchanged() {
        let twoPoints = [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5)]
        #expect(SpatialGeometry.ramerDouglasPeucker(points: twoPoints, epsilon: 10) == twoPoints)
        #expect(SpatialGeometry.ramerDouglasPeucker(points: [], epsilon: 10) == [])
    }

    // MARK: - Normalization

    private let frameSize = CGSize(width: 1000, height: 800)

    @Test func rectangleGestureProducesNormalizedPolygonAndBounds() {
        // A small rectangle drawn in overlay-local coordinates.
        let gesture = [
            CGPoint(x: 100, y: 160),
            CGPoint(x: 300, y: 160),
            CGPoint(x: 300, y: 320),
            CGPoint(x: 100, y: 320),
            CGPoint(x: 100, y: 160),
        ]

        guard let selection = SpatialGeometry.normalize(
            polygonScreenLocal: gesture,
            frameSize: frameSize
        ) else {
            Issue.record("Expected a valid selection")
            return
        }

        // Polygon normalized against 1000×800.
        #expect(selection.polygon[0] == [0.1, 0.2])
        // Bounds: x=0.1, y=0.2, w=200/1000, h=160/800.
        #expect(selection.bounds == [0.1, 0.2, 0.2, 0.2])
    }

    @Test func outOfBoundsDragClampsIntoUnitSquare() {
        let wildGesture = [
            CGPoint(x: -50, y: -40),
            CGPoint(x: 1200, y: -40),
            CGPoint(x: 1200, y: 900),
            CGPoint(x: -50, y: 900),
            CGPoint(x: -50, y: -40),
        ]

        let selection = SpatialGeometry.normalize(
            polygonScreenLocal: wildGesture,
            frameSize: frameSize
        )

        #expect(selection != nil)
        for vertex in selection?.polygon ?? [] {
            #expect(vertex[0] >= 0 && vertex[0] <= 1)
            #expect(vertex[1] >= 0 && vertex[1] <= 1)
        }
    }

    @Test func degenerateGesturesAreRejected() {
        // Too few vertices.
        let tooFew = [
            CGPoint(x: 10, y: 10),
            CGPoint(x: 200, y: 210),
        ]
        #expect(SpatialGeometry.normalize(polygonScreenLocal: tooFew, frameSize: frameSize) == nil)

        // Zero-area click-ish drag (below the 8pt minimum on an axis).
        let flat = [
            CGPoint(x: 10, y: 100),
            CGPoint(x: 300, y: 100),
            CGPoint(x: 310, y: 101),
            CGPoint(x: 15, y: 102),
            CGPoint(x: 10, y: 100),
        ]
        #expect(SpatialGeometry.normalize(polygonScreenLocal: flat, frameSize: frameSize) == nil)
    }
}
