//
//  NotchLayoutMathTests.swift
//  leanring-buddyTests
//
//  Layout math for the notch companion pill: notch detection, centering,
//  menu-bar strip placement, and width animation bounds.
//

import CoreGraphics
import Testing
@testable import HeyMate

@MainActor
struct NotchLayoutMathTests {

    /// Live 14″-class MacBook Pro (Mac17,2 / M5) at default scaling:
    /// 1512×982 pt, 32 pt camera-housing inset. Auxiliary strips end at
    /// x=665 and resume at x=850, so the cutout is 185×32 at (665, 950).
    private static let macBookScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private static let notchInset: CGFloat = 32
    private static let auxLeftMaxX: CGFloat = 665
    private static let auxRightMinX: CGFloat = 850  // 1512 − 662
    private static let hardwareWidth: CGFloat = 185  // 850 − 665

    @Test func insetBelowThresholdMeansNoNotch() {
        #expect(!NotchLayoutMath.screenHasNotch(topSafeAreaInset: 0))
        #expect(!NotchLayoutMath.screenHasNotch(topSafeAreaInset: 6))
        #expect(NotchLayoutMath.screenHasNotch(topSafeAreaInset: 24))
    }

    @Test func hardwareWidthDerivedFromAuxiliaryEdges() {
        let width = NotchLayoutMath.hardwareNotchWidth(
            leftMaxX: Self.auxLeftMaxX,
            rightMinX: Self.auxRightMinX
        )
        #expect(width == Self.hardwareWidth)
    }

    @Test func idleTabMatchesTheHardwareCutout() {
        let hardware = NotchLayoutMath.hardwareNotchWidth(
            leftMaxX: Self.auxLeftMaxX,
            rightMinX: Self.auxRightMinX
        )
        let idleWidth = NotchLayoutMath.idlePillWidth(
            leftMaxX: Self.auxLeftMaxX,
            rightMinX: Self.auxRightMinX
        )
        #expect(idleWidth == hardware)
        #expect(idleWidth == Self.hardwareWidth)
    }

    @Test func insetAuxiliaryStripsStillYieldTheHardwareGap() throws {
        // Left strip starts 12pt in from the screen edge, so width-subtraction
        // (1512 − 653 − 662) would be 197. The gap between the rects is still 185.
        let width = NotchLayoutMath.hardwareNotchWidth(
            leftMaxX: 12 + 653,
            rightMinX: 1512 - 662
        )
        #expect(width == Self.hardwareWidth)
        let frame = try #require(NotchLayoutMath.pillFrame(
            screenFrame: Self.macBookScreen,
            topSafeAreaInset: Self.notchInset,
            auxiliaryTopLeftMaxX: 665,
            auxiliaryTopRightMinX: 850
        ))
        #expect(frame == CGRect(x: 665, y: 950, width: 185, height: 32))
    }

    @Test func pillMatchesLiveHardwareNotchExactly() throws {
        let frame = try #require(NotchLayoutMath.pillFrame(
            screenFrame: Self.macBookScreen,
            topSafeAreaInset: Self.notchInset,
            auxiliaryTopLeftMaxX: Self.auxLeftMaxX,
            auxiliaryTopRightMinX: Self.auxRightMinX
        ))

        // Exact cutout measured on this Mac: (665, 950, 185, 32).
        #expect(frame == CGRect(x: 665, y: 950, width: 185, height: 32))
        #expect(frame.height == Self.notchInset)                // not taller than the housing
        #expect(frame.width == Self.hardwareWidth)
        #expect(frame.minX == Self.auxLeftMaxX)                // not the display midline
        #expect(frame.maxY == Self.macBookScreen.maxY)
        #expect(frame.midX != Self.macBookScreen.midX)         // 757.5 vs 756
    }

    @Test func nonNotchedScreenYieldsNoFrame() {
        // External display: no top safe-area inset → feature absent.
        #expect(NotchLayoutMath.pillFrame(
            screenFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            topSafeAreaInset: 0
        ) == nil)
    }

    @Test func negativeOriginDisplaysStayCenteredOnThemselves() throws {
        let leftDisplay = CGRect(x: -1920, y: 982, width: 1920, height: 1080)
        let frame = try #require(NotchLayoutMath.pillFrame(
            screenFrame: leftDisplay,
            topSafeAreaInset: Self.notchInset
        ))
        #expect(frame.midX == leftDisplay.midX)
        #expect(frame.maxY == leftDisplay.maxY)
    }

    @Test func activeInteractionWidensTabBeyondIdle() throws {
        let idle = try #require(NotchLayoutMath.pillFrame(
            screenFrame: Self.macBookScreen,
            topSafeAreaInset: Self.notchInset,
            auxiliaryTopLeftMaxX: Self.auxLeftMaxX,
            auxiliaryTopRightMinX: Self.auxRightMinX
        ))
        let active = try #require(NotchLayoutMath.pillFrame(
            screenFrame: Self.macBookScreen,
            topSafeAreaInset: Self.notchInset,
            auxiliaryTopLeftMaxX: Self.auxLeftMaxX,
            auxiliaryTopRightMinX: Self.auxRightMinX,
            activeInteraction: true
        ))
        #expect(active.width == idle.width + NotchLayoutMath.activeWidthBonus)
        #expect(active.midX == idle.midX)   // stays centered while widening
        #expect(active.height == idle.height)
    }

    // MARK: - Expanded card

    @Test func expandedCardIsCenteredFlushAndTallerThanHousing() throws {
        let frame = try #require(NotchLayoutMath.expandedFrame(
            screenFrame: Self.macBookScreen,
            topSafeAreaInset: Self.notchInset,
            auxiliaryTopLeftMaxX: Self.auxLeftMaxX,
            auxiliaryTopRightMinX: Self.auxRightMinX
        ))

        let notchCenter = NotchLayoutMath.hardwareNotchCenterX(
            screenFrame: Self.macBookScreen,
            auxiliaryTopLeftMaxX: Self.auxLeftMaxX,
            auxiliaryTopRightMinX: Self.auxRightMinX
        )
        #expect(frame.midX == notchCenter)                     // camera housing, not display midline
        #expect(frame.maxY == Self.macBookScreen.maxY)         // flush with screen top
        #expect(frame.height == Self.notchInset + NotchLayoutMath.expandedHeight)
        #expect(frame.width >= NotchLayoutMath.expandedWidth)
    }

    @Test func sixteenInchClassUsesLiveGeometryNotA14InchTable() throws {
        // 16″ MacBook Pro default scaling: 1728×1117 pt, 38 pt housing,
        // ~220 pt cutout. Same formula as this 14″ Mac — no model switch.
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let leftMaxX: CGFloat = (1728 - 220) / 2
        let rightMinX: CGFloat = leftMaxX + 220
        let frame = try #require(NotchLayoutMath.pillFrame(
            screenFrame: screen,
            topSafeAreaInset: 38,
            auxiliaryTopLeftMaxX: leftMaxX,
            auxiliaryTopRightMinX: rightMinX
        ))
        #expect(frame == CGRect(x: leftMaxX, y: 1117 - 38, width: 220, height: 38))
    }

    @Test func expandedCardAlwaysCoversTheNotch() throws {
        // Even with an unusually wide housing (low-res scaling), the card
        // must be wider than the idle tab by a comfortable margin.
        let leftMaxX: CGFloat = 100
        let rightMinX: CGFloat = Self.macBookScreen.maxX - 100
        let wideNotchFrame = try #require(NotchLayoutMath.expandedFrame(
            screenFrame: Self.macBookScreen,
            topSafeAreaInset: Self.notchInset,
            auxiliaryTopLeftMaxX: leftMaxX,
            auxiliaryTopRightMinX: rightMinX
        ))
        let idleWidth = NotchLayoutMath.idlePillWidth(
            leftMaxX: leftMaxX,
            rightMinX: rightMinX
        )
        #expect(wideNotchFrame.width >= idleWidth + 40)
    }

    @Test func expandedCardYieldsNoFrameWithoutNotch() {
        #expect(NotchLayoutMath.expandedFrame(
            screenFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            topSafeAreaInset: 0
        ) == nil)
    }

    @Test func fallbackPillHangsBelowTheMenuBarAndStaysCentered() {
        let external = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let idle = NotchLayoutMath.fallbackPillFrame(screenFrame: external)
        let active = NotchLayoutMath.fallbackPillFrame(screenFrame: external, activeInteraction: true)

        #expect(idle.midX == external.midX)
        #expect(idle.maxY == external.maxY - NotchLayoutMath.fallbackMenuBarHeight)
        #expect(idle.width == NotchLayoutMath.fallbackIdleWidth)
        #expect(idle.height == NotchLayoutMath.fallbackPillHeight)
        #expect(active.width == idle.width + NotchLayoutMath.activeWidthBonus)
        #expect(active.midX == idle.midX)
    }

    @Test func fallbackExpandedCardMatchesControlSurfaceSize() {
        let external = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let frame = NotchLayoutMath.fallbackExpandedFrame(screenFrame: external)

        #expect(frame.midX == external.midX)
        #expect(frame.width == NotchLayoutMath.expandedWidth)
        #expect(frame.height == NotchLayoutMath.expandedHeight)
        #expect(frame.maxY == external.maxY - NotchLayoutMath.fallbackMenuBarHeight)
    }

    @Test func compactChatIsSmallerThanTheFullCardAndStillCoversTheNotch() throws {
        let compact = try #require(NotchLayoutMath.compactChatFrame(
            screenFrame: Self.macBookScreen,
            topSafeAreaInset: Self.notchInset,
            auxiliaryTopLeftMaxX: Self.auxLeftMaxX,
            auxiliaryTopRightMinX: Self.auxRightMinX
        ))
        let full = try #require(NotchLayoutMath.expandedFrame(
            screenFrame: Self.macBookScreen,
            topSafeAreaInset: Self.notchInset,
            auxiliaryTopLeftMaxX: Self.auxLeftMaxX,
            auxiliaryTopRightMinX: Self.auxRightMinX
        ))
        let notchCenter = NotchLayoutMath.hardwareNotchCenterX(
            screenFrame: Self.macBookScreen,
            auxiliaryTopLeftMaxX: Self.auxLeftMaxX,
            auxiliaryTopRightMinX: Self.auxRightMinX
        )

        #expect(compact.midX == notchCenter)
        #expect(compact.maxY == Self.macBookScreen.maxY)
        #expect(compact.height == Self.notchInset + NotchLayoutMath.compactChatHeight)
        #expect(compact.width >= NotchLayoutMath.compactChatWidth)
        #expect(compact.height < full.height)
        #expect(compact.width <= full.width)
    }

    @Test func compactChatYieldsNoFrameWithoutNotch() {
        #expect(NotchLayoutMath.compactChatFrame(
            screenFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            topSafeAreaInset: 0
        ) == nil)
    }

    @Test func fallbackCompactChatHangsBelowTheMenuBar() {
        let external = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = NotchLayoutMath.fallbackCompactChatFrame(screenFrame: external)

        #expect(frame.midX == external.midX)
        #expect(frame.width == NotchLayoutMath.compactChatWidth)
        #expect(frame.height == NotchLayoutMath.compactChatHeight)
        #expect(frame.maxY == external.maxY - NotchLayoutMath.fallbackMenuBarHeight)
    }

    // MARK: - Pixel snap + corners

    @Test func backingAlignmentSnapsFractionalRectToNearestPixel() {
        let fractional = CGRect(x: 100.4, y: 200.4, width: 50.2, height: 32.2)
        let aligned = NotchLayoutMath.backingAlignedRect(fractional, scale: 2)
        #expect(aligned.minX == 100.5)
        #expect(aligned.minY == 200.5)
        #expect(aligned.maxX == 150.5)
        #expect(aligned.maxY == 232.5)
    }

    @Test func backingAlignmentLeavesPixelAlignedRectsAlone() {
        let alreadyAligned = CGRect(x: 665, y: 950, width: 185, height: 32)
        #expect(NotchLayoutMath.backingAlignedRect(alreadyAligned, scale: 2) == alreadyAligned)
    }

    @Test func pillCornerRadiusScalesWithHousingHeight() {
        #expect(NotchLayoutMath.pillCornerRadius(forHeight: 32) == 8)
        #expect(NotchLayoutMath.pillCornerRadius(forHeight: 38) == 9.5)
        #expect(NotchLayoutMath.pillCornerRadius(forHeight: 0) == NotchLayoutMath.pillCornerRadius)
        #expect(NotchLayoutMath.outlineStrokeWidth == 1.5)
    }

    // MARK: - Motion

    @Test func easeOutCubicStartsFastAndSettles() {
        #expect(NotchLayoutMath.easeOutCubic(0) == 0)
        #expect(NotchLayoutMath.easeOutCubic(1) == 1)
        #expect(NotchLayoutMath.easeOutCubic(-1) == 0)
        #expect(NotchLayoutMath.easeOutCubic(2) == 1)
        // Cubic ease-out is ahead of linear at the midpoint.
        #expect(NotchLayoutMath.easeOutCubic(0.5) > 0.5)
    }

    @Test func easeOutExpoAttacksFasterThanCubic() {
        #expect(NotchLayoutMath.easeOutExpo(0) == 0)
        #expect(NotchLayoutMath.easeOutExpo(1) == 1)
        #expect(NotchLayoutMath.easeOutExpo(-1) == 0)
        #expect(NotchLayoutMath.easeOutExpo(2) == 1)
        // The expand's "already there" feel: ~97% of the distance is
        // covered by the midpoint.
        #expect(NotchLayoutMath.easeOutExpo(0.5) > 0.95)
        // No overshoot — the bezel illusion forbids going past 1.
        #expect(NotchLayoutMath.easeOutExpo(0.9) <= 1)
    }

    @Test func easeInCubicStartsSlowAndAccelerates() {
        #expect(NotchLayoutMath.easeInCubic(0) == 0)
        #expect(NotchLayoutMath.easeInCubic(1) == 1)
        #expect(NotchLayoutMath.easeInCubic(-1) == 0)
        #expect(NotchLayoutMath.easeInCubic(2) == 1)
        // Ease-in is behind linear at the midpoint — the collapse holds,
        // then zips into the notch.
        #expect(NotchLayoutMath.easeInCubic(0.5) < 0.5)
    }

    @Test func interpolatedRectWithEasedProgressIsLinear() {
        let pill = CGRect(x: 100, y: 800, width: 200, height: 48)
        let card = CGRect(x: 0, y: 400, width: 400, height: 532)

        let mid = NotchLayoutMath.interpolatedRect(from: pill, to: card, easedProgress: 0.5)

        // Unlike the `progress:` overload, the eased variant applies no
        // curve of its own — the caller's animator owns easing.
        #expect(abs(mid.width - 300) < 0.01)
        #expect(abs(mid.height - 290) < 0.01)
        #expect(abs(mid.midX - pill.midX) < 0.01)
        #expect(abs(mid.midX - card.midX) < 0.01)
    }

    @Test func morphCardnessInvertsOnCollapse() {
        #expect(NotchLayoutMath.morphCardness(easedProgress: 0.25, isExpanding: true) == 0.25)
        #expect(NotchLayoutMath.morphCardness(easedProgress: 0.25, isExpanding: false) == 0.75)
    }

    @Test func morphContentOpacityFadesInFastOnExpand() {
        // Still invisible at the very first beat, then ramps immediately —
        // a late fade reads as the content chasing the fast-growing window.
        #expect(NotchLayoutMath.morphContentOpacity(linearProgress: 0.05, isExpanding: true) == 0)
        // Fully opaque by 40% of the duration.
        #expect(NotchLayoutMath.morphContentOpacity(linearProgress: 0.40, isExpanding: true) == 1)
        #expect(NotchLayoutMath.morphContentOpacity(linearProgress: 1, isExpanding: true) == 1)
    }

    @Test func morphContentOpacityFadesOutEarlyOnCollapse() {
        #expect(NotchLayoutMath.morphContentOpacity(linearProgress: 0, isExpanding: false) == 1)
        // Gone within the first 45% so text never squashes against the
        // shrinking frame.
        #expect(NotchLayoutMath.morphContentOpacity(linearProgress: 0.45, isExpanding: false) == 0)
        #expect(NotchLayoutMath.morphContentOpacity(linearProgress: 1, isExpanding: false) == 0)
    }

    @Test func morphBezelOpacityStartsSolidAndClearsOnExpand() {
        // Solid bezel black at the click instant — indistinguishable from
        // the pill it replaces.
        #expect(NotchLayoutMath.morphBezelOpacity(linearProgress: 0, isExpanding: true) == 1)
        // Glass fully revealed by 30% of the duration.
        #expect(NotchLayoutMath.morphBezelOpacity(linearProgress: 0.30, isExpanding: true) == 0)
        #expect(NotchLayoutMath.morphBezelOpacity(linearProgress: 1, isExpanding: true) == 0)
    }

    @Test func morphBezelOpacityReturnsForPillHandoffOnCollapse() {
        #expect(NotchLayoutMath.morphBezelOpacity(linearProgress: 0, isExpanding: false) == 0)
        #expect(NotchLayoutMath.morphBezelOpacity(linearProgress: 0.60, isExpanding: false) == 0)
        // Solid bezel black again by the time the real pill reappears.
        #expect(NotchLayoutMath.morphBezelOpacity(linearProgress: 1, isExpanding: false) == 1)
    }

    @Test func interpolatedRectMorphsFromPillToCardThroughCenter() {
        let pill = CGRect(x: 100, y: 800, width: 200, height: 48)
        let card = CGRect(x: 0, y: 400, width: 400, height: 532)

        let start = NotchLayoutMath.interpolatedRect(from: pill, to: card, progress: 0)
        let end = NotchLayoutMath.interpolatedRect(from: pill, to: card, progress: 1)
        let mid = NotchLayoutMath.interpolatedRect(from: pill, to: card, progress: 0.5)

        #expect(start == pill)
        #expect(end == card)
        #expect(mid.width > pill.width)
        #expect(mid.width < card.width)
        #expect(mid.height > pill.height)
        #expect(mid.height < card.height)
        // Stays centered: both frames share the same midX.
        #expect(abs(mid.midX - pill.midX) < 0.01)
        #expect(abs(mid.midX - card.midX) < 0.01)
    }
}
