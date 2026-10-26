// From vinzdg/codenotch Features/ProviderRing.swift, MIT, revision 6522e9f.
import AppKit
import SwiftUI
struct CNSpinningArc: NSViewRepresentable {
    let color: Color
    let arcFraction: CGFloat
    let dashed: Bool
    let inset: CGFloat
    let turns: Bool

    func makeNSView(context: Context) -> CNSpinningArcView { CNSpinningArcView() }

    func updateNSView(_ view: CNSpinningArcView, context: Context) {
        view.configure(color: NSColor(color), arcFraction: arcFraction,
                       dashed: dashed, inset: inset, turns: turns)
    }
}

final class CNSpinningArcView: NSView {
    static let turnDuration: CFTimeInterval = 1.1
    static let animationKey = "turn"

    let arc = CAShapeLayer()
    private var color: NSColor = .white
    private var inset: CGFloat = 0
    private var turns = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineCap = .round
        arc.lineWidth = CNNotchLayout.activityStroke
        arc.strokeStart = 0
        layer?.addSublayer(arc)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Decoration only: clicks belong to the ring and the notch beneath it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(color: NSColor, arcFraction: CGFloat, dashed: Bool, inset: CGFloat, turns: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.color = color
        self.inset = inset
        self.turns = turns
        arc.strokeEnd = arcFraction
        arc.lineDashPattern = dashed
            ? [0.01, NSNumber(value: Double(CNNotchLayout.activityStroke * 2.2))]
            : nil
        applyColor()
        rebuildPath()
        CATransaction.commit()
        updateAnimation()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rebuildPath()
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func applyColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            arc.strokeColor = color.cgColor
        }
    }

    /// The layer's own coordinates run y-up, so a visually clockwise circle
    /// starting at 3 o'clock is drawn with decreasing angles — the same start
    /// and direction as SwiftUI's `Circle().trim(from: 0, …)`.
    private func rebuildPath() {
        arc.frame = bounds
        let radius = max(0, min(bounds.width, bounds.height) / 2 - inset)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius,
                    startAngle: 0, endAngle: -2 * .pi, clockwise: true)
        arc.path = path
    }

    /// Re-added whenever it has gone missing: AppKit drops layer animations
    /// when a window leaves the screen, and the notch's panel does.
    private func updateAnimation() {
        guard turns, window != nil else {
            arc.removeAnimation(forKey: Self.animationKey)
            return
        }
        guard arc.animation(forKey: Self.animationKey) == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = Self.turnDuration
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        arc.add(turn, forKey: Self.animationKey)
    }
}

/// **A cell's percentage**, on its own: under its ring, or — merged into the
/// Mac's notch with a single ring — on the other side of the Mac's notch,
/// where the notch widens with nothing else to carry.
