//
//  AnnotationCanvasView.swift
//  HeyMate
//
//  The drawings a reply can put on screen (arrows, circles, highlights,
//  captions) and the dashed trail of a spatial selection in progress.
//  Everything here is click-through; it lives inside the screen overlay.
//

import SwiftUI

/// Renders the resolved visual-action annotations belonging to this screen.
/// A timeline tick purges expired annotations without extra timers, and each
/// shape springs in on appearance. Hit testing stays off — the whole layer is
/// click-through.
struct AnnotationCanvasView: View {
    let annotations: [ResolvedAnnotation]
    let screenFrame: CGRect

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
                        AnnotationShapeView(annotation: annotation)
                    }
                }
            }
        }
    }
}

private struct AnnotationShapeView: View {
    let annotation: ResolvedAnnotation

    @State private var appeared = false

    private static let strokeColor = DS.Colors.overlayCursorBlue

    var body: some View {
        shapeBody
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 1.06)
            .onAppear {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    appeared = true
                }
            }
    }

    @ViewBuilder
    private var shapeBody: some View {
        switch annotation.kind {
        case .point:
            pointMarker

        case .arrow:
            arrowShape

        case .polyline:
            // Custom shapes are proposed the full overlay frame, so their
            // path coordinates are already overlay-local — do not re-position.
            PolylineShape(points: annotation.points, close: false)
                .strokedOverlay()

        case .polygon:
            ZStack {
                PolylineShape(points: annotation.points, close: true)
                    .fill(Self.strokeColor.opacity(0.15))
                PolylineShape(points: annotation.points, close: true)
                    .strokedOverlay()
            }

        case .circle:
            Ellipse()
                .stroke(Self.strokeColor, lineWidth: 3)
                .background(
                    Ellipse().fill(Self.strokeColor.opacity(0.10))
                )
                .frame(width: annotation.radius.width * 2, height: annotation.radius.height * 2)
                .shadow(color: Self.strokeColor.opacity(0.6), radius: 6)
                .position(annotation.center)

        case .roundedRect:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Self.strokeColor, lineWidth: 3)
                .frame(width: annotation.rect.width, height: annotation.rect.height)
                .shadow(color: Self.strokeColor.opacity(0.6), radius: 6)
                .position(x: annotation.rect.midX, y: annotation.rect.midY)

        case .highlight:
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(DS.Colors.warning.opacity(0.22))
                .frame(width: annotation.rect.width, height: annotation.rect.height)
                .position(x: annotation.rect.midX, y: annotation.rect.midY)

        case .caption:
            if let label = annotation.label, !label.isEmpty {
                CursorPillLabel(text: label)
                    .position(annotation.center)
            }

        case .clear:
            EmptyView()
        }

        if showsAttachedLabel {
            Text(annotation.label ?? "")
                .font(DS.Fonts.micro)
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
    private var labelPosition: CGPoint {
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

    private var pointMarker: some View {
        ZStack {
            Circle()
                .stroke(Self.strokeColor.opacity(0.55), lineWidth: 2)
                .frame(width: 26, height: 26)
            Circle()
                .fill(Self.strokeColor)
                .frame(width: 10, height: 10)
        }
        .shadow(color: Self.strokeColor.opacity(0.7), radius: 7)
        .position(annotation.center)
    }

    @ViewBuilder
    private var arrowShape: some View {
        if annotation.points.count >= 2 {
            ArrowShape(start: annotation.points[0], end: annotation.points[1])
                .strokedOverlay()
        }
    }
}

/// A stroked polyline (optionally closed) used for polylines and polygons.
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
        if close {
            path.closeSubpath()
        }
        return path
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
        let headLength: CGFloat = 13
        let headSpread: CGFloat = 0.42

        path.move(to: end)
        path.addLine(to: CGPoint(
            x: end.x - headLength * cos(angle - headSpread),
            y: end.y - headLength * sin(angle - headSpread)
        ))
        path.move(to: end)
        path.addLine(to: CGPoint(
            x: end.x - headLength * cos(angle + headSpread),
            y: end.y - headLength * sin(angle + headSpread)
        ))
        return path
    }
}

extension Shape {
    /// Shared stroke treatment so every annotation reads as one visual family.
    fileprivate func strokedOverlay() -> some View {
        self
            .stroke(DS.Colors.overlayCursorBlue, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 5)
    }
}

/// Dashed live trail for the user's in-progress spatial selection drag.
struct SpatialDraftView: View {
    let points: [CGPoint]

    var body: some View {
        PolylineShape(points: points, close: false)
            .stroke(
                DS.Colors.warning,
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [6, 4])
            )
            .shadow(color: DS.Colors.warning.opacity(0.5), radius: 4)
    }
}
