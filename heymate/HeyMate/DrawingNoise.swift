//
//  DrawingNoise.swift
//  HeyMate
//
//  Deterministic pseudo-random noise for hand-drawn wobble, modelled on
//  ReferenceRenderer's drawing-engine seeded noise (same seed → same stroke every
//  time) but implemented in HeyMate's own Swift. No ReferenceRenderer code is copied.
//
//  A seed derived from the annotation id makes wobble stable across redraws
//  so the pen tip and the inked trim always follow the identical path.
//

import CoreGraphics

/// A deterministic noise stream seeded once. The same seed always produces
/// the same sequence, so a drawing wobbles identically on every frame.
struct DrawingNoise {
    private var s: UInt32

    init(seed: Double) {
        // Mix the seed's bits into a 32-bit state.
        var h = UInt64(seed.bitPattern)
        h = h &* 1664525 &+ 1013904223
        h ^= h >> 30
        h = h &* 1664525 &+ 1013904223
        h ^= h >> 27
        h = h &* 1664525 &+ 1013904223
        self.s = UInt32(truncatingIfNeeded: h ^ (h >> 31))
    }

    /// A deterministic value in -1…1.
    mutating func next() -> CGFloat {
        s = s &* 1664525 &+ 1013904223
        let fraction = CGFloat(s) / CGFloat(UInt32.max)
        return fraction * 2 - 1
    }

    /// A deterministic value in 0…1.
    mutating func unit() -> CGFloat {
        (next() + 1) / 2
    }
}

/// Full segment bow; zero disables wobble for crisp dashed geometry.
let DrawingWobbleAmount: CGFloat = 1
let DrawingWobbleAmplitude: CGFloat = 1

/// Four-point sampling resolves each segment's single bow.
let DrawingMaxSegment: CGFloat = 4

/// Given a polyline, returns resampled points with deterministic wobble applied
/// to interior samples. Corners and endpoints stay exact so pointing precision
/// is never affected.
func drawingWobbledPolyline(
    points: [CGPoint],
    close: Bool,
    seed: Double,
    amplitude: CGFloat = DrawingWobbleAmplitude,
    maxSegment: CGFloat = DrawingMaxSegment
) -> [CGPoint] {
    var vertices = points
    if close, let first = points.first, vertices.count > 1 {
        vertices.append(first)
    }
    guard vertices.count > 1 else { return vertices }

    var result: [CGPoint] = [vertices[0]]
    var noise = DrawingNoise(seed: seed)

    for (a, b) in zip(vertices, vertices.dropFirst()) {
        let length = hypot(b.x - a.x, b.y - a.y)
        // matches ReferenceRenderer mate-draw-engine.js / mate-draw-pieces.js parameter penBow: short segments use 3%, long segments clamp to 2–7 pt.
        let bow = (length < 24 ? length * 0.03 : min(max(length * 0.03, 2), 7)) * amplitude
        let sign: CGFloat = noise.next() < 0 ? -1 : 1
        let steps = max(2, Int((length / max(maxSegment, 0.1)).rounded(.up)))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            var point = CGPoint(x: a.x + (b.x - a.x) * t,
                                y: a.y + (b.y - a.y) * t)
            if step < steps, length > 0.001 {
                let wobble = sign * bow * sin(.pi * t)
                let nx = -(b.y - a.y) / length
                let ny = (b.x - a.x) / length
                point.x += nx * wobble
                point.y += ny * wobble
            }
            result.append(point)
        }
    }
    return result
}
