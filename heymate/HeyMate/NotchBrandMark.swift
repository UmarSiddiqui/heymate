import SwiftUI

/// User-approved 05 Mischief master, drawn as its exact four SVG strokes.
/// Source and handoff: docs/notch-mischief.svg and notch-compact-surface.md.
/// A static 20 pt mark: no image decoding, body, tile, glow or animation.
struct NotchBrandMark: View {
    var body: some View {
        MischiefStrokes()
            .stroke(Color(red: 168.0 / 255, green: 203.0 / 255, blue: 250.0 / 255),
                    style: StrokeStyle(lineWidth: 9 * 20.0 / 128, lineCap: .round, lineJoin: .round))
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }
}

private struct MischiefStrokes: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 18, y: 40))
        path.addLine(to: CGPoint(x: 42, y: 24))
        path.addLine(to: CGPoint(x: 56, y: 41))
        path.move(to: CGPoint(x: 86, y: 48))
        path.addLine(to: CGPoint(x: 114, y: 53))
        path.move(to: CGPoint(x: 70, y: 58))
        path.addLine(to: CGPoint(x: 65, y: 72))
        path.addLine(to: CGPoint(x: 74, y: 75))
        path.move(to: CGPoint(x: 65, y: 99))
        path.addCurve(to: CGPoint(x: 102, y: 88),
                      control1: CGPoint(x: 78, y: 99), control2: CGPoint(x: 94, y: 97))
        return path.applying(CGAffineTransform(scaleX: rect.width / 128, y: rect.height / 128))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}
