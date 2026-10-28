//
//  AnnotationCanvasView.swift
//  HeyMate
//
//  Renders the resolved visual-action annotations belonging to this screen.
//  Supports tapered strokes, brush varieties, colour, glow, dash, wash and
//  deterministic wobble — HeyMate's own Swift implementation of the 2D
//  drawing capabilities ReferenceRenderer's drawing engine exposes.
//  Everything here is click-through; it lives inside the screen overlay.
//

import SwiftUI
import AppKit
import CoreText

/// Renders the resolved visual-action annotations belonging to this screen.
/// A timeline tick purges expired annotations without extra timers, and each
/// shape springs in on appearance. Hit testing stays off — the whole layer is
/// click-through.
struct AnnotationCanvasView: View {
    let annotations: [ResolvedAnnotation]
    let screenFrame: CGRect
    /// When the drawing choreographer is running a build, it owns each
    /// annotation's ink progress so the pen tip and the stroke never drift.
    var progressOverrides: [UUID: CGFloat]? = nil

    /// A stable per-annotation wobble seed, shared by the rendered shape and
    /// the choreographer's stroke sampler so both traverse the same path.
    nonisolated static func seed(for id: UUID) -> Double {
        Double(id.uuid.0) / 255 * 2 * .pi
    }

    var body: some View {
        if annotations.isEmpty {
            Color.clear
        } else {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let visibleAnnotations = annotations.filter {
                    $0.expiresAt > context.date && $0.screenFrame == screenFrame
                }
                ZStack {
                    ForEach(visibleAnnotations) { annotation in
                        AnnotationShapeView(
                            annotation: annotation,
                            progressOverride: progressOverrides?[annotation.id],
                            obstacles: visibleAnnotations.filter { $0.id != annotation.id }.map(DrawingInkTiming.bounds)
                        )
                    }
                }
            }
        }
    }
}

private struct AnnotationShapeView: View {
    let annotation: ResolvedAnnotation
    /// Choreographer-driven ink share; nil falls back to self-timed inking.
    let progressOverride: CGFloat?
    var obstacles: [CGRect] = []

    @State private var appeared = false
    /// 0…1 share of each stroke drawn so far: lines are inked in, not faded in.
    @State private var inked: CGFloat = 0

    /// The style to render with: colour, brush, dash, glow, wash.
    /// Nil falls back to HeyMate's default screen-pen style.
    private var style: DrawingStyle { annotation.style ?? .screenPen }

    /// The resolved SwiftUI colour for this mark.
    private var markColor: Color { style.swiftUIColor }

    /// Whether this annotation is drawn stroke-by-stroke (vs popping in).
    private var drawsAsInk: Bool {
        switch annotation.kind {
        case .point, .caption, .clear: return false
        default: return true
        }
    }

    private var ink: CGFloat { progressOverride ?? inked }
    private var isAppeared: Bool { appeared || progressOverride != nil }

    var body: some View {
        Group {
            switch annotation.kind {
            case .point:
                pointMarker

            case .arrow:
                arrowShape

            case .polyline:
                WobbledPolylineShape(
                    points: annotation.points, close: false,
                    seed: AnnotationCanvasView.seed(for: annotation.id),
                    wobble: style.dash == nil && !style.wash
                )
                .trim(from: 0, to: ink)
                .strokedOverlay(style: style)

            case .polygon:
                ZStack {
                    WobbledPolylineShape(
                        points: annotation.points, close: true,
                        seed: AnnotationCanvasView.seed(for: annotation.id),
                        wobble: style.dash == nil && !style.wash
                    )
                    // matches ReferenceRenderer mate-draw-engine.js / mate-draw-pieces.js parameter fillAlpha 0.07.
                    .fill(markColor.opacity(0.07 * ink))
                    WobbledPolylineShape(
                        points: annotation.points, close: true,
                        seed: AnnotationCanvasView.seed(for: annotation.id),
                        wobble: style.dash == nil && !style.wash
                    )
                    .trim(from: 0, to: ink)
                    .strokedOverlay(style: style)
                    .opacity(style.wash ? 0 : 1)
                }

            case .circle:
                ZStack {
                    Ellipse()
                        .fill(markColor.opacity(0.10 * ink))
                        .frame(width: annotation.radius.width * 2,
                               height: annotation.radius.height * 2)
                        .position(annotation.center)
                    InkLoopShape(
                        center: annotation.center, radius: annotation.radius,
                        seed: AnnotationCanvasView.seed(for: annotation.id),
                        wobble: style.dash == nil && !style.wash
                    )
                    .trim(from: 0, to: ink)
                    .strokedOverlay(style: style)
                }

            case .roundedRect:
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .trim(from: 0, to: ink)
                    .strokedOverlay(style: style)
                    .frame(width: annotation.rect.width,
                           height: annotation.rect.height)
                    .position(x: annotation.rect.midX,
                              y: annotation.rect.midY)

            case .highlight:
                // A marker swept left to right.
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(markColor.opacity(0.22 * ink))
                    .frame(width: annotation.rect.width,
                           height: annotation.rect.height)
                    .scaleEffect(x: max(ink, 0.001), y: 1, anchor: .leading)
                    .position(x: annotation.rect.midX,
                              y: annotation.rect.midY)

            case .caption:
                if let label = annotation.label, !label.isEmpty {
                    CursorPillLabel(text: label)
                        .position(annotation.center)
                        .opacity(ink)
                }

            case .clear:
                EmptyView()
            }
        }
        .opacity(isAppeared ? 1 : 0)
        .scaleEffect(isAppeared || drawsAsInk ? 1 : 1.06)
        .onAppear {
            guard progressOverride == nil else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                appeared = true
            }
            withAnimation(.easeOut(duration: DrawingInkTiming.duration(for: annotation))) {
                inked = 1
            }
        }
        if showsAttachedLabel {
            Text(annotation.label ?? "")
                .font(DrawingHand.font(size: 12))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.65)))
                .fixedSize()
                .position(labelPosition)
        }
    }


    /// Bounding-box center of the annotation's points (label anchoring).
    private var pathCenter: CGPoint {
        guard !annotation.points.isEmpty else { return annotation.center }
        let xs = annotation.points.map(\.x)
        let ys = annotation.points.map(\.y)
        return CGPoint(
            x: (xs.min()! + xs.max()!) / 2,
            y: (ys.min()! + ys.max()!) / 2
        )
    }

    private var showsAttachedLabel: Bool {
        guard let label = annotation.label, !label.isEmpty else { return false }
        return annotation.kind != .caption && annotation.kind != .clear && annotation.kind != .point
    }

    /// Label placement that keeps small shapes unobscured: above circles and
    /// rects, past the end of arrows/lines.
    private var preferredLabelPosition: CGPoint {
        switch annotation.kind {
        case .circle:
            return CGPoint(x: annotation.center.x, y: annotation.center.y - annotation.radius.height - 12)
        case .roundedRect, .highlight:
            return CGPoint(x: annotation.rect.midX, y: max(12, annotation.rect.minY - 12))
        default:
            if let last = annotation.points.last {
                return CGPoint(x: last.x, y: max(12, last.y - 14))
            }
            return annotation.center
        }
    }

    private var labelPosition: CGPoint {
        let size = DrawingHand.size(annotation.label ?? "", fontSize: 12)
        let halfWidth = (size.width + 12) / 2, halfHeight = (size.height + 6) / 2
        let bounds = DrawingInkTiming.bounds(annotation)
        let candidates = [preferredLabelPosition,
                          CGPoint(x: bounds.midX, y: bounds.minY - halfHeight - 6),
                          CGPoint(x: bounds.midX, y: bounds.maxY + halfHeight + 6),
                          CGPoint(x: bounds.maxX + halfWidth + 6, y: bounds.midY),
                          CGPoint(x: bounds.minX - halfWidth - 6, y: bounds.midY)]
        return candidates.map { point in
            CGPoint(x: min(max(point.x, halfWidth), max(halfWidth, annotation.screenFrame.width - halfWidth)),
                    y: min(max(point.y, halfHeight), max(halfHeight, annotation.screenFrame.height - halfHeight)))
        }.min { a, b in
            func collisions(_ point: CGPoint) -> Int {
                let box = CGRect(x: point.x - halfWidth, y: point.y - halfHeight,
                                 width: halfWidth * 2, height: halfHeight * 2)
                return (obstacles + [bounds]).filter { $0.intersects(box) }.count
            }
            return collisions(a) < collisions(b)
        } ?? preferredLabelPosition
    }

    private var pointMarker: some View {
        ZStack {
            Circle()
                .fill(markColor)
                .frame(width: 10, height: 10)
        }
        .shadow(color: style.swiftUIColorGlow, radius: 12)
        .position(annotation.center)
    }

    @ViewBuilder
    private var arrowShape: some View {
        if annotation.points.count >= 2 {
            ArrowShape(start: annotation.points[0], end: annotation.points[1])
                .trim(from: 0, to: ink)
                .strokedOverlay(style: style)
        }
    }
}

/// A hand-drawn loop around an ellipse: it starts up and to the left,
/// wobbles a little, and runs past its start so the ends do not meet.
struct InkLoopShape: Shape {
    let center: CGPoint
    let radius: CGSize
    let seed: Double
    var wobble: Bool = true

    static let samples = 72

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (index, point) in Self.sampledPoints(center: center, radius: radius, seed: seed, wobble: wobble).enumerated() {
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// The loop as ordered points; the drawing choreographer rides these so
    /// the pen tip and the inked trim follow the identical wobble.
    static func sampledPoints(center: CGPoint, radius: CGSize, seed: Double, wobble: Bool = true) -> [CGPoint] {
        // matches ReferenceRenderer mate-draw-engine.js / mate-draw-pieces.js parameter ring pts.concat([pts[0], pts[1]]) and bow: pen.
        let points = (0..<samples).map { index in
            let angle = -1.9 + Double(index) / Double(samples) * 2 * .pi
            return CGPoint(x: center.x + CGFloat(cos(angle)) * radius.width,
                           y: center.y + CGFloat(sin(angle)) * radius.height)
        }
        let loop = points + Array(points.prefix(2))
        return wobble ? drawingWobbledPolyline(points: loop, close: false, seed: seed) : loop
    }
}

/// A polyline with a small deterministic wobble, so straight strokes read as
/// drawn by hand. Corners and endpoints stay exact — only interior samples
/// wander — so pointing precision is never affected.
struct WobbledPolylineShape: Shape {
    let points: [CGPoint]
    let close: Bool
    let seed: Double
    var wobble: Bool = true

    /// Peak sideways wander of an interior sample, in points.
    static let amplitude: CGFloat = DrawingWobbleAmplitude
    static let maxSegment: CGFloat = DrawingMaxSegment

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let sampled = Self.sampledPoints(points: points, close: close, seed: seed, wobble: wobble)
        guard let first = sampled.first else { return path }
        path.move(to: first)
        for point in sampled.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    static func sampledPoints(points: [CGPoint], close: Bool, seed: Double, wobble: Bool = true) -> [CGPoint] {
        drawingWobbledPolyline(points: points, close: close, seed: seed, amplitude: wobble ? 1 : 0)
    }
}

/// Line + open V arrowhead from start to end.
private struct ArrowShape: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)

        let angle = atan2(end.y - start.y, end.x - start.x)
        // matches ReferenceRenderer mate-draw-engine.js / mate-draw-pieces.js parameter head/headAngle.
        let headLength: CGFloat = 16
        let headSpread: CGFloat = .pi / 7

        path.addLine(to: CGPoint(
            x: end.x - headLength * cos(angle - headSpread),
            y: end.y - headLength * sin(angle - headSpread)
        ))
        path.addLine(to: end)
        path.addLine(to: CGPoint(
            x: end.x - headLength * cos(angle + headSpread),
            y: end.y - headLength * sin(angle + headSpread)
        ))
        return path
    }
}

/// Shared stroke treatment so every annotation reads as one visual family.
/// Applies brush width, colour, dash, taper and glow per `DrawingStyle`.
private extension Shape {
    func strokedOverlay(style: DrawingStyle) -> some View {
        // matches ReferenceRenderer mate-draw-engine.js / mate-draw-pieces.js parameter outline swell and __GLOW radius 12.
        let base = DrawingStrokeShape(source: self, brush: style.brush, dash: style.dash)
            .fill(style.swiftUIColor.opacity(style.brush.alpha))

        if style.glow {
            return base.shadow(color: style.swiftUIColorGlow, radius: 12)
        } else {
            return base.shadow(color: style.swiftUIColor.opacity(0.6), radius: 5)
        }
    }
}

/// Dashed live trail for the user's in-progress spatial selection drag.
struct SpatialDraftView: View {
    let points: [CGPoint]

    var body: some View {
        PolylineShape(points: points, close: false)
            .stroke(
                DS.Colors.warning,
                // matches ReferenceRenderer mate-draw-engine.js / mate-draw-pieces.js parameter dash 8 / gap 5.
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [8, 5])
            )
            .shadow(color: DS.Colors.warning.opacity(0.5), radius: 4)
    }
}

/// A plain stroked polyline (optionally closed).
private struct PolylineShape: Shape {
    let points: [CGPoint]
    let close: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        if close { path.closeSubpath() }
        return path
    }
}

// matches ReferenceRenderer mate-draw-engine.js / mate-draw-pieces.js parameter FONT.hand.
enum DrawingHand {
    private static let registered: Void = {
        if let url = Bundle.main.url(forResource: "PatrickHand-Regular", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
    static func font(size: CGFloat) -> Font {
        _ = registered
        return .custom("PatrickHand-Regular", size: size)
    }
    static func size(_ text: String, fontSize: CGFloat) -> CGSize {
        _ = registered
        return (text as NSString).size(withAttributes: [.font: NSFont(name: "PatrickHand-Regular", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)])
    }
}

// matches ReferenceRenderer mate-draw-engine.js / mate-draw-pieces.js parameter penDur, arrow offset, circle length and text duration.
nonisolated enum DrawingInkTiming {
    static func duration(for annotation: ResolvedAnnotation) -> Double {
        if annotation.kind == .caption { return 0.4 + Double(annotation.label?.count ?? 0) * 0.015 }
        let length: CGFloat
        if annotation.kind == .circle {
            length = .pi * (annotation.radius.width + annotation.radius.height) * 1.06
        } else {
            let points = DrawingStrokeSampler.points(for: annotation)
            length = zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        }
        return min(max(Double(length / 600), 0.14), 0.7) + (annotation.kind == .arrow ? 0.16 : 0)
    }
    static func bounds(_ annotation: ResolvedAnnotation) -> CGRect {
        switch annotation.kind {
        case .circle:
            return CGRect(x: annotation.center.x - annotation.radius.width, y: annotation.center.y - annotation.radius.height,
                          width: annotation.radius.width * 2, height: annotation.radius.height * 2)
        case .roundedRect, .highlight: return annotation.rect
        default:
            let points = annotation.points.isEmpty ? [annotation.center] : annotation.points
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: max(1, xs.max()! - xs.min()!), height: max(1, ys.max()! - ys.min()!))
        }
    }
}

/// Samples each subpath independently, preserving arrow lifts and dash gaps.
private struct DrawingStrokeShape<Source: Shape>: Shape {
    var source: Source
    let brush: DrawingBrush
    let dash: DrawingDash?
    var animatableData: Source.AnimatableData {
        get { source.animatableData }
        set { source.animatableData = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let sourcePath = source.path(in: rect)
        // Screen pen uses one even 3.5 pt width with native round caps and joins.
        // Avoid overlapping filled cap polygons, which can cancel winding at tips.
        if case .screenPen = brush {
            return sourcePath.strokedPath(StrokeStyle(lineWidth: brush.width, lineCap: .round,
                                                      lineJoin: .round, dash: dash ?? []))
        }
        if let dash, !dash.isEmpty {
            // matches ReferenceRenderer mate-draw-engine.js / mate-draw-pieces.js parameter dash 8, gap 5, wobble 0.
            return sourcePath.strokedPath(StrokeStyle(lineWidth: brush.width, lineCap: .round, lineJoin: .round, dash: dash))
        }
        var output = Path(), points: [CGPoint] = []
        var hasCurves = false
        func flush() {
            guard points.count > 1 else { points.removeAll(); return }
            output.addPath(TaperedStrokeBuilder(points: points, brush: brush).path(brushWidth: brush.width))
            points.removeAll()
        }
        sourcePath.forEach { element in
            switch element {
            case .move(let p): flush(); points = [p]
            case .line(let p):
                if let last = points.last {
                    let steps = max(1, Int(ceil(hypot(p.x - last.x, p.y - last.y) / 4)))
                    for i in 1...steps {
                        let t = CGFloat(i) / CGFloat(steps)
                        points.append(CGPoint(x: last.x + (p.x - last.x) * t, y: last.y + (p.y - last.y) * t))
                    }
                }
            case .closeSubpath: if let first = points.first { points.append(first) }; flush()
            default: hasCurves = true
            }
        }
        flush()
        // Curved primitives retain their native geometry rather than disappearing.
        return output.isEmpty || hasCurves ? sourcePath.strokedPath(StrokeStyle(lineWidth: brush.width, lineCap: .round, lineJoin: .round)) : output
    }
}
