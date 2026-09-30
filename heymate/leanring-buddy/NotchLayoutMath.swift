//
//  NotchLayoutMath.swift
//  leanring-buddy
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

    /// Bottom-corner radius of the collapsed tab. Matches the hardware
    /// cutout's continuous bottom corners (~8 pt); top stays square so the
    /// fill stays flush with the bezel.
    nonisolated static let pillCornerRadius: CGFloat = 8

    /// Bottom-corner radius of the expanded card.
    nonisolated static let cardCornerRadius: CGFloat = 24

    /// Boring Notch-style relaxed spring cadence. Real panel geometry still
    /// moves on the display-link clock; content and corners settle with it.
    nonisolated static let expandDuration: TimeInterval = 0.38

    /// Closing is slightly faster than opening, matching pointer intent.
    nonisolated static let collapseDuration: TimeInterval = 0.30

    /// Preview settles border radius over 180 ms while width/height continue
    /// their final 30 ms. Expressed separately so silhouette lands cleanly.
    nonisolated static let cornerSettleDuration: TimeInterval = 0.18

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
    /// hover/click). Wide enough for the Home tab's controls; the final
    /// frame width never goes below the idle tab + margin so the card always
    /// visually contains the notch.
    nonisolated static let expandedWidth: CGFloat = 680

    /// Visible content height of the expanded card BELOW the camera housing.
    /// The panel's total frame height is `topSafeAreaInset + expandedHeight`.
    /// Wide, shallow Boring Notch-style surface. Dense tools lay out in
    /// columns instead of turning the notch into a vertical popover.
    nonisolated static let expandedHeight: CGFloat = 250

    /// Compact chat that drops from the notch on ctrl+command: wide enough
    /// for a composer + bubbles, short enough that it still reads as the
    /// camera housing growing rather than a full control panel.
    nonisolated static let compactChatWidth: CGFloat = 320

    /// Visible chat height BELOW the camera housing. Toolbar + a few
    /// messages + composer; the panel's total height is
    /// `topSafeAreaInset + compactChatHeight`.
    nonisolated static let compactChatHeight: CGFloat = 200

    /// Passive connector prompt. Wide enough for identity + three actions,
    /// shallow enough to read like a HeyClicky notification instead of the
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
        // with unusually wide camera housings.
        let width = max(contentWidth, idleWidth + 40)

        let height = topSafeAreaInset + contentHeight
        let notchCenterX = hardwareNotchCenterX(
            screenFrame: screenFrame,
            auxiliaryTopLeftMaxX: auxiliaryTopLeftMaxX,
            auxiliaryTopRightMinX: auxiliaryTopRightMinX
        )
        let x = notchCenterX - width / 2
        let y = screenFrame.maxY - height
        return CGRect(x: x, y: y, width: width, height: height)
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
        let width = max(contentWidth, idleWidth + 40)
        let height = topSafeAreaInset + contentHeight
        let notchCenterX = hardwareNotchCenterX(
            screenFrame: screenFrame,
            auxiliaryTopLeftMaxX: auxiliaryTopLeftMaxX,
            auxiliaryTopRightMinX: auxiliaryTopRightMinX
        )
        let x = notchCenterX - width / 2
        let y = screenFrame.maxY - height
        return CGRect(x: x, y: y, width: width, height: height)
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
        let width = max(connectorSuggestionWidth, idleWidth + 40)
        let height = topSafeAreaInset + connectorSuggestionHeight
        let notchCenterX = hardwareNotchCenterX(
            screenFrame: screenFrame,
            auxiliaryTopLeftMaxX: auxiliaryTopLeftMaxX,
            auxiliaryTopRightMinX: auxiliaryTopRightMinX
        )
        return CGRect(
            x: notchCenterX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
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
        activeInteraction: Bool = false
    ) -> CGRect? {
        guard screenHasNotch(topSafeAreaInset: topSafeAreaInset) else { return nil }

        var width = idlePillWidth(
            leftMaxX: auxiliaryTopLeftMaxX,
            rightMinX: auxiliaryTopRightMinX
        )
        if activeInteraction {
            width += activeWidthBonus
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
        activeInteraction: Bool = false
    ) -> CGRect {
        var width = fallbackIdleWidth
        if activeInteraction {
            width += activeWidthBonus
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
        return CGRect(x: x, y: y, width: width, height: height)
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
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Software-notch placement for displays without camera housing.
    nonisolated static func fallbackConnectorSuggestionFrame(screenFrame: CGRect) -> CGRect {
        let width = connectorSuggestionWidth
        let height = connectorSuggestionHeight
        let x = screenFrame.midX - width / 2
        let y = screenFrame.maxY - fallbackMenuBarHeight - height
        return CGRect(x: x, y: y, width: width, height: height)
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
        let transitionDuration = isExpanding ? expandDuration : collapseDuration
        let cornerTimeline = min(
            linearProgress * CGFloat(transitionDuration / cornerSettleDuration),
            1
        )
        let settledProgress = cssEase(cornerTimeline)
        return isExpanding ? settledProgress : 1 - settledProgress
    }

    /// Content fade locked to the morph clock, computed from LINEAR time
    /// rather than eased distance: legibility is a function of how long the
    /// window has been moving, not how far it has travelled.
    ///
    /// Expand: hold content until the silhouette is established, then reveal
    /// from 42–85% of the clock. Collapse: remove content in the first 45% so
    /// text never visibly squashes against the shrinking frame.
    nonisolated static func morphContentOpacity(linearProgress: CGFloat, isExpanding: Bool) -> CGFloat {
        let clampedProgress = min(max(linearProgress, 0), 1)
        if isExpanding {
            return min(max((clampedProgress - 0.42) / 0.43, 0), 1)
        }
        return 1 - min(clampedProgress / 0.45, 1)
    }

    /// Bezel-black cover fade, locked to the same morph clock. The pill is
    /// solid black (it must merge with the camera bezel); the card is
    /// translucent glass with a 72% black scrim, which is visibly lighter.
    /// Without this cover the click flashes black → gray glass → grow, and
    /// the card reads as a different object than the notch that was clicked.
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
