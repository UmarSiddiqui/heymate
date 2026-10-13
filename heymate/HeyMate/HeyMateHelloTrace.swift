//
//  HeyMateHelloTrace.swift
//  HeyMate
//
//  The first thing a new person sees in the notch: "hey" written out in
//  one glowing stroke, a bright point leading the pen, in the theme color.
//  It plays once per launch; after that, and under Reduce Motion, the word
//  is simply there.
//
//  The letters are one continuous hand-drawn path in a 140 × 100 box
//  (baseline at y = 70), so the pen never lifts.
//

import SwiftUI

/// "hey" in joined handwriting, as a single open path.
struct HeyMateHelloShape: Shape {
    /// Aspect ratio of the drawing box, for callers sizing a frame.
    nonisolated static let aspectRatio: CGFloat = 140.0 / 100.0

    /// Start point, then one cubic segment per entry as
    /// (control 1, control 2, end), in the 140 × 100 drawing box.
    nonisolated private static let start = CGPoint(x: 4, y: 70)
    nonisolated private static let segments: [(CGPoint, CGPoint, CGPoint)] = [
        // h: lead-in, up into the ascender loop, down the stem
        (CGPoint(x: 16, y: 62), CGPoint(x: 34, y: 26), CGPoint(x: 35, y: 12)),
        (CGPoint(x: 36, y: 2), CGPoint(x: 26, y: 2), CGPoint(x: 25, y: 14)),
        (CGPoint(x: 24, y: 30), CGPoint(x: 23, y: 56), CGPoint(x: 21, y: 70)),
        // h: the shoulder
        (CGPoint(x: 26, y: 54), CGPoint(x: 35, y: 45), CGPoint(x: 41, y: 46)),
        (CGPoint(x: 49, y: 47), CGPoint(x: 45, y: 62), CGPoint(x: 47, y: 67)),
        (CGPoint(x: 49, y: 73), CGPoint(x: 57, y: 72), CGPoint(x: 62, y: 66)),
        // e
        (CGPoint(x: 70, y: 58), CGPoint(x: 82, y: 54), CGPoint(x: 81, y: 47)),
        (CGPoint(x: 80, y: 41), CGPoint(x: 68, y: 44), CGPoint(x: 68, y: 56)),
        (CGPoint(x: 68, y: 67), CGPoint(x: 77, y: 72), CGPoint(x: 88, y: 67)),
        // y: the cup
        (CGPoint(x: 93, y: 63), CGPoint(x: 95, y: 52), CGPoint(x: 97, y: 46)),
        (CGPoint(x: 97, y: 58), CGPoint(x: 99, y: 70), CGPoint(x: 107, y: 70)),
        (CGPoint(x: 115, y: 70), CGPoint(x: 119, y: 56), CGPoint(x: 121, y: 46)),
        // y: the tail, looping back into an exit stroke
        (CGPoint(x: 119, y: 60), CGPoint(x: 119, y: 80), CGPoint(x: 115, y: 92)),
        (CGPoint(x: 111, y: 100), CGPoint(x: 99, y: 100), CGPoint(x: 101, y: 90)),
        (CGPoint(x: 103, y: 82), CGPoint(x: 119, y: 74), CGPoint(x: 136, y: 64)),
    ]

    func path(in rect: CGRect) -> Path {
        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: rect.minX + point.x / 140 * rect.width,
                y: rect.minY + point.y / 100 * rect.height
            )
        }
        var path = Path()
        path.move(to: place(Self.start))
        for (control1, control2, end) in Self.segments {
            path.addCurve(to: place(end), control1: place(control1), control2: place(control2))
        }
        return path
    }
}

/// Writes "hey" in the notch, once.
struct HeyMateHelloTrace: View {
    var lineWidth: CGFloat = 2.6
    /// How long the pen takes to write the word.
    var duration: TimeInterval = 2.2

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var progress: CGFloat = 0
    @State private var penOpacity: Double = 1

    /// The word is written once per launch; reopening the notch shows it
    /// already there rather than replaying it every time.
    private static var hasWrittenThisLaunch = false

    /// Waits for the notch to finish opening before the pen starts.
    private static let startDelay: Duration = .milliseconds(450)

    /// Length of the bright leading point, as a fraction of the stroke.
    private static let penLength: CGFloat = 0.05

    var body: some View {
        let shape = HeyMateHelloShape()
        let stroke = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        ZStack {
            // Wide soft bloom, then a tighter one, then the line itself.
            shape.trim(from: 0, to: progress)
                .stroke(ink, style: StrokeStyle(lineWidth: lineWidth * 2.4, lineCap: .round, lineJoin: .round))
                .blur(radius: lineWidth * 3)
                .opacity(0.55)
            shape.trim(from: 0, to: progress)
                .stroke(ink, style: stroke)
                .blur(radius: lineWidth * 0.9)
                .opacity(0.8)
            shape.trim(from: 0, to: progress)
                .stroke(ink, style: stroke)
            // The pen: a short white-hot segment riding the end of the line.
            shape.trim(from: max(0, progress - Self.penLength), to: progress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth * 1.3, lineCap: .round))
                .blur(radius: 1.2)
                .opacity(penOpacity)
        }
        .aspectRatio(HeyMateHelloShape.aspectRatio, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("hey")
        .task { await write() }
    }

    private var ink: LinearGradient {
        LinearGradient(
            colors: [
                DS.Colors.accent.blendedWithWhite(fraction: 0.35),
                DS.Colors.accent,
                DS.Colors.accent.blendedWithWhite(fraction: 0.2),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func write() async {
        guard !accessibilityReduceMotion, !Self.hasWrittenThisLaunch else {
            progress = 1
            penOpacity = 0
            return
        }
        Self.hasWrittenThisLaunch = true
        try? await Task.sleep(for: Self.startDelay)
        withAnimation(.easeInOut(duration: duration)) { progress = 1 }
        try? await Task.sleep(for: .seconds(duration))
        withAnimation(.easeOut(duration: 0.5)) { penOpacity = 0 }
    }
}

#Preview {
    HeyMateHelloTrace()
        .frame(width: 140, height: 100)
        .padding()
        .background(Color.black)
}
