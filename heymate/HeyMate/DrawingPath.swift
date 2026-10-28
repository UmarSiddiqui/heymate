//
//  DrawingPath.swift
//  HeyMate
//
//  Path builders for hand-drawn marks: tapered strokes, Catmull-Rom splines,
//  and dashed polylines. HeyMate's own Swift implementation — modelled on the
//  capabilities ReferenceRenderer's drawing engine exposes (tapered pen strokes,
//  smooth spline curves, dash patterns) but not copied from ReferenceRenderer's code.
//

import CoreGraphics
import SwiftUI

/// Builds a stroked path with optional taper at both ends. The stroke is
/// rendered as a filled polygon so the width can vary along its length.
/// `widthAt` returns the stroke width (in points) at a fraction 0…1 along the
/// path; `.pen` tapers to near-zero at both ends, other brushes stay even.
struct TaperedStrokeBuilder {
    /// Samples of the centre line.
    let points: [CGPoint]
    /// Width as a fraction of the brush's full width at each sample (0…1).
    let widths: [CGFloat]
    /// Whether to draw a rounded cap at each end.
    let roundCaps: Bool

    init(points: [CGPoint], brush: DrawingBrush, roundCaps: Bool = true) {
        self.points = points
        self.roundCaps = roundCaps

        // Build per-sample width fractions: taper at both ends for tapering
        // brushes, even otherwise.
        switch brush {
        case .pen, .pencil:
            let taper = 0.18 // fraction of full width at the very tip
            var w: [CGFloat] = []
            let n = points.count
            for i in 0..<n {
                let f = CGFloat(i) / CGFloat(max(n - 1, 1))
                // Ease-in / ease-out taper: slow at the very ends, fast in middle.
                let ease = sin(f * .pi)
                w.append(max(taper, ease))
            }
            self.widths = w
        default:
            self.widths = [CGFloat](repeating: 1.0, count: points.count)
        }
    }

    /// Builds a filled Path representing the stroked line with varying width.
    func path(brushWidth: CGFloat) -> Path {
        guard points.count >= 2 else { return Path() }
        var path = Path()
        var distances: [CGFloat] = [0]
        for (a, b) in zip(points, points.dropFirst()) {
            distances.append(distances.last! + hypot(b.x - a.x, b.y - a.y))
        }
        // matches ReferenceRenderer mate-draw-engine.js / mate-draw-pieces.js parameter outline swell 0.94 + 0.06 * sin(u / 7).
        let modulatedWidths = widths.enumerated().map { index, width in
            let u = distances[index] / max(distances.last!, 0.001)
            return width * (0.94 + 0.06 * sin(u / 7))
        }

        // Compute perpendicular offsets for each sample point.
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for (index, point) in points.enumerated() {
            let halfWidth = brushWidth * modulatedWidths[index] / 2
            var normal: CGPoint
            if index == 0 {
                normal = Self.perpendicular(from: points[0], to: points[1])
            } else if index == points.count - 1 {
                normal = Self.perpendicular(from: points[index - 1], to: points[index])
            } else {
                // Average normals of adjacent segments for a smoother mitre.
                let n1 = Self.perpendicular(from: points[index - 1], to: points[index])
                let n2 = Self.perpendicular(from: points[index], to: points[index + 1])
                normal = CGPoint(x: (n1.x + n2.x) / 2, y: (n1.y + n2.y) / 2)
                let len = hypot(normal.x, normal.y)
                if len > 0 { normal.x /= len; normal.y /= len }
            }
            left.append(CGPoint(x: point.x + normal.x * halfWidth,
                                y: point.y + normal.y * halfWidth))
            right.append(CGPoint(x: point.x - normal.x * halfWidth,
                                 y: point.y - normal.y * halfWidth))
        }

        // Draw the filled strip: left edge forward, right edge back.
        path.move(to: left[0])
        for i in 1..<left.count { path.addLine(to: left[i]) }
        for i in (0..<right.count).reversed() { path.addLine(to: right[i]) }
        path.closeSubpath()
        if roundCaps {
            for (point, width) in [(points.first!, modulatedWidths.first!), (points.last!, modulatedWidths.last!)] {
                let radius = brushWidth * width / 2
                path.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            }
        }
        path.closeSubpath()
        return path
    }

    private static func perpendicular(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0 else { return CGPoint(x: 0, y: -1) }
        return CGPoint(x: -dy / len, y: dx / len)
    }
}

/// Catmull-Rom spline through a series of points. Returns resampled points
/// at uniform spacing so the resulting curve is smooth and even.
struct CatmullRomSpline {
    /// Control points the curve passes through.
    let points: [CGPoint]
    /// Whether the curve is closed.
    let closed: Bool
    /// Tension: 0.5 = centripetal (standard Catmull-Rom), 0 = uniform, 1 = chordal.
    let tension: CGFloat

    init(points: [CGPoint], closed: Bool = false, tension: CGFloat = 0.5) {
        self.points = points
        self.closed = closed
        self.tension = tension
    }

    /// Resampled points along the spline, approximately `spacing` points apart.
    func sampled(spacing: CGFloat = 4) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        var result: [CGPoint] = []

        let count = closed ? points.count : points.count - 1
        for i in 0..<count {
            let p0 = points[closed ? (i - 1 + points.count) % points.count : max(0, i - 1)]
            let p1 = points[i % points.count]
            let p2 = points[(i + 1) % points.count]
            let p3 = points[closed ? (i + 2) % points.count : min(points.count - 1, i + 2)]

            let segmentLength = hypot(p2.x - p1.x, p2.y - p1.y)
            let steps = max(1, Int((segmentLength / spacing).rounded(.up)))
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                result.append(catmullRom(t: t, p0: p0, p1: p1, p2: p2, p3: p3))
            }
        }
        if !closed, let last = points.last {
            result.append(last)
        }
        return result
    }

    private func catmullRom(t: CGFloat, p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint) -> CGPoint {
        let tt = t * t
        let ttt = tt * t

        // Centripetal parameterization would adjust t per segment; here t is
        // local 0…1 within the segment, tension controls the curve tightness.
        let x = 0.5 * (
            (2 * p1.x) +
            (-p0.x + p2.x) * t +
            (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * tt +
            (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * ttt
        )
        let y = 0.5 * (
            (2 * p1.y) +
            (-p0.y + p2.y) * t +
            (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * tt +
            (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * ttt
        )
        return CGPoint(x: x, y: y)
    }
}

/// Dash runs remain separate so renderers never connect across an off interval.
/// matches ReferenceRenderer mate-draw-engine.js / mate-draw-pieces.js parameter dash 8 / gap 5.
func drawingDashedRuns(points: [CGPoint], dash: DrawingDash = [8, 5]) -> [[CGPoint]] {
    guard points.count > 1, !dash.isEmpty, dash.allSatisfy({ $0.isFinite && $0 > 0 }) else { return [points] }
    let pattern = dash.count.isMultiple(of: 2) ? dash : dash + dash
    var runs: [[CGPoint]] = [], run: [CGPoint] = []
    var index = 0, remaining = pattern[0]
    for (a, b) in zip(points, points.dropFirst()) {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0 else { continue }
        var offset: CGFloat = 0
        func point(_ distance: CGFloat) -> CGPoint {
            let t = distance / length
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        while offset < length {
            let take = min(remaining, length - offset)
            if index.isMultiple(of: 2) {
                if run.isEmpty { run.append(point(offset)) }
                run.append(point(offset + take))
            }
            offset += take
            remaining -= take
            if remaining < 0.000001 {
                if !run.isEmpty { runs.append(run); run.removeAll() }
                index = (index + 1) % pattern.count
                remaining = pattern[index]
            }
        }
    }
    if !run.isEmpty { runs.append(run) }
    return runs
}

/// Compatibility sampling API. Drawing uses native dashed subpaths, never this flattened list.
func drawingDashedPoints(points: [CGPoint], dash: DrawingDash) -> [CGPoint] {
    drawingDashedRuns(points: points, dash: dash).flatMap { $0 }
}
