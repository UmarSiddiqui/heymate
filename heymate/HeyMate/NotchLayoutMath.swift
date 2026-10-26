//
//  NotchLayoutMath.swift
//  HeyMate
//
//  Pure layout math for the notch companion pill. No AppKit — everything
//  is unit-testable from screen geometry alone.
//
//  Never hardcode a model table. NSScreen is the source of truth:
//  height = safeAreaInsets.top, x = auxiliaryTopLeft.maxX,
//  width = auxiliaryTopRight.minX − auxiliaryTopLeft.maxX.
//  Those rects are in global screen coordinates (Apple). Values move with
//  the Mac and with display scaling (14″ class is typically 185×32 pt;
//  16″ is 220×38). The idle tab is the hardware cutout — same size, same
//  place, no peek. Frames are snapped to backing pixels before display.
//

import CoreGraphics
import SwiftUI
import Foundation

enum NotchLayoutMath {

    /// Extra width the tab takes when it has something to show on either
    /// side of the camera — hovering, a live voice interaction, or an
    /// ambient micro-app activity. Split evenly left/right, so 96 pt gives
    /// each peek slot 48 pt of screen that is NOT behind the camera
    /// housing. There is deliberately only one widened size: a third
    /// intermediate width made the tab look like it was hunting for a
    /// resting place every time state changed.
    nonisolated static let activeWidthBonus: CGFloat = 96

    /// Width available to ONE peek slot at the widened size. Used by tests
    /// and by callers that need to know whether a label will fit.
    nonisolated static var peekSlotWidth: CGFloat { activeWidthBonus / 2 }

    nonisolated static let compactUsageRingSize: CGFloat = 17
    nonisolated static let compactUsageSpacing: CGFloat = 5
    nonisolated static let compactUsageLimit = 3
    nonisolated static let compactUsageOverflowWidth: CGFloat = 26

    nonisolated static func compactUsageWidth(providerCount: Int) -> CGFloat {
        let count = min(max(providerCount, 0), compactUsageLimit)
        guard count > 0 else { return 0 }
        let rings = CGFloat(count) * compactUsageRingSize + CGFloat(count - 1) * compactUsageSpacing
        return rings + (providerCount > count ? compactUsageSpacing + compactUsageOverflowWidth : 0)
    }

    nonisolated static func pillWidthBonus(usageProviderCount: Int) -> CGFloat {
        // Each wing gets half the bonus. Keep the complete strip clear of
        // the camera housing and the rounded outside edge.
        max(activeWidthBonus, 2 * (compactUsageWidth(providerCount: usageProviderCount) + 12))
    }

    /// Bottom-corner radius of the collapsed tab. Matches the hardware
    /// cutout's continuous bottom corners (~8 pt); top stays square so the
    /// fill stays flush with the bezel.
    nonisolated static let pillCornerRadius: CGFloat = 8

    /// Bottom-corner radius of the expanded card.
    nonisolated static let cardCornerRadius: CGFloat = 24

    /// Radius of the concave "shoulders" where an expanded surface meets
    /// the menu bar. The top edge runs `cardShoulderRadius` past the body
    /// on each side and curves down into it, so the black reads as the
    /// camera housing flowing outward rather than a box hung below it.
    /// 10pt suits the 600×164 card under a 32–38pt housing: big enough to
    /// read as a fillet, small enough that the extra strip beside the body
    /// barely covers the menu bar.
    nonisolated static let cardShoulderRadius: CGFloat = 10

    /// Shoulder radius at this point of the morph. The pill has none (it is
    /// the hardware cutout), the card has the full fillet, and everything in
    /// between grows on the same corner clock as the bottom radius.
    nonisolated static func shoulderRadius(cardness: CGFloat) -> CGFloat {
        cardShoulderRadius * min(max(cardness, 0), 1)
    }

    /// How far a hanging surface's body sits in from its window's sides.
    /// Only surfaces that hang from a real camera housing get shoulders;
    /// the software-notch fallback floats under the menu bar, where a
    /// fillet would have nothing to flow out of.
    nonisolated static func shoulderInset(occludedTopInset: CGFloat) -> CGFloat {
        screenHasNotch(topSafeAreaInset: occludedTopInset) ? cardShoulderRadius : 0
    }

    /// The one silhouette every notch surface uses, in a top-left-origin,
    /// y-down space of `size`: a flat top edge flush with the screen, a
    /// concave quarter-circle shoulder of `shoulderRadius` at each top
    /// corner, straight sides `shoulderRadius` in from the edges, and
    /// circular bottom corners of `bottomRadius`. With a zero shoulder this
    /// is exactly the pill/card shape the morph already used.
    nonisolated static func silhouettePath(
        size: CGSize,
        shoulderRadius: CGFloat,
        bottomRadius: CGFloat
    ) -> CGPath {
        guard size.width > 0, size.height > 0 else { return CGMutablePath() }
        return CNSideNotchShape(edge: .top, cornerRadius: bottomRadius,
                               filletRadius: shoulderRadius, filletDepth: shoulderRadius)
            .path(in: CGRect(origin: .zero, size: size)).cgPath
    }

    /// A camera-width neck opens into the workspace below the menu bar.
    /// The neck starts at the pill's full width and forms on the same clock
    /// as the frame, so neither open nor close swaps silhouettes abruptly.
    nonisolated static func chatSilhouettePath(
        size: CGSize, notchWidth: CGFloat, neckHeight: CGFloat,
        cardness: CGFloat, bottomRadius: CGFloat
    ) -> CGPath {
        guard size.width > 0, size.height > 0 else { return CGMutablePath() }
        let progress = min(max(cardness, 0), 1)
        let width = size.width
        let height = size.height
        let neck = lerp(width, min(max(notchWidth, 0), width), progress)
        let top = min(max(neckHeight, 0) * progress, max(height - 1, 0))
        let side = (width - neck) / 2
        let flare = min(28 * progress, top, side)
        let bottom = min(max(bottomRadius, 0), width / 2, (height - top) / 2)
        let upper = min(bottom, max(side - flare, 0))
        let left = side
        let right = width - side
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: 0))
        path.addLine(to: CGPoint(x: right, y: 0))
        path.addLine(to: CGPoint(x: right, y: top - flare))
        let handle = flare * 0.5522847498
        path.addCurve(to: CGPoint(x: right + flare, y: top),
            control1: CGPoint(x: right, y: top - flare + handle),
            control2: CGPoint(x: right + flare - handle, y: top))
        path.addLine(to: CGPoint(x: width - upper, y: top))
        path.addQuadCurve(to: CGPoint(x: width, y: top + upper), control: CGPoint(x: width, y: top))
        path.addLine(to: CGPoint(x: width, y: height - bottom))
        path.addQuadCurve(to: CGPoint(x: width - bottom, y: height), control: CGPoint(x: width, y: height))
        path.addLine(to: CGPoint(x: bottom, y: height))
        path.addQuadCurve(to: CGPoint(x: 0, y: height - bottom), control: CGPoint(x: 0, y: height))
        path.addLine(to: CGPoint(x: 0, y: top + upper))
        path.addQuadCurve(to: CGPoint(x: upper, y: top), control: CGPoint(x: 0, y: top))
        path.addLine(to: CGPoint(x: left - flare, y: top))
        path.addCurve(to: CGPoint(x: left, y: top - flare),
            control1: CGPoint(x: left - flare + handle, y: top),
            control2: CGPoint(x: left, y: top - flare + handle))
        path.closeSubpath()
        return path
    }

    nonisolated static let chatNeckExtension: CGFloat = 10

    /// One gentle clock for workspace frame, neck and corners. Zero speed
    /// and acceleration at either end avoid a snap as the neck joins or
    /// releases the camera housing.
    nonisolated static func workspaceMorphProgress(_ time: CGFloat) -> CGFloat {
        let t = min(max(time, 0), 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    nonisolated static let workspaceExpandDuration: TimeInterval = 0.52
    nonisolated static let workspaceCollapseDuration: TimeInterval = 0.34

    /// Snappy: the frame lands early on the fast-attack swoosh curve and the
    /// content simply fades in over it. Real panel geometry moves on the
    /// display-link clock; content and corners settle with it.
    nonisolated static var expandDuration: TimeInterval { CNNotchMotion.unfoldSpring.settlingDuration }

    /// Closing is faster than opening, matching pointer intent.
    nonisolated static var collapseDuration: TimeInterval { CNNotchMotion.foldSpring.settlingDuration }

    /// Preview settles border radius over 180 ms while width/height continue
    /// their final 30 ms. Expressed separately so silhouette lands cleanly.
    nonisolated static let cornerSettleDuration: TimeInterval = 0.18

    /// How long the collapsed tab's peek slots blur and fade out before the
    /// card's frame starts growing. Short enough that a click still feels
    /// immediate, long enough to read as the pill "letting go".
    nonisolated static let pillYieldDuration: TimeInterval = 0.06

    /// Blur radius the peek slots reach as they yield. Zero: they just fade,
    /// so nothing pulls focus or reads as a zoom.
    nonisolated static let pillYieldBlur: CGFloat = 0

    /// Idle ↔ listening width change on the collapsed tab.
    nonisolated static let pillResizeDuration: TimeInterval = 0.22

    /// Extra window chrome around the hardware cutout so a 1.5pt theme rim
    /// (and its glow) is not clipped. Padding hangs left/right/below; the
    /// top stays flush with the screen edge — Apple's camera housing is
    /// measured from that edge via `safeAreaInsets.top`.
    nonisolated static let outlinePad: CGFloat = 6

    /// Halo stroke in points. 1.5pt is 3 physical pixels on a 2× panel, so
    /// the rim stays sharp after backing alignment.
    nonisolated static let outlineStrokeWidth: CGFloat = 1.5

    /// Reference housing height the 8pt bottom radius was measured against
    /// (14″-class `safeAreaInsets.top`). 16″ housings scale from this.
    nonisolated static let referenceNotchHeight: CGFloat = 32

    /// Bottom-corner radius for a housing of `height` points. 32pt → 8pt;
    /// 38pt → 9.5pt. Zero/negative heights keep the 14″ default.
    nonisolated static func pillCornerRadius(forHeight height: CGFloat) -> CGFloat {
        guard height > 0 else { return pillCornerRadius }
        return pillCornerRadius * (height / referenceNotchHeight)
    }

    /// Snap every edge of `rect` to the nearest backing pixel at `scale`
    /// (`NSScreen.backingScaleFactor`). Equivalent in spirit to AppKit's
    /// `backingAlignedRect(_:options: .alignAllEdgesNearest)` without
    /// importing AppKit into this testable math module.
    nonisolated static func backingAlignedRect(_ rect: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else { return rect }
        func snap(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded() / scale
        }
        let minX = snap(rect.minX)
        let maxX = snap(rect.maxX)
        let minY = snap(rect.minY)
        let maxY = snap(rect.maxY)
        return CGRect(
            x: minX,
            y: minY,
            width: max(maxX - minX, 0),
            height: max(maxY - minY, 0)
        )
    }

    /// Window frame that still *covers* the hardware notch exactly, with
    /// optional pad for the outline animation. Top edge never moves.
    nonisolated static func outlinePaddedFrame(
        hardware: CGRect,
        isOutlineEnabled: Bool
    ) -> CGRect {
        guard isOutlineEnabled else { return hardware }
        return CGRect(
            x: hardware.minX - outlinePad,
            y: hardware.minY - outlinePad,
            width: hardware.width + outlinePad * 2,
            height: hardware.height + outlinePad
        )
    }

    /// Expanded panel content width (the card that drops below the notch on
    /// hover/click). Two columns (composer, agents) and one tool bar; the
    /// final frame width never goes below the idle tab + margin so the card
    /// always visually contains the notch.
    nonisolated static let expandedWidth: CGFloat = 600

    /// Visible content height of the expanded card BELOW the camera housing.
    /// The panel's total frame height is `topSafeAreaInset + expandedHeight`.
    /// Wide, shallow Boring Notch-style surface: the composer beside two
    /// agent rows, over one bar of tools. Anything longer scrolls.
    nonisolated static let expandedHeight: CGFloat = 164

    /// Compact chat that drops from the notch on ctrl+command: wide enough
    /// for a composer + bubbles, short enough that it still reads as the
    /// camera housing growing rather than a full control panel.
    nonisolated static let compactChatWidth: CGFloat = 320

    /// Visible chat height BELOW the camera housing. Toolbar + a few
    /// messages + composer; the panel's total height is
    /// `topSafeAreaInset + compactChatHeight`.
    nonisolated static let compactChatHeight: CGFloat = 200

    /// Passive connector prompt. Wide enough for identity + three actions,
    /// shallow enough to read like a notification instead of the
    /// full HeyMate control surface.
    nonisolated static let connectorSuggestionWidth: CGFloat = 600

    /// Visible height below the camera housing. Identity, actions, and
    /// capability chips fit without compressing labels or controls.
    nonisolated static let connectorSuggestionHeight: CGFloat = 84

    /// Assumed menu-bar strip height when placing the software-notch fallback
    /// on a display that has no camera housing. Matches `NSStatusBar` thickness.
    nonisolated static let fallbackMenuBarHeight: CGFloat = 24

    /// Menu-bar strip height for a display with no camera housing, used as
    /// the height of a synthetic notch. The gap between the full and visible
    /// frames is the truth when it looks like a menu bar; a Dock docked to
    /// the top or an auto-hidden bar produces a gap that does not, so those
    /// fall back to the system status-bar thickness.
    nonisolated static func menuBarHeight(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        systemThickness: CGFloat
    ) -> CGFloat {
        let gap = screenFrame.maxY - visibleFrame.maxY
        if (20...40).contains(gap) { return gap }
        return systemThickness >= 20 ? systemThickness : fallbackMenuBarHeight
    }

    /// Idle tab width for the software-notch fallback (no hardware notch to hug).
    nonisolated static let fallbackIdleWidth: CGFloat = 148

    /// Collapsed-tab height on a display with no camera housing. Hardware
    /// idle height is always `safeAreaInsets.top` (no extra peek).
    nonisolated static let fallbackPillHeight: CGFloat = 22

    /// Frame for the expanded notch card: centered on the notch, flush with
    /// the screen top, hanging `expandedHeight` below the camera housing.
    /// Coordinates are AppKit GLOBAL points ready for NSPanel#setFrame.
    nonisolated static func expandedFrame(
        screenFrame: CGRect,
        topSafeAreaInset: CGFloat,
        auxiliaryTopLeftMaxX: CGFloat = 0,
        auxiliaryTopRightMinX: CGFloat = 0,
        contentWidth: CGFloat = expandedWidth,
        contentHeight: CGFloat = expandedHeight
    ) -> CGRect? {
        guard screenHasNotch(topSafeAreaInset: topSafeAreaInset) else { return nil }

        let idleWidth = idlePillWidth(
            leftMaxX: auxiliaryTopLeftMaxX,
            rightMinX: auxiliaryTopRightMinX
        )
        // The card must fully cover the notch it hangs from, even on models
        // with unusually wide camera housings. The shoulders sit outside
        // the body, so the window is one fillet wider on each side.
        let width = max(contentWidth, idleWidth + 40) + cardShoulderRadius * 2

        let height = topSafeAreaInset + contentHeight
        let notchCenterX = hardwareNotchCenterX(
            screenFrame: screenFrame,
            auxiliaryTopLeftMaxX: auxiliaryTopLeftMaxX,
            auxiliaryTopRightMinX: auxiliaryTopRightMinX
        )
        let x = notchCenterX - width / 2
        let y = screenFrame.maxY - height
        return fittedSurfaceFrame(CGRect(x: x, y: y, width: width, height: height), on: screenFrame)
    }

    /// Compact chat hanging from the camera housing. Same flush-top, centered
    /// rule as the full card, but sized to the smaller chat surface.
    nonisolated static func compactChatFrame(
        screenFrame: CGRect,
        topSafeAreaInset: CGFloat,
        auxiliaryTopLeftMaxX: CGFloat = 0,
        auxiliaryTopRightMinX: CGFloat = 0,
        contentWidth: CGFloat = compactChatWidth,
        contentHeight: CGFloat = compactChatHeight
    ) -> CGRect? {
        guard screenHasNotch(topSafeAreaInset: topSafeAreaInset) else { return nil }

        let idleWidth = idlePillWidth(
            leftMaxX: auxiliaryTopLeftMaxX,
            rightMinX: auxiliaryTopRightMinX
        )
        let width = max(contentWidth, idleWidth + 40) + cardShoulderRadius * 2
        let height = topSafeAreaInset + contentHeight
        let notchCenterX = hardwareNotchCenterX(
            screenFrame: screenFrame,
            auxiliaryTopLeftMaxX: auxiliaryTopLeftMaxX,
            auxiliaryTopRightMinX: auxiliaryTopRightMinX
        )
        let x = notchCenterX - width / 2
        let y = screenFrame.maxY - height
        return fittedSurfaceFrame(CGRect(x: x, y: y, width: width, height: height), on: screenFrame)
    }

    /// Compact auto-suggestion hanging from the hardware notch.
    nonisolated static func connectorSuggestionFrame(
        screenFrame: CGRect,
        topSafeAreaInset: CGFloat,
        auxiliaryTopLeftMaxX: CGFloat = 0,
        auxiliaryTopRightMinX: CGFloat = 0
    ) -> CGRect? {
        guard screenHasNotch(topSafeAreaInset: topSafeAreaInset) else { return nil }

        let idleWidth = idlePillWidth(
            leftMaxX: auxiliaryTopLeftMaxX,
            rightMinX: auxiliaryTopRightMinX
        )
        let width = max(connectorSuggestionWidth, idleWidth + 40) + cardShoulderRadius * 2
        let height = topSafeAreaInset + connectorSuggestionHeight
        let notchCenterX = hardwareNotchCenterX(
            screenFrame: screenFrame,
            auxiliaryTopLeftMaxX: auxiliaryTopLeftMaxX,
            auxiliaryTopRightMinX: auxiliaryTopRightMinX
        )
        return fittedSurfaceFrame(CGRect(
            x: notchCenterX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        ), on: screenFrame)
    }

    /// True when the display physically has a notch (top safe-area inset).
    nonisolated static func screenHasNotch(topSafeAreaInset: CGFloat) -> Bool {
        topSafeAreaInset >= 20
    }

    /// Raw hardware notch width in points: the gap between the right edge
    /// of the left auxiliary area and the left edge of the right one.
    /// Apple documents those rects in global screen coordinates.
    nonisolated static func hardwareNotchWidth(
        leftMaxX: CGFloat,
        rightMinX: CGFloat
    ) -> CGFloat {
        max(rightMinX - leftMaxX, 0)
    }

    /// Idle tab width: exactly the live hardware cutout. If the screen
    /// reports a notch height but no auxiliary gap (tests / odd setups),
    /// fall back to a typical 14″-class width rather than the full display.
    nonisolated static func idlePillWidth(
        leftMaxX: CGFloat,
        rightMinX: CGFloat
    ) -> CGFloat {
        let width = hardwareNotchWidth(leftMaxX: leftMaxX, rightMinX: rightMinX)
        return width > 0 ? width : fallbackIdleWidth
    }

    /// Horizontal center of the camera housing. Uses the auxiliary edges
    /// so an asymmetric menu bar (this 14″ panel is 665 / 850) still lines
    /// the tab up with the physical cutout instead of the display midline.
    nonisolated static func hardwareNotchCenterX(
        screenFrame: CGRect,
        auxiliaryTopLeftMaxX: CGFloat,
        auxiliaryTopRightMinX: CGFloat
    ) -> CGFloat {
        let width = hardwareNotchWidth(
            leftMaxX: auxiliaryTopLeftMaxX,
            rightMinX: auxiliaryTopRightMinX
        )
        guard width > 0 else { return screenFrame.midX }
        return (auxiliaryTopLeftMaxX + auxiliaryTopRightMinX) / 2
    }

    /// Frame for the companion tab on a notched display: the live hardware
    /// cutout (same origin, width, and height). No extra peek below it.
    /// Coordinates are AppKit GLOBAL points ready for NSPanel#setFrame.
    nonisolated static func pillFrame(
        screenFrame: CGRect,
        topSafeAreaInset: CGFloat,
        auxiliaryTopLeftMaxX: CGFloat = 0,
        auxiliaryTopRightMinX: CGFloat = 0,
        activeInteraction: Bool = false,
        usageProviderCount: Int = 0
    ) -> CGRect? {
        guard screenHasNotch(topSafeAreaInset: topSafeAreaInset) else { return nil }

        var width = idlePillWidth(
            leftMaxX: auxiliaryTopLeftMaxX,
            rightMinX: auxiliaryTopRightMinX
        )
        if activeInteraction {
            width += pillWidthBonus(usageProviderCount: usageProviderCount)
        }

        let height = topSafeAreaInset
        let x = hardwareNotchCenterX(
            screenFrame: screenFrame,
            auxiliaryTopLeftMaxX: auxiliaryTopLeftMaxX,
            auxiliaryTopRightMinX: auxiliaryTopRightMinX
        ) - width / 2
        let y = screenFrame.maxY - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Top-center tab on a display with no camera housing: hangs just below
    /// the menu bar so non-notched Macs still get the same control surface
    /// after the menu-bar panel is removed.
    nonisolated static func fallbackPillFrame(
        screenFrame: CGRect,
        activeInteraction: Bool = false,
        usageProviderCount: Int = 0
    ) -> CGRect {
        var width = fallbackIdleWidth
        if activeInteraction {
            width += pillWidthBonus(usageProviderCount: usageProviderCount)
        }
        let height = fallbackPillHeight
        let x = screenFrame.midX - width / 2
        let y = screenFrame.maxY - fallbackMenuBarHeight - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Expanded card for the software-notch fallback: same width/height as
    /// the hardware card, parked just below the menu bar.
    nonisolated static func fallbackExpandedFrame(
        screenFrame: CGRect,
        contentWidth: CGFloat = expandedWidth,
        contentHeight: CGFloat = expandedHeight
    ) -> CGRect {
        let width = contentWidth
        let height = contentHeight
        let x = screenFrame.midX - width / 2
        let y = screenFrame.maxY - fallbackMenuBarHeight - height
        return fittedSurfaceFrame(CGRect(x: x, y: y, width: width, height: height), on: screenFrame)
    }

    /// Compact chat for the software-notch fallback: same compact size as
    /// the hardware chat, parked just below the menu bar.
    nonisolated static func fallbackCompactChatFrame(
        screenFrame: CGRect,
        contentWidth: CGFloat = compactChatWidth,
        contentHeight: CGFloat = compactChatHeight
    ) -> CGRect {
        let width = contentWidth
        let height = contentHeight
        let x = screenFrame.midX - width / 2
        let y = screenFrame.maxY - fallbackMenuBarHeight - height
        return fittedSurfaceFrame(CGRect(x: x, y: y, width: width, height: height), on: screenFrame)
    }

    /// Software-notch placement for displays without camera housing.
    nonisolated static func fallbackConnectorSuggestionFrame(screenFrame: CGRect) -> CGRect {
        let width = connectorSuggestionWidth
        let height = connectorSuggestionHeight
        let x = screenFrame.midX - width / 2
        let y = screenFrame.maxY - fallbackMenuBarHeight - height
        return fittedSurfaceFrame(CGRect(x: x, y: y, width: width, height: height), on: screenFrame)
    }

    /// Keep controls reachable after display scaling or reconnecting a smaller
    /// monitor. Preserve the bezel/menu-bar anchor; shrink only as needed and
    /// shift horizontally only when the camera center would put an edge outside.
    nonisolated static func fittedSurfaceFrame(_ frame: CGRect, on screenFrame: CGRect) -> CGRect {
        let top = min(max(frame.maxY, screenFrame.minY), screenFrame.maxY)
        let width = min(max(frame.width, 0), max(screenFrame.width, 0))
        let height = min(max(frame.height, 0), max(top - screenFrame.minY, 0))
        let x = min(max(frame.midX - width / 2, screenFrame.minX), screenFrame.maxX - width)
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    // MARK: - Motion

    /// Cubic ease-out: the notch grows quickly then settles flush against
    /// the hardware edge. No overshoot — overshoot would misalign with the
    /// camera housing and break the "this is the bezel" illusion.
    nonisolated static func easeOutCubic(_ progress: CGFloat) -> CGFloat {
        let clampedProgress = min(max(progress, 0), 1)
        return 1 - pow(1 - clampedProgress, 3)
    }

    /// Exponential ease-out: attacks faster than any polynomial curve and
    /// is within 1% of the target by ~70% of the duration. Used for the
    /// pill → card expand — the window effectively lands mid-animation and
    /// the remaining frames are an imperceptible settle, which is what
    /// makes a click feel like the card was already there. No overshoot,
    /// same bezel-illusion constraint as `easeOutCubic`.
    nonisolated static func easeOutExpo(_ progress: CGFloat) -> CGFloat {
        let clampedProgress = min(max(progress, 0), 1)
        guard clampedProgress > 0 else { return 0 }
        guard clampedProgress < 1 else { return 1 }
        return 1 - pow(2, -10 * clampedProgress)
    }

    /// Cubic ease-in: barely moves at first, then accelerates. Used for the
    /// card → pill collapse so the card exits INTO the notch instead of
    /// slowing to a crawl over the desktop the way ease-out does.
    nonisolated static func easeInCubic(_ progress: CGFloat) -> CGFloat {
        let clampedProgress = min(max(progress, 0), 1)
        return clampedProgress * clampedProgress * clampedProgress
    }

    /// Portfolio preview motion curve: cubic-bezier(0.22, 0.75, 0.24, 1).
    /// CSS cubic-bezier maps elapsed time through the x control points, so a
    /// direct polynomial of y is incorrect. Binary search is stable, bounded,
    /// and cheap at one evaluation per display refresh.
    nonisolated static func swooshEase(_ progress: CGFloat) -> CGFloat {
        cubicBezier(progress, x1: 0.22, y1: 0.75, x2: 0.24, y2: 1)
    }

    /// CSS `ease`, used by the preview's 180 ms border-radius transition.
    nonisolated static func cssEase(_ progress: CGFloat) -> CGFloat {
        cubicBezier(progress, x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)
    }

    nonisolated static func cubicBezier(
        _ progress: CGFloat,
        x1: CGFloat,
        y1: CGFloat,
        x2: CGFloat,
        y2: CGFloat
    ) -> CGFloat {
        let clampedProgress = min(max(progress, 0), 1)
        guard clampedProgress > 0 else { return 0 }
        guard clampedProgress < 1 else { return 1 }

        func coordinate(_ parameter: CGFloat, _ first: CGFloat, _ second: CGFloat) -> CGFloat {
            let inverse = 1 - parameter
            return 3 * inverse * inverse * parameter * first
                + 3 * inverse * parameter * parameter * second
                + parameter * parameter * parameter
        }

        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for _ in 0..<14 {
            let midpoint = (lower + upper) / 2
            if coordinate(midpoint, x1, x2) < clampedProgress {
                lower = midpoint
            } else {
                upper = midpoint
            }
        }
        return coordinate((lower + upper) / 2, y1, y2)
    }

    nonisolated static func lerp(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
        start + (end - start) * progress
    }

    /// Interpolates two window frames. `easedProgress` is ALREADY eased
    /// (0…1 of distance covered) — the caller owns the curve so expand and
    /// collapse can use different easing shapes on the same clock.
    nonisolated static func interpolatedRect(
        from source: CGRect,
        to target: CGRect,
        easedProgress: CGFloat
    ) -> CGRect {
        CGRect(
            x: lerp(source.minX, target.minX, easedProgress),
            y: lerp(source.minY, target.minY, easedProgress),
            width: lerp(source.width, target.width, easedProgress),
            height: lerp(source.height, target.height, easedProgress)
        )
    }

    /// Peak extra height, as a fraction of the full pill → card distance,
    /// that the card reaches past its final height on open. Zero: the card
    /// lands flush with no bounce, which reads crisper than a stretch.
    nonisolated static let expandHeightOvershoot: CGFloat = 0

    /// Height progress for the open: the same swoosh as the width, plus a
    /// half-sine bump over the back 70% of the clock. It starts and ends at
    /// zero so the frame still lands exactly on the destination.
    nonisolated static func liquidOpenHeightProgress(linearProgress: CGFloat) -> CGFloat {
        let clampedProgress = min(max(linearProgress, 0), 1)
        let bumpTimeline = min(max((clampedProgress - 0.30) / 0.70, 0), 1)
        return swooshEase(clampedProgress)
            + expandHeightOvershoot * sin(.pi * bumpTimeline)
    }

    /// Interpolates two window frames with independent width and height
    /// progress. The TOP edge follows `widthProgress` and never overshoots:
    /// the card hangs from the bezel, so extra height can only grow
    /// downward. `heightProgress` may exceed 1 (the open's overshoot).
    nonisolated static func interpolatedRect(
        from source: CGRect,
        to target: CGRect,
        widthProgress: CGFloat,
        heightProgress: CGFloat
    ) -> CGRect {
        let top = lerp(source.maxY, target.maxY, widthProgress)
        let height = max(lerp(source.height, target.height, heightProgress), 0)
        return CGRect(
            x: lerp(source.minX, target.minX, widthProgress),
            y: top - height,
            width: lerp(source.width, target.width, widthProgress),
            height: height
        )
    }

    /// Interpolates two window frames with ease-out cubic. `progress` is
    /// linear 0…1 elapsed time; easing is applied inside.
    nonisolated static func interpolatedRect(
        from source: CGRect,
        to target: CGRect,
        progress: CGFloat
    ) -> CGRect {
        interpolatedRect(from: source, to: target, easedProgress: easeOutCubic(progress))
    }

    /// How "card-shaped" the surface is at this point in the morph: 1 = full
    /// card, 0 = pill. Drives the bottom corner radius so the shape reads as
    /// one continuous liquid surface instead of a full-radius card clipped
    /// by a pill-sized window. Radius uses the preview's independent 180 ms
    /// CSS-ease settle; collapse inverts it.
    nonisolated static func morphCardness(linearProgress: CGFloat, isExpanding: Bool) -> CGFloat {
        let settledProgress = min(max(CNNotchMotion.progress(linearProgress, expanding: isExpanding), 0), 1)
        return isExpanding ? settledProgress : 1 - settledProgress
    }

    /// Content fade locked to the morph clock, computed from LINEAR time
    /// rather than eased distance: legibility is a function of how long the
    /// window has been moving, not how far it has travelled.
    ///
    /// Expand: start the reveal once the silhouette is established, 15–60%
    /// of the clock, so the fade overlaps the frame growth instead of
    /// waiting for it. Collapse: remove content in the first 35%
    /// so text never visibly squashes against the shrinking frame.
    nonisolated static func morphContentOpacity(linearProgress: CGFloat, isExpanding: Bool) -> CGFloat {
        let clampedProgress = min(max(linearProgress, 0), 1)
        if isExpanding {
            return min(max((clampedProgress - 0.15) / 0.45, 0), 1)
        }
        return 1 - min(clampedProgress / 0.35, 1)
    }

    /// Blur radius of the content at the start (and end of collapse) of the
    /// reveal. Zero: a blur-to-sharp reveal reads as a camera zoom.
    nonisolated static let contentRevealMaxBlur: CGFloat = 0

    /// Scale the content grows from. 1: content never scales, it only
    /// fades, so opening the card has no zoom feel.
    nonisolated static let contentRevealMinScale: CGFloat = 1

    /// Blur and scale ride the content's own opacity, so all three settle
    /// together and every curve stays a function of the same clock.
    nonisolated static func morphContentBlur(contentOpacity: CGFloat) -> CGFloat {
        contentRevealMaxBlur * (1 - min(max(contentOpacity, 0), 1))
    }

    nonisolated static func morphContentScale(contentOpacity: CGFloat) -> CGFloat {
        lerp(contentRevealMinScale, 1, min(max(contentOpacity, 0), 1))
    }

    /// Bezel-black cover fade, locked to the same morph clock. Both the pill
    /// and the card are now opaque bezel black, so this no longer hides a
    /// colour change; it stays as the clock any future surface tint would
    /// have to cross-fade on.
    ///
    /// Expand: the cover crossfades out over the first 30% of the duration
    /// so the surface starts indistinguishable from the pill it replaces.
    /// Collapse: it returns over the last 40% so the shrinking window is
    /// solid bezel black again by the time the real pill reappears.
    nonisolated static func morphBezelOpacity(linearProgress: CGFloat, isExpanding: Bool) -> CGFloat {
        let clampedProgress = min(max(linearProgress, 0), 1)
        if isExpanding {
            return 1 - min(clampedProgress / 0.30, 1)
        }
        return min(max((clampedProgress - 0.60) / 0.40, 0), 1)
    }
}
