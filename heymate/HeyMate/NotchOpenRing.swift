import AppKit
import QuartzCore
import SwiftUI

/// Transient compositor-owned ring. No TimelineView, polling or idle animation.
struct NotchOpenRing: NSViewRepresentable {
    let cue: NotchOpenCue
    let reduceMotion: Bool

    func makeNSView(context: Context) -> NotchOpenRingView { NotchOpenRingView() }
    func updateNSView(_ view: NotchOpenRingView, context: Context) {
        view.show(cue, reduceMotion: reduceMotion)
    }
}

final class NotchOpenRingView: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()
    private var cueID: UUID?
    private var wasReduced = false

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
        wantsLayer = true
        for shape in [track, arc] {
            shape.fillColor = NSColor.clear.cgColor
            shape.lineWidth = 1.4
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        let blue = NSColor(srgbRed: 168.0 / 255, green: 203.0 / 255, blue: 250.0 / 255, alpha: 1)
        track.strokeColor = blue.withAlphaComponent(0.18).cgColor
        arc.strokeColor = blue.cgColor
        arc.transform = CATransform3DMakeRotation(-.pi / 2, 0, 0, 1)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [track, arc] {
            shape.frame = bounds
            shape.path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
        }
        CATransaction.commit()
    }

    func show(_ cue: NotchOpenCue, reduceMotion: Bool) {
        guard cueID != cue.id || wasReduced != reduceMotion else { return }
        cueID = cue.id
        wasReduced = reduceMotion
        layer?.removeAllAnimations()
        arc.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.strokeEnd = 1
        CATransaction.commit()
        let now = Date()
        let remaining = cue.remaining(at: now)
        guard !reduceMotion, remaining > 0 else { return }

        let fill = CABasicAnimation(keyPath: "strokeEnd")
        fill.fromValue = cue.progress(at: now)
        fill.toValue = 1
        fill.duration = remaining
        fill.timingFunction = CAMediaTimingFunction(name: .linear)
        arc.add(fill, forKey: "opening-progress")

        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.65
        spring.toValue = 1
        spring.mass = 1
        spring.stiffness = 650
        spring.damping = 34
        spring.duration = min(spring.settlingDuration, 0.24)
        layer?.add(spring, forKey: "opening-spring")
    }
}
