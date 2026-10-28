//
//  CursorPointingMotion.swift
//  HeyMate
//
//  The small moves the cursor makes while it is parked beside a target:
//  a squash-and-settle on landing, one tap when the line says to click,
//  and a slow point / nudge / inspect loop while a guided step is still
//  being spoken. Pure timing, sampled by seconds since landing, so a
//  dropped frame never stretches a move.
//

import CoreGraphics
import Foundation

nonisolated struct CursorPointingMotion: Equatable {
    struct Pose: Equatable {
        /// Distance pushed toward the target, in points.
        var lean: CGFloat = 0
        var scale: CGFloat = 1
        var headingOffsetDegrees: Double = 0
        /// 0...1 while a tap ring spreads from the target, nil otherwise.
        var tapRingProgress: Double?

        static let rest = Pose()
    }

    static let settleDuration: TimeInterval = 0.35
    static let tapWindow: ClosedRange<TimeInterval> = 1.2...1.7
    static let loopPeriod: TimeInterval = 3.4
    static let nudgeWindow: Range<TimeInterval> = 2.15..<2.55
    static let inspectWindow: Range<TimeInterval> = 2.55..<loopPeriod

    /// Tap once when the line asks the user to click, tap or press.
    let taps: Bool

    init(caption: String?) {
        taps = Self.asksForClick(caption ?? "")
    }

    static func asksForClick(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["click", "tap", "press"].contains { lowered.contains($0) }
    }

    /// The pose `elapsed` seconds after landing. `isHeld` is true while a
    /// guided step is still being spoken; the loop only runs then.
    func pose(at elapsed: TimeInterval, isHeld: Bool, reduceMotion: Bool) -> Pose {
        guard !reduceMotion, elapsed >= 0 else { return .rest }

        if elapsed < Self.settleDuration {
            return Pose(scale: Self.settleScale(elapsed / Self.settleDuration))
        }

        if taps, Self.tapWindow.contains(elapsed) {
            let progress = (elapsed - Self.tapWindow.lowerBound)
                / (Self.tapWindow.upperBound - Self.tapWindow.lowerBound)
            // Press in over the first third, then ease back out.
            let press = progress < 1.0 / 3 ? progress * 3 : 1 - (progress - 1.0 / 3) * 1.5
            let depth = CGFloat(max(0, min(press, 1)))
            return Pose(lean: 5 * depth, scale: 1 - 0.14 * depth, tapRingProgress: progress)
        }

        let loopStart = Self.tapWindow.upperBound
        guard isHeld, elapsed >= loopStart else { return .rest }
        let phase = (elapsed - loopStart).truncatingRemainder(dividingBy: Self.loopPeriod)

        if Self.nudgeWindow.contains(phase) {
            let t = (phase - Self.nudgeWindow.lowerBound)
                / (Self.nudgeWindow.upperBound - Self.nudgeWindow.lowerBound)
            return Pose(lean: 3 * CGFloat(sin(t * .pi)))
        }
        if Self.inspectWindow.contains(phase) {
            let t = (phase - Self.inspectWindow.lowerBound)
                / (Self.inspectWindow.upperBound - Self.inspectWindow.lowerBound)
            // Two small looks either way that fade out by the end.
            return Pose(headingOffsetDegrees: 7 * sin(t * 4 * .pi) * (1 - t))
        }
        return .rest
    }

    /// Squashes to 0.86, springs past to 1.06, settles at 1.
    private static func settleScale(_ t: Double) -> CGFloat {
        let keys: [(Double, Double)] = [(0, 1), (0.34, 0.86), (0.7, 1.06), (1, 1)]
        for (from, to) in zip(keys, keys.dropFirst()) where t <= to.0 {
            let local = (t - from.0) / (to.0 - from.0)
            let eased = local * local * (3 - 2 * local)
            return CGFloat(from.1 + (to.1 - from.1) * eased)
        }
        return 1
    }
}
