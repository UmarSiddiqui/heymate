//
//  CursorFlight.swift
//  HeyMate
//
//  The arc the cursor flies along when it goes to point at something,
//  comes back, or launches from and lands in the notch dock. Pure geometry,
//  sampled by elapsed time, so a dropped frame never slows a flight down.
//

import CoreGraphics
import Foundation

nonisolated struct CursorFlight: Equatable {
    struct Sample: Equatable {
        var position: CGPoint
        /// Rotation that points the arrowhead along the direction of travel.
        var headingDegrees: Double
        /// Grows to 1.3 at mid-flight and settles back to 1 on landing.
        var scale: CGFloat
    }

    let start: CGPoint
    private(set) var end: CGPoint
    private(set) var control: CGPoint
    /// Short hops are quick and long flights take longer, within 0.6–1.4 s.
    let duration: TimeInterval

    init(from start: CGPoint, to end: CGPoint) {
        self.start = start
        self.end = end
        let distance = hypot(end.x - start.x, end.y - start.y)
        duration = min(max(distance / 800, 0.6), 1.4)
        // Lift the midpoint (up is negative y on screen) for a gentle arc.
        let lift = min(distance * 0.2, 80)
        control = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - lift)
    }

    /// Re-aims the landing at a target that has moved. The arc's peak moves
    /// half as far, so the path bends toward the new spot instead of jumping.
    mutating func retarget(to newEnd: CGPoint) {
        control.x += (newEnd.x - end.x) / 2
        control.y += (newEnd.y - end.y) / 2
        end = newEnd
    }

    /// Where the cursor is at `progress` (0 at take-off, 1 on landing).
    func sample(at progress: Double) -> Sample {
        let linear = min(max(progress, 0), 1)
        // Ease in and out (smoothstep), then walk the quadratic bezier.
        let t = linear * linear * (3 - 2 * linear)
        let u = 1 - t
        let position = CGPoint(
            x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
        )
        let tangent = CGVector(
            dx: 2 * u * (control.x - start.x) + 2 * t * (end.x - control.x),
            dy: 2 * u * (control.y - start.y) + 2 * t * (end.y - control.y)
        )
        // The arrowhead points up at 0°, while atan2 measures from the right.
        let heading = atan2(tangent.dy, tangent.dx) * 180 / .pi + 90
        return Sample(position: position, headingDegrees: heading, scale: 1 + sin(linear * .pi) * 0.3)
    }
}
