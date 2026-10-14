//
//  NotchBuddyView.swift
//  HeyMate
//
//  The notch character, drawn in code: a tiny round mate in the active
//  mate's colour with stubby feet, nub arms and the same ink eyes and
//  cheeks as `MateLiveFace`. Effects (z's, thought dots, sparkles, speed
//  lines) are matte white or the accent. No bitmaps, no sprite sheets.
//
//  Redraws come from a custom `TimelineSchedule` that asks
//  `NotchBuddyMotion` for the next date: at the pose's frame rate while it
//  animates (24 fps ceiling), one wake-up at the next real change while it
//  is still, and nothing at all while the notch is hidden.
//

import SwiftUI

struct NotchBuddyView: View {
    @ObservedObject var model: NotchBuddyModel
    let height: CGFloat
    let accent: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionMotionSuppressed) private var motionSuppressed
    @Environment(\.companionSnapshotRendering) private var snapshotRendering
    @AppStorage(CompanionAppearancePreference.idleAnimationsKey) private var idleAnimations = true
    @State private var isVisible = false
    /// The tab is rebuilt each time the card closes; the character fades in
    /// with it instead of popping.
    @State private var hasAppeared = false

    private var motion: NotchBuddyMotion {
        NotchBuddyMotion(policy: CompanionMotionPolicy(
            reduceMotion: reduceMotion || motionSuppressed,
            idleAnimations: idleAnimations,
            isVisible: isVisible && !snapshotRendering
        ))
    }

    private var pinnedDate: Date? {
        #if DEBUG
        model.snapshotDate
        #else
        nil
        #endif
    }

    var body: some View {
        let context = model.context
        let motion = motion
        TimelineView(NotchBuddySchedule(context: context, motion: motion)) { timeline in
            let date = pinnedDate ?? timeline.date
            let scene = NotchBuddyDirector.scene(context, at: date, still: motion.isStill)
            let elapsed = date.timeIntervalSince(scene.since)
            // A paused idle (idle motion off) holds the still frame too.
            let still = motion.isStill || (!snapshotRendering && !motion.animates(scene.pose))
            NotchBuddyCanvas(
                pose: scene.pose,
                frame: NotchBuddyFrameClock.frame(for: scene.pose, elapsed: elapsed, still: still),
                loop: NotchBuddyFrameClock.loop(for: scene.pose, elapsed: elapsed, still: still),
                bodyColor: MateFacePalette.color(forMateAsset: model.assetName(for: scene.mateID), mateID: scene.mateID),
                accent: accent
            )
        }
        .frame(width: NotchBuddyArt.cellWidth, height: height)
        .opacity(hasAppeared || snapshotRendering ? 1 : 0)
        .onAppear {
            guard !hasAppeared else { return }
            if reduceMotion || motionSuppressed { hasAppeared = true; return }
            withAnimation(.easeOut(duration: 0.2)) { hasAppeared = true }
        }
        .background {
            if !snapshotRendering { CompanionVisibilityProbe(isVisible: $isVisible) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Redraw dates for the character. A value snapshot, so it never reads
/// the model off the main thread.
nonisolated struct NotchBuddySchedule: TimelineSchedule {
    let context: NotchBuddyContext
    let motion: NotchBuddyMotion

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = startDate
        let lowFrequency = mode == .lowFrequency
        let context = context
        let motion = motion
        return AnyIterator {
            guard let current = next else { return nil }
            next = motion.nextRedraw(after: current, context: context, lowFrequency: lowFrequency)
            return current
        }
    }
}

/// One frame of one pose.
struct NotchBuddyCanvas: View {
    let pose: NotchBuddyPose
    let frame: Int
    let loop: Int
    let bodyColor: Color
    let accent: Color

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            NotchBuddyArt.draw(in: &context, size: size,
                               figure: NotchBuddyFigure.make(pose: pose, frame: frame, loop: loop),
                               body: bodyColor, accent: accent,
                               ink: MateFacePalette.ink, white: DS.Colors.textPrimary)
        }
    }
}

// MARK: - Figure

/// The pose of the drawn character in one frame, in character units
/// (1 unit = notch height / 32). Pure, so the still frame is testable.
nonisolated struct NotchBuddyFigure: Equatable {
    enum Eyes: Equatable { case round, wide, closed, happy }
    enum Mouth: Equatable { case smile, flat, frown, small, open(Double) }
    enum Prop: Equatable { case none, page, pencil, gear, globe }

    /// Vertical body offset; negative lifts.
    var bob: Double = 0
    var squashX: Double = 1
    var squashY: Double = 1
    /// Degrees; positive leans toward the camera (right).
    var tilt: Double = 0
    var eyes: Eyes = .round
    var eyeOpen: Double = 1
    var look: CGSize = .zero
    var mouth: Mouth = .smile
    /// Arm angles in degrees from hanging straight down, swung outward.
    /// Nil keeps the arm tucked out of sight.
    var leftArm: Double?
    var rightArm: Double?
    /// Feet: horizontal offset and lift, in units.
    var leftFoot = CGPoint.zero
    var rightFoot = CGPoint.zero
    var prop: Prop = .none
    var propPhase: Double = 0

    // Effects. Phases run 0…1; nil means not drawn.
    var zPhase: Double?
    var thoughtDots: Int?
    var soundArcs: Double?
    var voiceArcs: Double?
    var exclamation = false
    var sparkles: Double?
    var sweat: Double?
    var dust: Double?
    var speedLines: Int?

    static func make(pose: NotchBuddyPose, frame: Int, loop: Int) -> Self {
        let count = Double(NotchBuddyFrameClock.framesPerPose)
        let f = max(0, min(frame, NotchBuddyFrameClock.framesPerPose - 1))
        let p = Double(f) / count
        let wave = sin(2 * .pi * p)
        var figure = Self()

        switch pose {
        case .idle:
            figure.bob = -abs(wave) * 0.45
            figure.squashY = 1 + 0.02 * wave
            if loop % 3 == 2, f == 12 { figure.eyes = .closed }
            if loop % 3 == 2, f == 13 { figure.eyeOpen = 0.45 }
            if loop % 4 == 1, (4...10).contains(f) { figure.look = CGSize(width: 0.9, height: 0) }

        case .doze:
            figure.eyes = .closed
            figure.squashX = 1.05
            figure.squashY = 0.93 + 0.02 * wave
            figure.tilt = -6
            figure.mouth = p < 0.5 ? .small : .flat
            figure.zPhase = p

        case .waking:
            if f <= 4 {
                let t = Double(f) / 4
                figure.eyes = .closed
                figure.squashY = 0.93 + 0.17 * t
                figure.squashX = 1.05 - 0.11 * t
                figure.leftArm = 30 + 135 * t
                figure.rightArm = 30 + 135 * t
            } else if f <= 10 {
                figure.eyes = f < 8 ? .closed : .happy
                figure.squashY = 1.1
                figure.squashX = 0.94
                figure.mouth = .open(0.9)
                let sway = sin(Double(f - 5) / 5 * 2 * .pi) * 10
                figure.leftArm = 165 + sway
                figure.rightArm = 165 - sway
            } else {
                let t = Double(f - 10) / 5
                figure.squashY = 1.1 - 0.1 * t
                figure.squashX = 0.94 + 0.06 * t
                figure.leftArm = f == 15 ? nil : 165 - 140 * t
                figure.rightArm = f == 15 ? nil : 165 - 140 * t
                figure.bob = -sin(t * .pi) * 1.2
            }

        case .listening:
            figure.eyes = .wide
            figure.look = CGSize(width: 0.9, height: -0.2)
            figure.tilt = 5
            figure.mouth = .small
            figure.bob = -abs(wave) * 0.3
            figure.soundArcs = p

        case .thinking:
            figure.look = CGSize(width: -0.6, height: -1.0)
            figure.mouth = .flat
            figure.tilt = wave * 2.5
            figure.thoughtDots = min(3, (f / 4) % 4 + 1)

        case .speaking:
            let openings: [Double] = [0.2, 0.7, 0.4, 0.9, 0.3, 0.8, 0.5, 1.0, 0.2, 0.6, 0.9, 0.4, 0.7, 0.3, 0.8, 0.5]
            figure.mouth = .open(openings[f])
            figure.look = CGSize(width: 0.5, height: 0)
            figure.bob = -abs(sin(.pi * p * 4)) * 0.4
            figure.voiceArcs = openings[f]

        case .guiding:
            figure.rightArm = 95 + sin(4 * .pi * p) * 6
            figure.look = CGSize(width: 1, height: 0)
            figure.tilt = 4

        case .attention:
            figure.eyes = .wide
            figure.mouth = .open(0.5)
            figure.rightArm = 150 + 20 * sin(4 * .pi * p)
            figure.bob = -max(0, sin(4 * .pi * p)) * 1.0
            figure.exclamation = f % 8 < 6

        case .celebrate:
            figure.eyes = .happy
            figure.mouth = .open(0.7)
            let wiggle = sin(4 * .pi * p) * 10
            figure.leftArm = 160 + wiggle
            figure.rightArm = 160 - wiggle
            if f <= 11 {
                figure.bob = -sin(.pi * Double(f) / 11) * 4.5
                figure.squashY = 1 + 0.06 * sin(.pi * Double(f) / 11)
                figure.squashX = 1 - 0.04 * sin(.pi * Double(f) / 11)
            } else if f <= 13 {
                figure.squashX = 1.08
                figure.squashY = 0.9
            }
            figure.sparkles = p

        case .failed:
            figure.tilt = sin(p * 4 * .pi) * 10 * (1 - p)
            figure.eyeOpen = 0.7
            figure.look = CGSize(width: 0, height: 0.6)
            figure.mouth = .frown
            figure.squashY = 1 - 0.04 * p
            figure.sweat = p

        case .working(let work, let gait):
            let cycles: Double
            let stride: Double
            let lift: Double
            let bounce: Double
            switch gait {
            case .walk: cycles = 1; stride = 2.2; lift = 1.0; bounce = 0.6; figure.tilt = 3
            case .run: cycles = 2; stride = 3.0; lift = 1.6; bounce = 1.0; figure.tilt = 8
            case .sprint: cycles = 4; stride = 3.6; lift = 2.0; bounce = 1.2; figure.tilt = 14
            }
            let phase = 2 * .pi * p * cycles
            figure.leftFoot = CGPoint(x: sin(phase) * stride, y: max(0, cos(phase)) * lift)
            figure.rightFoot = CGPoint(x: sin(phase + .pi) * stride, y: max(0, cos(phase + .pi)) * lift)
            figure.bob = -abs(sin(phase)) * bounce
            let swing = gait == .walk ? 25.0 : 40.0
            figure.leftArm = 30 + sin(phase + .pi) * swing
            figure.rightArm = work == .none || work == .reasoning ? 30 + sin(phase) * swing : 70
            if gait != .walk { figure.dust = (p * cycles).truncatingRemainder(dividingBy: 1) }
            if gait == .sprint { figure.speedLines = f }

            switch work {
            case .none:
                figure.look = CGSize(width: 0.8, height: 0)
            case .reasoning:
                figure.look = CGSize(width: -0.4, height: -1.0)
                figure.mouth = .flat
                figure.thoughtDots = min(3, (f / 4) % 4 + 1)
            case .reading:
                figure.look = CGSize(width: 0.7, height: 0.9)
                figure.mouth = .flat
                figure.prop = .page
            case .writing:
                figure.look = CGSize(width: 0.8, height: 0.8)
                figure.prop = .pencil
                figure.propPhase = p
            case .tooling:
                figure.look = CGSize(width: 1.0, height: 0.2)
                figure.eyeOpen = 0.6
                figure.mouth = .flat
                figure.prop = .gear
                figure.propPhase = p
            case .browsing:
                figure.look = CGSize(width: sin(2 * .pi * p) * 0.9, height: 0)
                figure.mouth = .small
                figure.prop = .globe
                figure.propPhase = p
            }
        }
        return figure
    }
}

// MARK: - Art

enum NotchBuddyArt {
    /// The character's cell: exactly one peek slot, so it never asks the
    /// pill for more width than the widened size already has.
    static var cellWidth: CGFloat { NotchLayoutMath.peekSlotWidth }

    static func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        figure: NotchBuddyFigure,
        body: Color,
        accent: Color,
        ink: Color,
        white: Color
    ) {
        let u = max(size.height, 16) / 32
        let r = 8.2 * u
        let cx = size.width * 0.42
        let ground = size.height - 3.2 * u
        let pivot = CGPoint(x: cx, y: ground - 1.6 * u)
        let center = CGPoint(x: cx, y: pivot.y - r + figure.bob * u)
        let limb = body.blendedWithBlack(fraction: 0.3)

        // Ground shadow and motion trails sit behind the body.
        context.fill(Path(ellipseIn: CGRect(x: cx - 6 * u, y: ground - 0.4 * u, width: 12 * u, height: 1.4 * u)),
                     with: .color(white.opacity(0.07)))
        if let dust = figure.dust {
            for index in 0..<2 {
                let q = (dust + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
                let radius = (0.6 + q * 1.0) * u
                let point = CGPoint(x: cx - r - q * 4 * u, y: ground - q * 1.5 * u)
                context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                    width: radius * 2, height: radius * 2)),
                             with: .color(white.opacity((1 - q) * 0.45)))
            }
        }
        if let lines = figure.speedLines {
            for index in 0..<3 {
                let length = (3 + Double((lines + index * 5) % 3)) * u
                let y = center.y + Double(index - 1) * 3 * u
                let end = cx - r - 1.2 * u
                var line = Path()
                line.move(to: CGPoint(x: end - length, y: y))
                line.addLine(to: CGPoint(x: end, y: y))
                context.stroke(line, with: .color(white.opacity(0.55)),
                               style: StrokeStyle(lineWidth: 0.8 * u, lineCap: .round))
            }
        }

        // Feet stay on the ground while the body bobs above them.
        for (side, foot) in [(-1.0, figure.leftFoot), (1.0, figure.rightFoot)] {
            let footCenter = CGPoint(x: cx + side * 3 * u + foot.x * u, y: ground - 0.9 * u - foot.y * u)
            context.fill(Path(ellipseIn: CGRect(x: footCenter.x - 1.7 * u, y: footCenter.y - 0.9 * u,
                                                width: 3.4 * u, height: 1.8 * u)),
                         with: .color(limb))
        }

        // Body, leaning and squashing from the feet.
        var bodyContext = context
        bodyContext.translateBy(x: pivot.x, y: pivot.y)
        bodyContext.rotate(by: .degrees(figure.tilt))
        bodyContext.scaleBy(x: figure.squashX, y: figure.squashY)
        bodyContext.translateBy(x: 0, y: -r + figure.bob * u)
        // From here the body's centre is the origin.

        let bodyRect = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        bodyContext.fill(Path(ellipseIn: bodyRect),
                         with: .linearGradient(Gradient(colors: [body.blendedWithWhite(fraction: 0.18), body]),
                                               startPoint: CGPoint(x: 0, y: -r), endPoint: CGPoint(x: 0, y: r)))

        // Arms: little nubs that pivot at the shoulders.
        for (side, angle) in [(-1.0, figure.leftArm), (1.0, figure.rightArm)] {
            guard let angle else { continue }
            var arm = bodyContext
            arm.translateBy(x: side * r * 0.82, y: 0.8 * u)
            arm.rotate(by: .degrees(-side * angle))
            arm.fill(Path(roundedRect: CGRect(x: -1 * u, y: -0.6 * u, width: 2 * u, height: 4.6 * u),
                          cornerRadius: 1 * u),
                     with: .color(limb))
        }

        drawFace(in: &bodyContext, figure: figure, u: u, ink: ink)
        drawProp(in: &bodyContext, figure: figure, u: u, r: r, accent: accent, ink: ink, white: white)
        drawEffects(in: &bodyContext, figure: figure, u: u, r: r, accent: accent, white: white)
    }

    private static func drawFace(in context: inout GraphicsContext, figure: NotchBuddyFigure, u: CGFloat, ink: Color) {
        let look = CGSize(width: figure.look.width * u, height: figure.look.height * u)
        for side in [-1.0, 1.0] {
            let eye = CGPoint(x: side * 3.1 * u + look.width, y: -1.0 * u + look.height)
            switch figure.eyes {
            case .closed, .happy:
                var lid = Path()
                let bend = figure.eyes == .closed ? 0.9 * u : -1.1 * u
                lid.move(to: CGPoint(x: eye.x - 1.1 * u, y: eye.y))
                lid.addQuadCurve(to: CGPoint(x: eye.x + 1.1 * u, y: eye.y),
                                 control: CGPoint(x: eye.x, y: eye.y + bend))
                context.stroke(lid, with: .color(ink), style: StrokeStyle(lineWidth: 0.9 * u, lineCap: .round))
            case .round, .wide:
                let wide = figure.eyes == .wide
                let width = (wide ? 2.2 : 1.8) * u
                let height = (wide ? 3.3 : 2.8) * u * max(0.12, figure.eyeOpen)
                context.fill(Path(ellipseIn: CGRect(x: eye.x - width / 2, y: eye.y - height / 2,
                                                    width: width, height: height)),
                             with: .color(ink))
                if wide {
                    context.fill(Path(ellipseIn: CGRect(x: eye.x - 0.2 * u, y: eye.y - 1.1 * u,
                                                        width: 0.7 * u, height: 0.7 * u)),
                                 with: .color(.white.opacity(0.9)))
                }
            }
        }
        for side in [-1.0, 1.0] {
            context.fill(Path(ellipseIn: CGRect(x: side * 5.4 * u - 1.3 * u, y: 1.4 * u, width: 2.6 * u, height: 1.3 * u)),
                         with: .color(Color.pink.opacity(0.35)))
        }
        let mouthX = look.width * 0.4
        var mouth = Path()
        switch figure.mouth {
        case .smile, .flat, .frown:
            let (endY, controlY): (CGFloat, CGFloat) = {
                switch figure.mouth {
                case .smile: return (2.7 * u, 4.0 * u)
                case .frown: return (3.5 * u, 2.2 * u)
                default: return (3.1 * u, 3.1 * u)
                }
            }()
            mouth.move(to: CGPoint(x: mouthX - 1.3 * u, y: endY))
            mouth.addQuadCurve(to: CGPoint(x: mouthX + 1.3 * u, y: endY), control: CGPoint(x: mouthX, y: controlY))
            context.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 0.8 * u, lineCap: .round))
        case .small:
            context.fill(Path(ellipseIn: CGRect(x: mouthX - 0.65 * u, y: 2.6 * u, width: 1.3 * u, height: 1.3 * u)),
                         with: .color(ink))
        case .open(let amount):
            let height = (0.8 + 2.0 * min(max(amount, 0), 1)) * u
            context.fill(Path(ellipseIn: CGRect(x: mouthX - 1.1 * u, y: 3.3 * u - height / 2, width: 2.2 * u, height: height)),
                         with: .color(ink))
        }
    }

    private static func drawProp(
        in context: inout GraphicsContext, figure: NotchBuddyFigure,
        u: CGFloat, r: CGFloat, accent: Color, ink: Color, white: Color
    ) {
        let anchor = CGPoint(x: r + 2.4 * u, y: 1.2 * u)
        switch figure.prop {
        case .none:
            return
        case .page, .pencil:
            var page = context
            page.translateBy(x: anchor.x, y: anchor.y)
            page.rotate(by: .degrees(-8))
            page.fill(Path(roundedRect: CGRect(x: -2.1 * u, y: -2.6 * u, width: 4.2 * u, height: 5.2 * u), cornerRadius: 0.6 * u),
                      with: .color(white.opacity(0.92)))
            for row in 0..<3 {
                var line = Path()
                let y = (-1.3 + Double(row) * 1.3) * u
                line.move(to: CGPoint(x: -1.2 * u, y: y))
                line.addLine(to: CGPoint(x: (row == 2 ? 0.2 : 1.2) * u, y: y))
                page.stroke(line, with: .color(ink.opacity(0.45)), lineWidth: 0.5 * u)
            }
            if figure.prop == .pencil {
                let x = sin(figure.propPhase * 4 * .pi) * 1.0 * u
                var pencil = page
                pencil.translateBy(x: x + 0.8 * u, y: -0.4 * u)
                pencil.rotate(by: .degrees(35))
                pencil.fill(Path(roundedRect: CGRect(x: -0.45 * u, y: -4.2 * u, width: 0.9 * u, height: 4.2 * u), cornerRadius: 0.3 * u),
                            with: .color(accent))
            }
        case .gear:
            var gear = context
            gear.translateBy(x: anchor.x, y: anchor.y)
            gear.rotate(by: .degrees(figure.propPhase * 360))
            for tooth in 0..<6 {
                var spoke = gear
                spoke.rotate(by: .degrees(Double(tooth) * 60))
                spoke.fill(Path(CGRect(x: -0.55 * u, y: -2.7 * u, width: 1.1 * u, height: 1.2 * u)), with: .color(white))
            }
            gear.stroke(Path(ellipseIn: CGRect(x: -1.6 * u, y: -1.6 * u, width: 3.2 * u, height: 3.2 * u)),
                        with: .color(white), lineWidth: 1.1 * u)
        case .globe:
            let radius = 2.4 * u
            let rect = CGRect(x: anchor.x - radius, y: anchor.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(white.opacity(0.12)))
            context.stroke(Path(ellipseIn: rect), with: .color(white), lineWidth: 0.7 * u)
            let meridian = abs(cos(figure.propPhase * 2 * .pi)) * radius
            context.stroke(Path(ellipseIn: CGRect(x: anchor.x - meridian, y: anchor.y - radius,
                                                  width: max(0.3 * u, meridian * 2), height: radius * 2)),
                           with: .color(accent), lineWidth: 0.6 * u)
            var equator = Path()
            equator.move(to: CGPoint(x: anchor.x - radius, y: anchor.y))
            equator.addLine(to: CGPoint(x: anchor.x + radius, y: anchor.y))
            context.stroke(equator, with: .color(white.opacity(0.7)), lineWidth: 0.5 * u)
        }
    }

    private static func drawEffects(
        in context: inout GraphicsContext, figure: NotchBuddyFigure,
        u: CGFloat, r: CGFloat, accent: Color, white: Color
    ) {
        if let zPhase = figure.zPhase {
            for index in 0..<3 {
                let q = (zPhase + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                let side = (2.0 + q * 1.4) * u
                let origin = CGPoint(x: r * 0.55 + q * 5 * u, y: -r - 0.5 * u - q * 7 * u - side)
                var z = Path()
                z.move(to: origin)
                z.addLine(to: CGPoint(x: origin.x + side, y: origin.y))
                z.addLine(to: CGPoint(x: origin.x, y: origin.y + side))
                z.addLine(to: CGPoint(x: origin.x + side, y: origin.y + side))
                context.stroke(z, with: .color(white.opacity(sin(.pi * max(0.12, q)) * 0.95)),
                               style: StrokeStyle(lineWidth: 0.75 * u, lineCap: .round, lineJoin: .round))
            }
        }
        if let lit = figure.thoughtDots {
            let radii: [CGFloat] = [0.6, 0.85, 1.1]
            for index in 0..<3 {
                let radius = radii[index] * u
                let point = CGPoint(x: r * 0.75 + Double(index) * 2.3 * u, y: -r - 0.8 * u - Double(index) * 1.6 * u)
                context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                             with: .color(white.opacity(index < lit ? 0.95 : 0.25)))
            }
        }
        if let soundArcs = figure.soundArcs {
            arcs(in: &context, at: CGPoint(x: r + 0.6 * u, y: -1 * u), u: u, color: accent) { index in
                0.35 + 0.65 * max(0, sin(2 * .pi * (soundArcs - Double(index) * 0.25)))
            }
        }
        if let voiceArcs = figure.voiceArcs {
            arcs(in: &context, at: CGPoint(x: r + 0.4 * u, y: 2.4 * u), u: u, color: white) { index in
                (0.2 + 0.6 * voiceArcs) * (index == 0 ? 1 : 0.6)
            }
        }
        if figure.exclamation {
            let x = -r - 1.6 * u
            let top = -r - 0.4 * u
            context.fill(Path(roundedRect: CGRect(x: x - 0.6 * u, y: top, width: 1.2 * u, height: 3.6 * u), cornerRadius: 0.6 * u),
                         with: .color(accent))
            context.fill(Path(ellipseIn: CGRect(x: x - 0.6 * u, y: top + 4.3 * u, width: 1.2 * u, height: 1.2 * u)),
                         with: .color(accent))
        }
        if let sparkles = figure.sparkles {
            let spots: [CGPoint] = [CGPoint(x: -r - 2.2 * u, y: -r * 0.6), CGPoint(x: r + 2.4 * u, y: -r * 0.9),
                                    CGPoint(x: -r - 0.6 * u, y: -r - 2.6 * u), CGPoint(x: r + 1.0 * u, y: r * 0.2)]
            for (index, spot) in spots.enumerated() {
                let q = (sparkles * 2 + Double(index) * 0.25).truncatingRemainder(dividingBy: 1)
                let scale = (0.6 + 0.6 * sin(.pi * q)) * u
                context.fill(sparkle(at: spot, size: 1.6 * scale), with: .color(index.isMultiple(of: 2) ? accent : white))
            }
        }
        if let sweat = figure.sweat {
            let x = r * 0.7
            let y = -r * 0.55 + sweat * 2 * u
            var drop = Path()
            drop.move(to: CGPoint(x: x, y: y - 1.4 * u))
            drop.addQuadCurve(to: CGPoint(x: x, y: y + 0.9 * u), control: CGPoint(x: x + 1.5 * u, y: y + 0.6 * u))
            drop.addQuadCurve(to: CGPoint(x: x, y: y - 1.4 * u), control: CGPoint(x: x - 1.5 * u, y: y + 0.6 * u))
            context.fill(drop, with: .color(white.opacity(0.8)))
        }
    }

    private static func arcs(
        in context: inout GraphicsContext, at origin: CGPoint, u: CGFloat, color: Color,
        opacity: (Int) -> Double
    ) {
        for index in 0..<2 {
            var arc = Path()
            arc.addArc(center: origin, radius: (2.0 + Double(index) * 1.8) * u,
                       startAngle: .degrees(-40), endAngle: .degrees(40), clockwise: false)
            context.stroke(arc, with: .color(color.opacity(opacity(index))),
                           style: StrokeStyle(lineWidth: 0.8 * u, lineCap: .round))
        }
    }

    private static func sparkle(at point: CGPoint, size: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: point.x, y: point.y - size))
        path.addQuadCurve(to: CGPoint(x: point.x + size, y: point.y), control: point)
        path.addQuadCurve(to: CGPoint(x: point.x, y: point.y + size), control: point)
        path.addQuadCurve(to: CGPoint(x: point.x - size, y: point.y), control: point)
        path.addQuadCurve(to: CGPoint(x: point.x, y: point.y - size), control: point)
        return path
    }
}
