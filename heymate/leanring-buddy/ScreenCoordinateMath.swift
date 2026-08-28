//
//  ScreenCoordinateMath.swift
//  leanring-buddy
//
//  Pure multi-display coordinate conversion between screenshot pixel space
//  (what vision models see: top-left origin, y increases downward) and
//  macOS global AppKit space (bottom-left origin, y increases upward,
//  possibly negative display origins). Extracted from CompanionManager so
//  every transform can be unit-tested against known corner points.
//

import CoreGraphics

/// Geometry snapshot for one captured display — everything needed to convert
/// model-returned screenshot pixel coordinates into global AppKit points.
struct DisplayGeometry {
    let screenshotPixelWidth: Int
    let screenshotPixelHeight: Int
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    /// Global AppKit frame of the display. The origin may be negative for
    /// displays positioned to the left of or above the main display.
    let displayFrame: CGRect

    var displayWidth: CGFloat { CGFloat(displayWidthInPoints) }
    var displayHeight: CGFloat { CGFloat(displayHeightInPoints) }
}

enum ScreenCoordinateMath {

    /// Converts a point in screenshot pixel space (top-left origin, y down)
    /// into macOS global AppKit coordinates:
    ///
    /// 1. clamp the input into the captured image bounds;
    /// 2. scale from screenshot pixels to display points (handles Retina);
    /// 3. flip y from top-left origin to bottom-left origin;
    /// 4. translate by the display frame origin (handles negative origins).
    static func globalAppKitPoint(
        fromScreenshotPixelPoint pixelPoint: CGPoint,
        geometry: DisplayGeometry
    ) -> CGPoint {
        let screenshotWidth = CGFloat(geometry.screenshotPixelWidth)
        let screenshotHeight = CGFloat(geometry.screenshotPixelHeight)

        // Clamp to the screenshot coordinate space — model output can be
        // slightly out of bounds and must never land off-screen.
        let clampedX = max(0, min(pixelPoint.x, screenshotWidth))
        let clampedY = max(0, min(pixelPoint.y, screenshotHeight))

        // Scale from screenshot pixels to display points
        let displayLocalX = clampedX * (geometry.displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (geometry.displayHeight / screenshotHeight)

        // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
        let appKitY = geometry.displayHeight - displayLocalY

        // Convert display-local coords to global screen coords
        return CGPoint(
            x: displayLocalX + geometry.displayFrame.origin.x,
            y: appKitY + geometry.displayFrame.origin.y
        )
    }
}
