//
//  DrawingChoreographer.swift
//  HeyMate
//
//  Makes the buddy cursor the thing that builds a drawing: it flies to each
//  stroke's start, presses the pen down, and traces the stroke's path while
//  the ink reveals underneath the tip, then lifts and springs to the next
//  stroke. Cursor position and ink progress are sampled from one wall clock,
//  so the two never drift apart and a dropped frame never slows the build.
//

import AppKit
import Combine

/// One pen stroke the cursor will trace, with its geometry pre-sampled so
/// the tick loop only ever interpolates between points.
nonisolated struct DrawingStroke: Equatable, Identifiable {
    enum Role: Equatable {
        /// Pen traces `points` while the shape's trim follows the same progress.
        case trace
        /// Zero-length pen dip: the marker pops in as the tip touches down.
        case tap
    }

    let id: UUID
    let role: Role
    /// Screen-overlay-local points along the stroke, in draw order.
    let points: [CGPoint]
    /// Cumulative point-to-point distances; `lengths.last` is the total.
    let lengths: [CGFloat]
    let duration: TimeInterval

    /// Pen speed in points/second; a stroke never runs shorter than the
    /// minimum (it would feel like a pop) or longer than the maximum (it
    /// would feel like it stalled).
    // matches ReferenceRenderer mate-draw-engine.js / mate-draw-pieces.js parameter penDur speed and clamp.
    static let pointsPerSecond: CGFloat = 600
    static let minimumSeconds: TimeInterval = 0.14
    static let maximumSeconds: TimeInterval = 0.7
    static let tapSeconds: TimeInterval = 0.35

    init(id: UUID, role: Role, points: [CGPoint], duration durationOverride: TimeInterval? = nil) {
        self.id = id
        self.role = role
        self.points = points

        var lengths: [CGFloat] = [0]
        for pair in zip(points, points.dropFirst()) {
            lengths.append(lengths.last! + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y))
        }
        self.lengths = lengths

        let total = lengths.last ?? 0
        switch role {
        case .trace:
            duration = durationOverride
                ?? min(max(TimeInterval(total / Self.pointsPerSecond), Self.minimumSeconds), Self.maximumSeconds)
        case .tap:
            duration = durationOverride ?? Self.tapSeconds
        }
    }

    var length: CGFloat { lengths.last ?? 0 }

    /// Position and travel heading at `fraction` (0…1) of the stroke's length.
    func sample(at fraction: CGFloat) -> (position: CGPoint, headingDegrees: Double) {
        guard points.count > 1, length > 0 else {
            return (points.first ?? .zero, CompanionCursorShape.restingHeadingDegrees)
        }
        let target = min(max(fraction, 0), 1) * length
        var index = 1
        while index < lengths.count - 1 && lengths[index] < target { index += 1 }
        let a = points[index - 1], b = points[index]
        let segment = lengths[index] - lengths[index - 1]
        let t = segment > 0 ? (target - lengths[index - 1]) / segment : 0
        let position = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        // The glyph points up at 0°, atan2 measures from the right.
        let heading = atan2(b.y - a.y, b.x - a.x) * 180 / .pi + 90
        return (position, heading)
    }
}

/// Pure samplers that turn resolved annotations into stroke geometry, so the
/// cursor and the ink traverse exactly the same path.
nonisolated enum DrawingStrokeSampler {

    static func stroke(for annotation: ResolvedAnnotation) -> DrawingStroke {
        DrawingStroke(id: annotation.id, role: role(of: annotation), points: points(for: annotation),
                      duration: DrawingInkTiming.duration(for: annotation))
    }

    private static func role(of annotation: ResolvedAnnotation) -> DrawingStroke.Role {
        switch annotation.kind {
        case .point, .caption, .clear: return .tap
        default: return .trace
        }
    }

    static func points(for annotation: ResolvedAnnotation) -> [CGPoint] {
        switch annotation.kind {
        case .polyline:
            return WobbledPolylineShape.sampledPoints(
                points: annotation.points, close: false, seed: AnnotationCanvasView.seed(for: annotation.id),
                wobble: annotation.style?.dash == nil && annotation.style?.wash != true)

        case .polygon:
            return WobbledPolylineShape.sampledPoints(
                points: annotation.points, close: true, seed: AnnotationCanvasView.seed(for: annotation.id),
                wobble: annotation.style?.dash == nil && annotation.style?.wash != true)

        case .arrow:
            guard annotation.points.count >= 2 else { return annotation.points }
            let start = annotation.points[0], end = annotation.points[1]
            let angle = atan2(end.y - start.y, end.x - start.x)
            // matches ReferenceRenderer mate-draw-engine.js / mate-draw-pieces.js parameter head/headAngle.
            let headLength: CGFloat = 16, headSpread: CGFloat = .pi / 7
            let barbA = CGPoint(x: end.x - headLength * cos(angle - headSpread),
                                y: end.y - headLength * sin(angle - headSpread))
            let barbB = CGPoint(x: end.x - headLength * cos(angle + headSpread),
                                y: end.y - headLength * sin(angle + headSpread))
            // Shaft, lift-free hook out to one barb, back through the tip to the other.
            return subdivided([start, end]) + [barbA, end, barbB]

        case .circle:
            // Same loop the shape renders, so tip and ink stay together.
            return InkLoopShape.sampledPoints(
                center: annotation.center,
                radius: annotation.radius,
                seed: AnnotationCanvasView.seed(for: annotation.id),
                wobble: annotation.style?.dash == nil
            )

        case .roundedRect:
            return roundedRectPerimeter(annotation.rect, cornerRadius: 8)

        case .highlight:
            // The marker sweeps left to right; the tip rides the leading edge.
            let rect = annotation.rect
            return [CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY)]

        case .point, .caption, .clear:
            return [annotation.center]
        }
    }

    /// Splits long segments so heading changes read smoothly along a stroke.
    static func subdivided(_ points: [CGPoint], maxSegment: CGFloat = 24) -> [CGPoint] {
        guard points.count > 1 else { return points }
        var result: [CGPoint] = [points[0]]
        for point in points.dropFirst() {
            let last = result.last!
            let segment = hypot(point.x - last.x, point.y - last.y)
            let steps = max(1, Int((segment / maxSegment).rounded(.up)))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                result.append(CGPoint(x: last.x + (point.x - last.x) * t,
                                      y: last.y + (point.y - last.y) * t))
            }
        }
        return result
    }

    /// Perimeter of a rounded rect, clockwise from just after the top-left corner.
    static func roundedRectPerimeter(_ rect: CGRect, cornerRadius: CGFloat) -> [CGPoint] {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        guard r > 0, rect.width > 0, rect.height > 0 else {
            return [rect.origin, CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
                    rect.origin]
        }
        var points: [CGPoint] = []
        let edgeSteps = 8, cornerSteps = 6
        func edge(from a: CGPoint, to b: CGPoint) {
            for step in 0...edgeSteps {
                let t = CGFloat(step) / CGFloat(edgeSteps)
                points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        func corner(center: CGPoint, from startAngle: CGFloat) {
            for step in 1...cornerSteps {
                let angle = startAngle + CGFloat(step) / CGFloat(cornerSteps) * .pi / 2
                points.append(CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle)))
            }
        }
        // Screen coordinates: y down, so angles run -π (left) → 0 (right) → π.
        edge(from: CGPoint(x: rect.minX + r, y: rect.minY), to: CGPoint(x: rect.maxX - r, y: rect.minY))
        corner(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), from: -.pi / 2)
        edge(from: CGPoint(x: rect.maxX, y: rect.minY + r), to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        corner(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), from: 0)
        edge(from: CGPoint(x: rect.maxX - r, y: rect.maxY), to: CGPoint(x: rect.minX + r, y: rect.maxY))
        corner(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), from: .pi / 2)
        edge(from: CGPoint(x: rect.minX, y: rect.maxY - r), to: CGPoint(x: rect.minX, y: rect.minY + r))
        corner(center: CGPoint(x: rect.minX + r, y: rect.minY + r), from: .pi)
        return points
    }
}

/// Hand-stroke easing: quick set-down, steady middle, soft lift.
nonisolated enum DrawingEase {
    static let control = (x1: 0.35, y1: 0.2, x2: 0.55, y2: 0.95)

    /// Cubic-bezier y for time fraction `x` in 0…1, endpoints (0,0) and (1,1).
    static func value(at x: Double) -> Double {
        let x = min(max(x, 0), 1)
        if x == 0 || x == 1 { return x }
        // Solve x(t) = x by bisection (x(t) is monotonic for these controls).
        var low = 0.0, high = 1.0, t = x
        for _ in 0..<24 {
            let curveX = cubic(t, 0, control.x1, control.x2, 1)
            if abs(curveX - x) < 1e-4 { break }
            if curveX < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return cubic(t, 0, control.y1, control.y2, 1)
    }

    private static func cubic(_ t: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
        let u = 1 - t
        return u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d
    }
}

/// What the overlay needs for one frame: where the pen is, whether it is
/// touching, and how far each stroke has inked.
nonisolated struct DrawingFrameState: Equatable {
    var cursorPosition: CGPoint = .zero
    var headingDegrees: Double = CompanionCursorShape.restingHeadingDegrees
    var penIsDown = false
    /// 1 while a tap dips the tip; used to scale the glyph down briefly.
    var pressDepth: CGFloat = 0
    var progressByID: [UUID: CGFloat] = [:]
    var isActive = false
}

/// Runs the stroke queue against the wall clock. Owned by a screen's
/// `CompanionCursorView`; one instance per overlay keeps multi-display builds
/// drawing only the strokes that belong to that screen.
@MainActor
final class DrawingChoreographer: ObservableObject {

    @Published private(set) var frame = DrawingFrameState()

    private enum Phase {
        case idle
        case flying(path: CursorFlight, startedAt: CFTimeInterval)
        case tracing(stroke: DrawingStroke, startedAt: CFTimeInterval)
        case tapping(stroke: DrawingStroke, startedAt: CFTimeInterval)
    }

    private var phase: Phase = .idle
    private var queue: [DrawingStroke] = []
    private var timer: Timer?
    private var completedProgress: [UUID: CGFloat] = [:]
    /// Where a new flight begins when the queue is appended mid-build.
    private var cursorPosition: CGPoint = .zero

    /// Mirrors the overlay's Reduce Motion setting; can change mid-build.
    var reduceMotion: Bool

    init(reduceMotion: Bool = false) {
        self.reduceMotion = reduceMotion
    }

    deinit {
        timer?.invalidate()
    }

    /// Appends new strokes and starts (or continues) the build from
    /// `cursorStart`, the cursor's current overlay-local position.
    func enqueue(_ strokes: [DrawingStroke], from cursorStart: CGPoint) {
        guard !strokes.isEmpty else { return }
        queue.append(contentsOf: strokes)
        cursorPosition = cursorStart
        if case .idle = phase { advance() }
        startTimerIfNeeded()
        publish()
    }

    /// Drops everything queued and lifts the pen (annotations were cleared).
    func cancel() {
        queue.removeAll()
        phase = .idle
        completedProgress.removeAll()
        timer?.invalidate()
        timer = nil
        frame = DrawingFrameState(cursorPosition: cursorPosition)
    }

    // MARK: - Tick

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        switch phase {
        case .idle:
            timer?.invalidate()
            timer = nil
            frame.isActive = false

        case .flying(let path, let startedAt):
            let progress = (now - startedAt) / path.duration
            if progress >= 1 {
                cursorPosition = path.end
                advance()
            } else {
                let sample = path.sample(at: progress)
                cursorPosition = sample.position
                frame.cursorPosition = sample.position
                frame.headingDegrees = sample.headingDegrees
                frame.penIsDown = false
                frame.pressDepth = 0
            }

        case .tracing(let stroke, let startedAt):
            let elapsed = now - startedAt
            let duration = reduceMotion ? stroke.duration / 3 : stroke.duration
            let raw = min(max(elapsed / duration, 0), 1)
            let eased = CGFloat(DrawingEase.value(at: raw))
            let sample = stroke.sample(at: eased)
            cursorPosition = sample.position
            frame.cursorPosition = sample.position
            frame.headingDegrees = sample.headingDegrees
            frame.penIsDown = true
            // Press harder at set-down and lift at the end of the stroke.
            frame.pressDepth = CGFloat(sin(min(raw, 1) * .pi)) * 0.4 + 0.6
            frame.progressByID[stroke.id] = eased
            if raw >= 1 {
                completedProgress[stroke.id] = 1
                advance()
            }

        case .tapping(let stroke, let startedAt):
            let raw = min(max((now - startedAt) / stroke.duration, 0), 1)
            frame.cursorPosition = stroke.points.first ?? cursorPosition
            frame.headingDegrees = CompanionCursorShape.restingHeadingDegrees
            frame.penIsDown = true
            frame.pressDepth = CGFloat(sin(raw * .pi))
            frame.progressByID[stroke.id] = raw
            if raw >= 1 {
                completedProgress[stroke.id] = 1
                advance()
            }
        }
    }

    /// Moves to the next stroke: fly to its start, then trace or tap.
    private func advance() {
        guard let next = queue.first else {
            phase = .idle
            return
        }
        queue.removeFirst()

        let start = next.points.first ?? cursorPosition
        frame.progressByID[next.id] = frame.progressByID[next.id] ?? 0
        let distance = hypot(start.x - cursorPosition.x, start.y - cursorPosition.y)
        if reduceMotion || distance <= 4 {
            cursorPosition = start
            begin(stroke: next)
        } else {
            phase = .flying(path: CursorFlight(from: cursorPosition, to: start), startedAt: CACurrentMediaTime())
        }
    }

    private func begin(stroke: DrawingStroke) {
        let startedAt = CACurrentMediaTime()
        switch stroke.role {
        case .trace: phase = .tracing(stroke: stroke, startedAt: startedAt)
        case .tap: phase = .tapping(stroke: stroke, startedAt: startedAt)
        }
        frame.progressByID[stroke.id] = 0
    }

    private func publish() {
        frame.isActive = true
        frame.cursorPosition = cursorPosition
        frame.progressByID.merge(completedProgress) { _, new in new }
        for stroke in queue where frame.progressByID[stroke.id] == nil {
            frame.progressByID[stroke.id] = 0
        }
    }
}
