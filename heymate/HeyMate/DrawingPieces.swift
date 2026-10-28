//
//  DrawingPieces.swift
//  HeyMate
//
//  ReferenceRenderer-style pieces for drawing on the screen: point, target, hover,
//  frame, ring, ink, write, num, underline, connect, trace. Each piece builds
//  one or more VisualAction(s) that the annotation resolver renders onto
//  overlays. HeyMate's own Swift — same capabilities, HeyMate's code.
//
//  All coordinates are screen points in the overlay's local space (top-left
//  origin, y down), matching CompanionCursorView and VisualActionResolver.
//

import CoreGraphics
import SwiftUI

/// A screen pen: the default mark used for pointing at and marking real
/// things. Even 3.5pt line with round ends and a soft glow.
public struct ScreenPen {
    public var size: CGFloat = 3.5
    public var taper: CGFloat = 0        // 0 = no taper, 1 = full taper to tip
    public var glow: [CGFloat] = [0.65, 12]  // [opacity, radius] in points
    public var dash: CGFloat? = nil      // dash length, nil = solid
    public var dashGap: CGFloat? = nil   // gap between dashes
    public var smooth: Bool = true       // Catmull-Rom smoothing
    public var wobble: CGFloat = 0.6     // hand-drawn wobble amount
    public var bow: String? = nil        // 'pen' = bends each side once
    public var fill: Color? = nil        // fill colour for closed shapes
    public var fillAlpha: CGFloat = 0    // fill opacity
    public var wash: Bool = false        // filled wash instead of stroke
    public var role: String? = nil       // semantic role (frame, ring, underline, ...)
    public var label: String? = nil      // pill label
    public var marquee: [CGFloat]? = nil // [x, y, w, h, r] for host-drawn marquee
}

/// HeyMate's ink colour — the buddy's accent, used for marking the real screen.
public let mateInk: Color = AppTheme.color

/// Default screen pen style: 3.5pt, no taper, glow in the ink colour.
public let screenPen = ScreenPen()

// MARK: - Point

/// point(x, y, label): the pen rings the exact spot, named in a pill.
/// - Parameters:
///   - x, y: centre of the point, screen points.
///   - label: pill text naming the spot.
/// - Returns: one VisualAction (circle) plus an optional caption pill.
func point(x: CGFloat, y: CGFloat, label: String? = nil) -> [VisualAction] {
    let r: CGFloat = 12
    let circle = VisualAction(
        type: .circle,
        screenId: nil,
        x: nil, y: nil,
        points: nil,
        center: [Double(x), Double(y)],
        radius: [Double(r), Double(r)],
        rect: nil,
        label: label,
        ttlMs: nil,
        style: DrawingStyle(
            brush: .pen(width: 3.5, alpha: 1.0),
            color: .ink,
            glow: true
        )
    )
    var actions: [VisualAction] = [circle]
    if let label {
        actions.append(VisualAction(
            type: .caption,
            screenId: nil,
            x: Double(x), y: Double(y),
            points: nil, center: nil, radius: nil, rect: nil,
            label: label, ttlMs: nil,
            style: nil
        ))
    }
    // Dot in the centre
    actions.append(VisualAction(
        type: .point,
        screenId: nil,
        x: Double(x), y: Double(y),
        points: nil, center: nil, radius: nil, rect: nil,
        label: nil, ttlMs: nil,
        style: DrawingStyle(
            brush: .pen(width: 3.0, alpha: 1.0),
            color: .ink,
            glow: true
        )
    ))
    return actions
}

// MARK: - Target / Hover

/// target(x, y, w, h, label): outlines a control by its box (top-left, width,
/// height), dashed frame, named in a pill. The app draws the click-wait ring.
/// - Parameters:
///   - x, y: top-left corner.
///   - w, h: width, height.
///   - label: pill text.
/// - Returns: VisualActions for the dashed outline and centre dot.
func target(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, label: String? = nil) -> [VisualAction] {
    let p: CGFloat = 4
    let pts = roundedRectPoints(
        x: x - p, y: y - p, width: w + 2 * p, height: h + 2 * p, cornerRadius: (h + 2 * p) / 2
    )
    let dash: [CGFloat] = [8, 5]
    var actions: [VisualAction] = []
    actions.append(VisualAction(
        type: .polyline,
        screenId: nil,
        x: nil, y: nil,
        points: pts.map { [Double($0.x), Double($0.y)] },
        center: nil, radius: nil, rect: nil,
        label: label, ttlMs: nil,
        style: DrawingStyle(
            brush: .pen(width: 3.5, alpha: 1.0),
            color: .ink,
            dash: dash,
            glow: true,
            wash: false
        )
    ))
    let cx = x + w / 2, cy = y + h / 2
    actions.append(VisualAction(
        type: .circle,
        screenId: nil,
        x: nil, y: nil,
        points: nil,
        center: [Double(cx), Double(cy)],
        radius: [Double(min(w, h) / 2 + 6), Double(min(w, h) / 2 + 6)],
        rect: nil,
        label: nil, ttlMs: nil,
        style: DrawingStyle(brush: .pen(width: 0.1, alpha: 0), glow: false)
    ))
    if let label {
        actions.append(VisualAction(
            type: .caption,
            screenId: nil,
            x: Double(cx), y: Double(cy),
            points: nil, center: nil, radius: nil, rect: nil,
            label: label, ttlMs: nil,
            style: nil
        ))
    }
    return actions
}

/// hover(x, y, w, h, label): like target but for hover/wait states.
func hover(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, label: String? = nil) -> [VisualAction] {
    target(x: x, y: y, w: w, h: h, label: label)
}

// MARK: - Frame

/// frame(x, y, w, h, label, radius): an AREA (panel, section, group of fields):
/// faint tint fill + dashed outline in ink, named in a pill.
func frame(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, label: String? = nil, radius: CGFloat? = nil) -> [VisualAction] {
    let p: CGFloat = 3
    let bx = x - p, by = y - p, bw = w + 2 * p, bh = h + 2 * p
    let r = radius ?? min(8, bw / 2, bh / 2)
    let pts = roundedRectPoints(x: bx, y: by, width: bw, height: bh, cornerRadius: r)
    var actions: [VisualAction] = []
    // Faint tint fill
    actions.append(VisualAction(
        type: .polygon,
        screenId: nil,
        x: nil, y: nil,
        points: pts.map { [Double($0.x), Double($0.y)] },
        center: nil, radius: nil, rect: nil,
        label: nil, ttlMs: nil,
        style: DrawingStyle(
            brush: .wash(width: 1, alpha: 0.07),
            color: .ink,
            glow: false,
            wash: true
        )
    ))
    // Dashed outline
    actions.append(VisualAction(
        type: .polyline,
        screenId: nil,
        x: nil, y: nil,
        points: (pts + [pts[0]]).map { [Double($0.x), Double($0.y)] },
        center: nil, radius: nil, rect: nil,
        label: label, ttlMs: nil,
        style: DrawingStyle(
            brush: .pen(width: 3.5, alpha: 1.0),
            color: .ink,
            dash: [8, 5],
            glow: true,
            wash: false
        )
    ))
    if let label {
        actions.append(VisualAction(
            type: .caption,
            screenId: nil,
            x: Double(x), y: Double(y),
            points: nil, center: nil, radius: nil, rect: nil,
            label: label, ttlMs: nil,
            style: nil
        ))
    }
    return actions
}

// MARK: - Ring

/// ring(x, y, w, h, label, radius): a loop around ONE thing (word, number, icon,
/// button), hugging its shape — pill for wide/thin, round for small, rounded
/// box for big. Named in a pill.
func ring(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, label: String? = nil, radius: CGFloat? = nil) -> [VisualAction] {
    let p: CGFloat = 4
    let bw = w + 2 * p, bh = h + 2 * p
    let r: CGFloat
    if let radius { r = radius }
    else {
        let short = min(bw, bh), long = max(bw, bh)
        if short <= 56 { r = short / 2 }
        else if long <= 120 && long < short * 1.4 { r = short / 2 }
        else { r = max(8, min(18, short * 0.12)) }
    }
    let pts = roundedRectPoints(x: x - p, y: y - p, width: bw, height: bh, cornerRadius: r)
    // Bend each long side once like a hand going around; run past start
    let closed = pts + [pts[0], pts[1]]
    var actions: [VisualAction] = []
    actions.append(VisualAction(
        type: .polyline,
        screenId: nil,
        x: nil, y: nil,
        points: closed.map { [Double($0.x), Double($0.y)] },
        center: nil, radius: nil, rect: nil,
        label: label, ttlMs: nil,
        style: DrawingStyle(
            brush: .pen(width: 3.5, alpha: 1.0),
            color: .ink,
            glow: true,
            wash: false
        )
    ))
    if let label {
        actions.append(VisualAction(
            type: .caption,
            screenId: nil,
            x: Double(x + w / 2), y: Double(y + h / 2),
            points: nil, center: nil, radius: nil, rect: nil,
            label: label, ttlMs: nil,
            style: nil
        ))
    }
    return actions
}

// MARK: - Ink

/// ink(pts, options): draw a free pen stroke through points — arrow, curve, or
/// plain line depending on options.
func ink(pts: [CGPoint], arrow: Bool = false, curve: Bool = false, label: String? = nil, size: CGFloat = 3.5, alpha: CGFloat = 1.0, dash: [CGFloat]? = nil, glow: Bool = true) -> [VisualAction] {
    guard pts.count >= 2 else { return [] }
    var actions: [VisualAction] = []
    actions.append(VisualAction(
        type: arrow ? .arrow : .polyline,
        screenId: nil,
        x: nil, y: nil,
        points: pts.map { [Double($0.x), Double($0.y)] },
        center: nil, radius: nil, rect: nil,
        label: label, ttlMs: nil,
        style: DrawingStyle(
            brush: .pen(width: size, alpha: alpha),
            color: .ink,
            dash: dash,
            glow: glow,
            wash: false
        )
    ))
    if let label, pts.indices.contains(pts.count / 2) {
        let mid = pts[pts.count / 2]
        let pill = pillSize(label, size: 12)
        actions.append(VisualAction(
            type: .caption,
            screenId: nil,
            x: Double(mid.x - pill[0] / 2), y: Double(mid.y - pill[1] / 2),
            points: nil, center: nil, radius: nil, rect: nil,
            label: label, ttlMs: nil,
            style: nil
        ))
    }
    return actions
}

// MARK: - Write

/// write(x, y, text, options): free words on calm space, handwriting style.
func write(x: CGFloat, y: CGFloat, _ text: String, size: CGFloat = 24, anchor: String = "start") -> [VisualAction] {
    let w = CGFloat(text.count) * size * 0.5
    let x0: CGFloat
    switch anchor {
    case "middle": x0 = x - w / 2
    case "end": x0 = x - w
    default: x0 = x
    }
    return [VisualAction(
        type: .caption,
        screenId: nil,
        x: Double(x0), y: Double(y),
        points: nil, center: nil, radius: nil,
        rect: [Double(x0), Double(y), Double(w), Double(size * 1.25)],
        label: text, ttlMs: nil,
        style: nil
    )]
}

// MARK: - Num

/// num(x, y, n): a numbered badge (1, 2, 3 ...) for step order.
func num(x: CGFloat, y: CGFloat, _ n: Int, radius: CGFloat? = nil) -> [VisualAction] {
    let r = radius ?? 9
    var actions: [VisualAction] = []
    // Gel disc background
    actions.append(VisualAction(
        type: .circle,
        screenId: nil,
        x: nil, y: nil,
        points: nil,
        center: [Double(x), Double(y)],
        radius: [Double(r), Double(r)],
        rect: nil,
        label: nil, ttlMs: nil,
        style: DrawingStyle(
            brush: .wash(width: 1, alpha: 0.9),
            color: .violet,
            glow: false,
            wash: true
        )
    ))
    // Number text as caption
    actions.append(VisualAction(
        type: .caption,
        screenId: nil,
        x: Double(x), y: Double(y + sizeForDigit(n) * 0.355 + 0.8),
        points: nil, center: nil, radius: nil, rect: nil,
        label: String(n), ttlMs: nil,
        style: nil
    ))
    return actions
}

private func sizeForDigit(_ n: Int) -> CGFloat {
    9 * 1.15
}

// MARK: - Underline

/// underline(x, y, w): a thin pen line under words. y is the bottom of the letters.
func underline(x: CGFloat, y: CGFloat, w: CGFloat) -> [VisualAction] {
    let yy = y + 3
    return [VisualAction(
        type: .polyline,
        screenId: nil,
        x: nil, y: nil,
        points: [[Double(x), Double(yy)], [Double(x + w), Double(yy)]],
        center: nil, radius: nil, rect: nil,
        label: nil, ttlMs: nil,
        style: DrawingStyle(
            brush: .pen(width: 3, alpha: 1.0),
            color: .ink,
            glow: true,
            wash: false
        )
    )]
}

// MARK: - Connect

/// connect(a, b, label): a curved arrow from one real thing to another.
func connect(a: CGPoint, b: CGPoint, label: String? = nil, bend: CGFloat = 0.2) -> [VisualAction] {
    // Build a curved path: control point offset perpendicular to the chord
    let dx = b.x - a.x, dy = b.y - a.y
    let len = hypot(dx, dy)
    guard len > 0 else { return [] }
    let nx = -dy / len, ny = dx / len
    let ctrl = CGPoint(
        x: (a.x + b.x) / 2 + nx * len * bend,
        y: (a.y + b.y) / 2 + ny * len * bend
    )
    let pts = [a, ctrl, b]
    var actions: [VisualAction] = []
    actions.append(VisualAction(
        type: .polyline,
        screenId: nil,
        x: nil, y: nil,
        points: pts.map { [Double($0.x), Double($0.y)] },
        center: nil, radius: nil, rect: nil,
        label: label, ttlMs: nil,
        style: DrawingStyle(
            brush: .pen(width: 3.5, alpha: 1.0),
            color: .ink,
            glow: true,
            wash: false
        )
    ))
    if let label {
        actions.append(VisualAction(
            type: .caption,
            screenId: nil,
            x: Double(ctrl.x), y: Double(ctrl.y),
            points: nil, center: nil, radius: nil, rect: nil,
            label: label, ttlMs: nil,
            style: nil
        ))
    }
    return actions
}

// MARK: - Trace

/// trace(pts, options): a closed outline around an irregular thing (region,
/// cluster, passage). straight: true keeps corners; fill: true tints inside.
func trace(pts: [CGPoint], straight: Bool = false, fill: Bool = false, label: String? = nil) -> [VisualAction] {
    guard pts.count >= 2 else { return [] }
    var actions: [VisualAction] = []
    let closed = pts + [pts[0]]
    if fill {
        actions.append(VisualAction(
            type: .polygon,
            screenId: nil,
            x: nil, y: nil,
            points: closed.map { [Double($0.x), Double($0.y)] },
            center: nil, radius: nil, rect: nil,
            label: nil, ttlMs: nil,
            style: DrawingStyle(
                brush: .wash(width: 1, alpha: 0.18),
                color: .ink,
                glow: false,
                wash: true
            )
        ))
    }
    actions.append(VisualAction(
        type: .polyline,
        screenId: nil,
        x: nil, y: nil,
        points: closed.map { [Double($0.x), Double($0.y)] },
        center: nil, radius: nil, rect: nil,
        label: label, ttlMs: nil,
        style: DrawingStyle(
            brush: .pen(width: 3.5, alpha: 1.0),
            color: .ink,
            glow: true,
            wash: false
        )
    ))
    if let label, let first = pts.first, let last = pts.last {
        let xs = pts.map { $0.x }, ys = pts.map { $0.y }
        actions.append(VisualAction(
            type: .caption,
            screenId: nil,
            x: Double(xs.min()!), y: Double(ys.min()!),
            points: nil, center: nil, radius: nil, rect: nil,
            label: label, ttlMs: nil,
            style: nil
        ))
    }
    return actions
}

// MARK: - Helpers

func roundedRectPoints(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, cornerRadius: CGFloat) -> [CGPoint] {
    let r = max(0, min(cornerRadius, width / 2, height / 2))
    var pts: [CGPoint] = []
    let arcSteps = 6
    func arc(cx: CGFloat, cy: CGFloat, a0: CGFloat, a1: CGFloat) {
        for k in 0...arcSteps {
            let a = a0 + (a1 - a0) * CGFloat(k) / CGFloat(arcSteps)
            pts.append(CGPoint(x: cx + r * cos(a), y: cy + r * sin(a)))
        }
    }
    // Clockwise from top-left
    arc(cx: x + width - r, cy: y + r, a0: -.pi / 2, a1: 0)
    arc(cx: x + width - r, cy: y + height - r, a0: 0, a1: .pi / 2)
    arc(cx: x + r, cy: y + height - r, a0: .pi / 2, a1: .pi)
    arc(cx: x + r, cy: y + r, a0: .pi, a1: 3 * .pi / 2)
    return pts
}

private func pillSize(_ str: String, size: CGFloat) -> [CGFloat] {
    [round(CGFloat(str.count) * size * 0.58 + size * 1.9), round(size * 1.9)]
}
