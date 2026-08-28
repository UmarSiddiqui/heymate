//
//  SpatialGeometry.swift
//  leanring-buddy
//
//  Pure math for the spatial-selection feature (master spec FR-7): simplify
//  a freehand drag into a compact polygon, then normalize polygon + bounding
//  box into 0…1 coordinates relative to the captured display. Kept free of
//  AppKit so every edge case is unit-testable.
//

import CoreGraphics
import Foundation

enum SpatialGeometry {

    /// Normalized selection payload attached to screen context.
    struct NormalizedSelection: Equatable {
        /// Simplified polygon as [[x, y]] pairs, each component 0…1.
        let polygon: [[Double]]
        /// Bounding box [x, y, w, h], each component 0…1.
        let bounds: [Double]
    }

    /// Ramer–Douglas–Peucker polyline simplification. Keeps the gesture's
    /// shape while cutting hundreds of drag samples down to the vertices
    /// that matter — smaller payloads, cleaner prompts.
    nonisolated static func ramerDouglasPeucker(
        points: [CGPoint],
        epsilon: CGFloat
    ) -> [CGPoint] {
        guard points.count > 2, epsilon > 0 else { return points }

        var keepFlags = [Bool](repeating: false, count: points.count)
        keepFlags[0] = true
        keepFlags[points.count - 1] = true

        var stack: [(start: Int, end: Int)] = [(0, points.count - 1)]

        while let (startIndex, endIndex) = stack.popLast() {
            guard endIndex > startIndex + 1 else { continue }

            let start = points[startIndex]
            let end = points[endIndex]

            var maxDistance: CGFloat = 0
            var maxIndex = startIndex

            for candidateIndex in (startIndex + 1)..<endIndex {
                let distance = pointDistance(
                    points[candidateIndex],
                    segmentStart: start,
                    segmentEnd: end
                )
                if distance > maxDistance {
                    maxDistance = distance
                    maxIndex = candidateIndex
                }
            }

            if maxDistance > epsilon {
                keepFlags[maxIndex] = true
                stack.append((startIndex, maxIndex))
                stack.append((maxIndex, endIndex))
            }
        }

        return zip(points, keepFlags).filter(\.1).map(\.0)
    }

    /// Perpendicular distance from `point` to the infinite segment — but
    /// clamped to the segment's span so collinear-ish drags measure against
    /// the endpoints rather than a faraway line.
    private nonisolated static func pointDistance(
        _ point: CGPoint,
        segmentStart: CGPoint,
        segmentEnd: CGPoint
    ) -> CGFloat {
        let dx = segmentEnd.x - segmentStart.x
        let dy = segmentEnd.y - segmentStart.y

        let squaredLength = dx * dx + dy * dy
        if squaredLength == 0 {
            return hypot(point.x - segmentStart.x, point.y - segmentStart.y)
        }

        // Projection parameter t clamped to [0, 1].
        var t = ((point.x - segmentStart.x) * dx + (point.y - segmentStart.y) * dy) / squaredLength
        t = min(max(t, 0), 1)

        let projectedX = segmentStart.x + t * dx
        let projectedY = segmentStart.y + t * dy
        return hypot(point.x - projectedX, point.y - projectedY)
    }

    /// Converts simplified screen-local points (overlay coordinates, y-down)
    /// into the normalized selection payload sent with screen context.
    /// Returns nil for degenerate gestures (too few points or zero-area
    /// bounds) so junk never reaches the model.
    nonisolated static func normalize(
        polygonScreenLocal points: [CGPoint],
        frameSize: CGSize,
        minVertices: Int = 4
    ) -> NormalizedSelection? {
        guard frameSize.width > 0, frameSize.height > 0 else { return nil }
        guard points.count >= minVertices else { return nil }

        let clampedUnit: (CGFloat) -> Double = { min(max($0, 0), 1) }

        let normalizedPolygon = points.map { point in
            [
                clampedUnit(point.x / frameSize.width),
                clampedUnit(point.y / frameSize.height)
            ]
        }

        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }

        let width = maxX - minX
        let height = maxY - minY
        // Require a minimal area so an accidental click doesn't become a
        // "region" the model over-prioritizes.
        guard width >= 8, height >= 8 else { return nil }

        let bounds = [
            clampedUnit(minX / frameSize.width),
            clampedUnit(minY / frameSize.height),
            clampedUnit(width / frameSize.width),
            clampedUnit(height / frameSize.height)
        ]

        return NormalizedSelection(polygon: normalizedPolygon, bounds: bounds)
    }
}
