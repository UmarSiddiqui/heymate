//
//  DrawingChoreographerTests.swift
//  HeyMateTests
//
//  Tests for the pen-cursor build layer: stroke geometry sampling, duration
//  clamping, the hand-stroke easing curve, and queue state at enqueue time.
//

import CoreGraphics
import Foundation
import Testing
@testable import HeyMate

@MainActor
struct DrawingChoreographerTests {

    private func makeAnnotation(
        kind: VisualAction.Kind,
        points: [CGPoint] = [],
        center: CGPoint = .zero,
        radius: CGSize = .zero,
        rect: CGRect = .zero
    ) -> ResolvedAnnotation {
        ResolvedAnnotation(
            id: UUID(),
            kind: kind,
            screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            points: points,
            center: center,
            radius: radius,
            rect: rect,
            label: nil,
            expiresAt: Date().addingTimeInterval(60)
        )
    }

    // MARK: - Stroke sampling

    @Test func polylineStrokeLengthMatchesPointDistances() {
        let annotation = makeAnnotation(
            kind: .polyline,
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 0), CGPoint(x: 300, y: 400)]
        )
        let stroke = DrawingStrokeSampler.stroke(for: annotation)

        #expect(stroke.role == .trace)
        // Wobble only moves interior samples sideways; total stays near 700.
        #expect(stroke.length > 600 && stroke.length < 800)
    }

    @Test func polygonStrokeReturnsToItsStart() {
        let annotation = makeAnnotation(
            kind: .polygon,
            points: [CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 10), CGPoint(x: 60, y: 110)]
        )
        let stroke = DrawingStrokeSampler.stroke(for: annotation)

        let first = stroke.points.first!, last = stroke.points.last!
        #expect(abs(first.x - last.x) < 0.001 && abs(first.y - last.y) < 0.001)
    }

    @Test func circleStrokeMatchesTheRenderedInkLoop() {
        let center = CGPoint(x: 200, y: 200)
        let radius = CGSize(width: 60, height: 40)
        let annotation = makeAnnotation(kind: .circle, center: center, radius: radius)
        let stroke = DrawingStrokeSampler.stroke(for: annotation)

        let expected = InkLoopShape.sampledPoints(
            center: center, radius: radius, seed: AnnotationCanvasView.seed(for: annotation.id))
        #expect(stroke.points == expected)
    }

    @Test func arrowStrokeReturnsThroughTheTip() {
        let tip = CGPoint(x: 100, y: 100)
        let annotation = makeAnnotation(kind: .arrow, points: [CGPoint(x: 0, y: 0), tip])
        let stroke = DrawingStrokeSampler.stroke(for: annotation)

        // Shaft ends at the tip; after hooking out to one barb the stroke
        // passes the tip again on its way to the other.
        let tipVisits = stroke.points.filter { abs($0.x - tip.x) < 0.001 && abs($0.y - tip.y) < 0.001 }
        #expect(tipVisits.count == 2)
    }

    @Test func pointAndCaptionBecomeTaps() {
        #expect(DrawingStrokeSampler.stroke(for: makeAnnotation(kind: .point, center: CGPoint(x: 5, y: 5))).role == .tap)
        #expect(DrawingStrokeSampler.stroke(for: makeAnnotation(kind: .caption, center: CGPoint(x: 5, y: 5))).role == .tap)
    }

    @Test func roundedRectPerimeterStaysOnTheRect() {
        let rect = CGRect(x: 10, y: 20, width: 200, height: 100)
        let points = DrawingStrokeSampler.roundedRectPerimeter(rect, cornerRadius: 8)

        #expect(points.count > 16)
        for point in points {
            #expect(point.x >= rect.minX - 0.01 && point.x <= rect.maxX + 0.01)
            #expect(point.y >= rect.minY - 0.01 && point.y <= rect.maxY + 0.01)
        }
    }

    // MARK: - Durations and sampling

    @Test func strokeDurationIsClamped() {
        let short = DrawingStroke(id: UUID(), role: .trace,
                                  points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)])
        #expect(short.duration == DrawingStroke.minimumSeconds)

        let long = DrawingStroke(id: UUID(), role: .trace,
                                 points: [CGPoint(x: 0, y: 0), CGPoint(x: 100_000, y: 0)])
        #expect(long.duration == DrawingStroke.maximumSeconds)
    }

    @Test func strokeSampleEndpointsMatchPathEndpoints() {
        let stroke = DrawingStroke(id: UUID(), role: .trace,
                                   points: [CGPoint(x: 3, y: 4), CGPoint(x: 300, y: 400)])
        #expect(stroke.sample(at: 0).position == stroke.points.first)
        #expect(stroke.sample(at: 1).position == stroke.points.last)
    }

    @Test func wobbleLeavesEndpointsExact() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 500, y: 0)]
        let sampled = WobbledPolylineShape.sampledPoints(points: points, close: false, seed: 1.23)

        #expect(sampled.first == points.first)
        #expect(sampled.last == points.last)
        #expect(sampled.count > 2)
    }

    // MARK: - Easing

    @Test func easeHitsEndpointsAndStaysMonotonic() {
        #expect(DrawingEase.value(at: 0) == 0)
        #expect(DrawingEase.value(at: 1) == 1)

        var previous = 0.0
        for step in 1...20 {
            let value = DrawingEase.value(at: Double(step) / 20)
            #expect(value >= previous)
            #expect(value >= 0 && value <= 1)
            previous = value
        }
    }

    // MARK: - Queue state

    @Test func enqueuePublishesZeroedProgressForEveryStroke() {
        let choreographer = DrawingChoreographer()
        let strokes = [
            DrawingStroke(id: UUID(), role: .trace, points: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100)]),
            DrawingStroke(id: UUID(), role: .tap, points: [CGPoint(x: 400, y: 400)]),
        ]

        choreographer.enqueue(strokes, from: CGPoint(x: 20, y: 20))

        #expect(choreographer.frame.isActive)
        #expect(choreographer.frame.progressByID[strokes[0].id] == 0)
        #expect(choreographer.frame.progressByID[strokes[1].id] == 0)

        choreographer.cancel()
        #expect(choreographer.frame.isActive == false)
        #expect(choreographer.frame.progressByID.isEmpty)
    }
}
