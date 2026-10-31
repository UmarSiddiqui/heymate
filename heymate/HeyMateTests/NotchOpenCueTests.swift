import Foundation
import AppKit
import QuartzCore
import Testing
@testable import HeyMate

@MainActor
struct NotchOpenCueTests {
    private let start = Date(timeIntervalSince1970: 100)

    @Test func progressUsesActualDwellDeadlineAndClampsLateUpdates() {
        let cue = NotchOpenCue(kind: .hover, startedAt: start, duration: 0.16)
        #expect(cue.progress(at: start.addingTimeInterval(-1)) == 0)
        #expect(abs(cue.progress(at: start.addingTimeInterval(0.08)) - 0.5) < 0.0001)
        #expect(cue.progress(at: start.addingTimeInterval(1)) == 1)
        #expect(abs(cue.remaining(at: start.addingTimeInterval(0.08)) - 0.08) < 0.0001)
        #expect(cue.remaining(at: start.addingTimeInterval(1)) == 0)
    }

    @Test func immediateCueNeverDividesByZeroOrCreatesNegativeWait() {
        let cue = NotchOpenCue(kind: .click, startedAt: start, duration: -1)
        #expect(cue.duration == 0)
        #expect(cue.progress(at: start) == 1)
        #expect(cue.remaining(at: start) == 0)
    }

    @Test func replacementHasDistinctIdentityForStaleCallbackRejection() {
        let hover = NotchOpenCue(kind: .hover, startedAt: start, duration: 0.16)
        let click = NotchOpenCue(kind: .click, startedAt: start, duration: 0.09)
        #expect(hover.id != click.id)
        #expect(click.kind == .click)
        #expect(click.duration < hover.duration)
    }

    @Test func reducedMotionLeavesNoAnimatedLayers() throws {
        let view = NotchOpenRingView()
        view.show(NotchOpenCue(kind: .hover, duration: 0.16), reduceMotion: false)
        view.show(NotchOpenCue(kind: .hover, duration: 0.16), reduceMotion: true)
        func animated(_ layer: CALayer) -> Bool {
            !(layer.animationKeys() ?? []).isEmpty || (layer.sublayers ?? []).contains(where: animated)
        }
        #expect(!animated(try #require(view.layer)))
    }

    @Test func ringStrokesFitTheSixteenPointReferenceFootprint() throws {
        let view = NotchOpenRingView()
        view.layout()
        let root = try #require(view.layer)
        let shapes = (root.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        #expect(shapes.count == 2)
        for shape in shapes {
            let path = try #require(shape.path)
            let painted = path.boundingBoxOfPath.insetBy(dx: -shape.lineWidth / 2, dy: -shape.lineWidth / 2)
            #expect(view.bounds.contains(painted))
        }
    }
}
