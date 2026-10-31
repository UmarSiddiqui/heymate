//
//  DrawingBrush.swift
//  HeyMate
//
//  Brush varieties and mark styles for 2D drawing on screen, modelled on
//  ReferenceRenderer's drawing-engine capabilities (tapered strokes, multiple
//  brushes, colour, glow, dash, wash) but implemented in HeyMate's own
//  Swift and design system. Parameters match ReferenceRenderer; implementation remains Swift-native.
//
//  A brush describes how a mark is laid down: its width, opacity, whether
//  the line tapers at the ends, whether it is dashed, and whether it is a
//  semi-transparent wash rather than an opaque stroke.
//

import CoreGraphics
import SwiftUI

/// One brush variety. Each has a natural width and opacity so different
/// marks read as different tools (pen for precise arrows, marker for
/// emphasis, pencil for light sketches, brush for broad strokes).
enum DrawingBrush: Equatable, Sendable {
    /// Fine precise line for arrows, underlines, rings. Tapers at both ends.
    case screenPen(width: CGFloat, alpha: CGFloat)
    case pen(width: CGFloat, alpha: CGFloat)
    /// Broad marker for emphasis and highlighting.
    case marker(width: CGFloat, alpha: CGFloat)
    /// Light sketch line, softer and thinner than pen.
    case pencil(width: CGFloat, alpha: CGFloat)
    /// Broad soft stroke for washes and callout fills.
    case brush(width: CGFloat, alpha: CGFloat)
    /// Semi-transparent highlight swept across text or UI.
    case highlighter(width: CGFloat, alpha: CGFloat)
    /// Watercolour wash: semi-transparent filled area, no stroke.
    case wash(width: CGFloat, alpha: CGFloat)

    /// The line width in screen points.
    var width: CGFloat {
        switch self {
        case .screenPen(let w, _): return w
        case .pen(let w, _): return w
        case .marker(let w, _): return w
        case .pencil(let w, _): return w
        case .brush(let w, _): return w
        case .highlighter(let w, _): return w
        case .wash(let w, _): return w
        }
    }

    /// Opacity 0…1.
    var alpha: CGFloat {
        switch self {
        case .screenPen(_, let a): return a
        case .pen(_, let a): return a
        case .marker(_, let a): return a
        case .pencil(_, let a): return a
        case .brush(_, let a): return a
        case .highlighter(_, let a): return a
        case .wash(_, let a): return a
        }
    }

    /// Whether the stroke tapers to a fine point at both ends.
    var tapers: Bool {
        switch self {
        case .screenPen: return false
        case .pen: return true
        case .marker: return false
        case .pencil: return true
        case .brush: return false
        case .highlighter: return false
        case .wash: return false
        }
    }

    /// Whether the mark is a filled wash rather than a stroked line.
    var isWash: Bool {
        if case .wash = self { return true }
        return false
    }

    /// Default brushes for each tool, tuned so drawings read as one family.
    // matches ReferenceRenderer mate-draw-engine.js / mate-draw-pieces.js parameter __SCREEN_PEN.size/taper/alpha and BRUSH sizes.
    static let screenPen = DrawingBrush.screenPen(width: 3.5, alpha: 1.0)
    static let pen = DrawingBrush.pen(width: 2.8, alpha: 1.0)
    static let marker = DrawingBrush.marker(width: 8.0, alpha: 0.9)
    static let pencil = DrawingBrush.pencil(width: 1.8, alpha: 0.85)
    static let brush = DrawingBrush.brush(width: 6.0, alpha: 0.95)
    static let highlighter = DrawingBrush.highlighter(width: 10.0, alpha: 0.35)
    static let wash = DrawingBrush.wash(width: 1.0, alpha: 0.25)
}

/// Optional dash pattern: [on, off, on, off, ...] in points. Nil = solid.
typealias DrawingDash = [CGFloat]

/// Screen ink matches ReferenceRenderer; theme ink and other swatches remain available.
enum DrawingColor: Equatable, Sendable {
    case mateInk
    case ink          // primary marking colour (the buddy's accent)
    case white
    case grey
    case butter       // warm yellow
    case sun          // amber
    case orange
    case peach
    case coral
    case red
    case pink
    case lilac
    case violet
    case sky
    case blue
    case mint
    case leaf
    case brown
    case tan
    case cream

    var color: Color {
        switch self {
        // the default ink of mate-draw-engine.js and the pieces; the other colours are its TONES.
        case .mateInk: return Color(hex: "#3380FF")
        case .ink: return AppTheme.color
        case .white: return Color.white
        case .grey: return Color(hex: "#7D8088")
        case .butter: return Color(hex: "#FDDC5B")
        case .sun: return Color(hex: "#FEC254")
        case .orange: return Color(hex: "#FDA75D")
        case .peach: return Color(hex: "#FDBCA6")
        case .coral: return Color(hex: "#DC655F")
        case .red: return Color(hex: "#D74745")
        case .pink: return Color(hex: "#FD9CBA")
        case .lilac: return Color(hex: "#9E91E4")
        case .violet: return Color(hex: "#6B5AD4")
        case .sky: return Color(hex: "#4BA3F7")
        case .blue: return Color(hex: "#195CC7")
        case .mint: return Color(hex: "#7AD59C")
        case .leaf: return Color(hex: "#439458")
        case .brown: return Color(hex: "#9A633B")
        case .tan: return Color(hex: "#D6A270")
        case .cream: return Color(hex: "#F6EED8")
        }
    }

    /// The colour used for soft glows behind marks (lower opacity than the mark itself).
    var glow: Color {
        // matches ReferenceRenderer mate-draw-engine.js / mate-draw-pieces.js parameter __GLOW opacity.
        color.opacity(0.65)
    }
}

/// One mark's complete style: brush, colour, optional dash, optional glow,
/// optional wash fill. The model can set any subset; defaults apply for the
/// rest.
struct DrawingStyle: Equatable, Sendable {
    var brush: DrawingBrush = .screenPen
    var color: DrawingColor = .mateInk
    var dash: DrawingDash? = nil
    var glow: Bool = false
    /// When true, the mark is rendered as a filled wash instead of a stroke
    /// (ignored unless brush is `.wash`).
    var wash: Bool = false

    /// The resolved SwiftUI color.
    var swiftUIColor: Color { color.color }

    /// The resolved glow color.
    var swiftUIColorGlow: Color { color.glow }
}

extension DrawingStyle {
    /// Default real-screen style: even screen pen, fixed blue ink, soft glow.
    static var screenPen: DrawingStyle {
        DrawingStyle(brush: .screenPen, color: .mateInk, glow: true)
    }

    /// A marker emphasis style.
    static var marker: DrawingStyle {
        DrawingStyle(brush: .marker, color: .ink, glow: true)
    }

    /// A highlighter style swept across text.
    static var highlighter: DrawingStyle {
        DrawingStyle(brush: .highlighter, color: .butter, glow: false)
    }

    /// A light pencil sketch style.
    static var pencil: DrawingStyle {
        DrawingStyle(brush: .pencil, color: .grey, glow: false)
    }
}
