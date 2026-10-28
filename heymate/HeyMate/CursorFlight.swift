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
    /// Hops stay low and quick; long flights lift higher, swell more and
    /// pull back briefly before take-off.
    enum Reach: Equatable {
        case hop, medium, long

        init(distance: CGFloat) {
            if distance <= 320 { self = .hop }
            else if distance <= 900 { self = .medium }
            else { self = .long }
        }

        var maxLift: CGFloat {
            switch self {
            case .hop: return 40
            case .medium: return 80
            case .long: return 120
            }
        }

        var peakScale: CGFloat {
            switch self {
            case .hop: return 1.15
            case .medium: return 1.3
            case .long: return 1.4
            }
        }

        /// How far it draws back against the flight before leaving, in points.
        var windUp: CGFloat { self == .long ? 14 : 0 }
    }

    struct Sample: Equatable {
        var position: CGPoint
        /// Rotation that points the arrowhead along the direction of travel.
        var headingDegrees: Double
        /// Swells to the reach's peak at mid-flight and is 1 on landing.
        var scale: CGFloat
    }

    let start: CGPoint
    let reach: Reach
    private(set) var end: CGPoint
    private(set) var control: CGPoint
    /// Short hops are quick and long flights take longer, within 0.6–1.4 s.
    let duration: TimeInterval

    init(from start: CGPoint, to end: CGPoint) {
        self.start = start
        self.end = end
        let distance = hypot(end.x - start.x, end.y - start.y)
        duration = min(max(distance / 800, 0.6), 1.4)
        reach = Reach(distance: distance)
        // Lift the midpoint (up is negative y on screen) for a gentle arc.
        let lift = min(distance * 0.2, reach.maxLift)
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
        var position = CGPoint(
            x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
        )
        // Wind-up: a short pull back along the opening direction.
        if reach.windUp > 0, linear < Self.windUpShare {
            let opening = CGVector(dx: control.x - start.x, dy: control.y - start.y)
            let length = max(hypot(opening.dx, opening.dy), 0.001)
            let pull = reach.windUp * CGFloat(sin(linear / Self.windUpShare * .pi))
            position.x -= opening.dx / length * pull
            position.y -= opening.dy / length * pull
        }
        let tangent = CGVector(
            dx: 2 * u * (control.x - start.x) + 2 * t * (end.x - control.x),
            dy: 2 * u * (control.y - start.y) + 2 * t * (end.y - control.y)
        )
        // The arrowhead points up at 0°, while atan2 measures from the right.
        let heading = atan2(tangent.dy, tangent.dx) * 180 / .pi + 90
        return Sample(
            position: position,
            headingDegrees: heading,
            scale: 1 + CGFloat(sin(linear * .pi)) * (reach.peakScale - 1)
        )
    }

    /// Share of the flight spent winding up on long flights.
    static let windUpShare = 0.12
}
