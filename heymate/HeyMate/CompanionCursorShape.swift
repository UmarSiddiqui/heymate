//
//  CompanionCursorShape.swift
//  HeyMate
//
//  HeyMate's floating cursor: the arrowhead from the app icon, with no
//  shaft. The notch dock and the screen overlay draw the same glyph, so a
//  flight into or out of the dock never shows a visible swap.
//

import SwiftUI

/// An arrowhead with a notched base. The notch keeps it reading as a
/// pointer at any rotation, which matters while it banks through a flight.
struct CompanionCursorShape: Shape {
    /// The angle the cursor rests at, tilted like a system pointer.
    static let restingHeadingDegrees: Double = -35

    func path(in rect: CGRect) -> Path {
        func corner(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: corner(0.50, 0.04))
        path.addLine(to: corner(0.08, 0.92))
        path.addLine(to: corner(0.50, 0.66))
        path.addLine(to: corner(0.92, 0.92))
        path.closeSubpath()
        return path
    }
}

/// The cursor as it appears on screen: filled, sized and glowing.
struct CompanionCursorGlyph: View {
    var headingDegrees: Double = CompanionCursorShape.restingHeadingDegrees
    /// Added to the resting glow radius; a flight brightens it mid-air.
    var extraGlow: CGFloat = 0

    var body: some View {
        CompanionCursorShape()
            .fill(DS.Colors.overlayCursorBlue)
            .frame(width: 16, height: 16)
            .rotationEffect(.degrees(headingDegrees))
            .shadow(color: DS.Colors.overlayCursorBlue, radius: 8 + extraGlow)
    }
}
