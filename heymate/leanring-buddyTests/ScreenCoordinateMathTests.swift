//
//  ScreenCoordinateMathTests.swift
//  leanring-buddyTests
//
//  Unit tests for the screenshot-pixel → AppKit-global coordinate transform.
//  These pin down the corner behavior required for accurate multi-monitor
//  pointing: top-left origin conversion, Retina scaling, negative display
//  origins, and out-of-bounds clamping.
//

import CoreGraphics
import Testing
@testable import HeyMate

@MainActor
struct ScreenCoordinateMathTests {

    // MARK: - Fixtures

    /// A 1512×982 pt display at the global origin with a 2x Retina capture
    /// (3024×1964 px) — the typical built-in laptop display.
    private static let retinaMainDisplay = DisplayGeometry(
        screenshotPixelWidth: 3024,
        screenshotPixelHeight: 1964,
        displayWidthInPoints: 1512,
        displayHeightInPoints: 982,
        displayFrame: CGRect(x: 0, y: 0, width: 1512, height: 982)
    )

    /// A non-Retina 1920×1080 pt display placed to the LEFT of the main
    /// display, so its global origin x is -1920.
    private static let nonRetinaLeftDisplay = DisplayGeometry(
        screenshotPixelWidth: 1920,
        screenshotPixelHeight: 1080,
        displayWidthInPoints: 1920,
        displayHeightInPoints: 1080,
        displayFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    )

    /// A 2x Retina display ABOVE the main display — global origin y is
    /// positive in AppKit terms (its bottom edge sits at y=982).
    private static let retinaAboveDisplay = DisplayGeometry(
        screenshotPixelWidth: 2560,
        screenshotPixelHeight: 1440,
        displayWidthInPoints: 1280,
        displayHeightInPoints: 720,
        displayFrame: CGRect(x: 0, y: 982, width: 1280, height: 720)
    )

    private static func assertClose(
        _ a: CGPoint,
        _ b: CGPoint,
        accuracy: CGFloat = 0.001,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(a.x - b.x) < accuracy, sourceLocation: sourceLocation)
        #expect(abs(a.y - b.y) < accuracy, sourceLocation: sourceLocation)
    }

    // MARK: - Corner mapping (top-left origin ↔ bottom-left origin)

    @Test func topLeftScreenshotPixelMapsToTopLeftGlobalPoint() {
        // Screenshot (0,0) is the TOP-left; AppKit's top-left of this frame
        // is (minX, maxY) = (0, 982).
        let result = ScreenCoordinateMath.globalAppKitPoint(
            fromScreenshotPixelPoint: CGPoint(x: 0, y: 0),
            geometry: Self.retinaMainDisplay
        )
        Self.assertClose(result, CGPoint(x: 0, y: 982))
    }

    @Test func bottomRightScreenshotPixelMapsToBottomLeftOriginGlobalPoint() {
        // Screenshot bottom-right is AppKit's global origin of the display.
        let result = ScreenCoordinateMath.globalAppKitPoint(
            fromScreenshotPixelPoint: CGPoint(x: 3024, y: 1964),
            geometry: Self.retinaMainDisplay
        )
        Self.assertClose(result, CGPoint(x: 1512, y: 0))
    }

    @Test func topRightAndBottomLeftCornersMapCorrectly() {
        let topRight = ScreenCoordinateMath.globalAppKitPoint(
            fromScreenshotPixelPoint: CGPoint(x: 3024, y: 0),
            geometry: Self.retinaMainDisplay
        )
        Self.assertClose(topRight, CGPoint(x: 1512, y: 982))

        let bottomLeft = ScreenCoordinateMath.globalAppKitPoint(
            fromScreenshotPixelPoint: CGPoint(x: 0, y: 1964),
            geometry: Self.retinaMainDisplay
        )
        Self.assertClose(bottomLeft, CGPoint(x: 0, y: 0))
    }

    @Test func centerPixelMapsToCenterPoint() {
        let result = ScreenCoordinateMath.globalAppKitPoint(
            fromScreenshotPixelPoint: CGPoint(x: 1512, y: 982),
            geometry: Self.retinaMainDisplay
        )
        Self.assertClose(result, CGPoint(x: 756, y: 491))
    }

    // MARK: - Retina scale handling

    @Test func retinaPixelsScaleDownToDisplayPoints() {
        // One quarter into the image on both axes must land one quarter
        // into the display in points, regardless of the pixel scale factor.
        let result = ScreenCoordinateMath.globalAppKitPoint(
            fromScreenshotPixelPoint: CGPoint(x: 756, y: 491),
            geometry: Self.retinaMainDisplay
        )
        Self.assertClose(result, CGPoint(x: 378, y: 736.5))
    }

    @Test func nonRetinaCaptureMapsOneToOne() {
        let result = ScreenCoordinateMath.globalAppKitPoint(
            fromScreenshotPixelPoint: CGPoint(x: 960, y: 540),
            geometry: Self.nonRetinaLeftDisplay
        )
        Self.assertClose(result, CGPoint(x: -960, y: 540))
    }

    // MARK: - Negative / offset display origins

    @Test func negativeOriginDisplayShiftsGlobalXByFrameOrigin() {
        // Left-of-main display: global x values are all negative.
        let result = ScreenCoordinateMath.globalAppKitPoint(
            fromScreenshotPixelPoint: CGPoint(x: 100, y: 200),
            geometry: Self.nonRetinaLeftDisplay
        )
        Self.assertClose(result, CGPoint(x: -1820, y: 880))
    }

    @Test func displayAboveMainShiftsGlobalYByFrameOrigin() {
        // Display stacked above the main display: its bottom-left corner is
        // at global y=982, so screenshot bottom maps there.
        let result = ScreenCoordinateMath.globalAppKitPoint(
            fromScreenshotPixelPoint: CGPoint(x: 1280, y: 1440),
            geometry: Self.retinaAboveDisplay
        )
        Self.assertClose(result, CGPoint(x: 640, y: 982))
    }

    // MARK: - Clamping

    @Test func outOfBoundsNegativeInputClampsToZero() {
        let result = ScreenCoordinateMath.globalAppKitPoint(
            fromScreenshotPixelPoint: CGPoint(x: -50, y: -50),
            geometry: Self.retinaMainDisplay
        )
        Self.assertClose(result, CGPoint(x: 0, y: 982))
    }

    @Test func outOfBoundsLargeInputClampsToImageBounds() {
        let result = ScreenCoordinateMath.globalAppKitPoint(
            fromScreenshotPixelPoint: CGPoint(x: 5000, y: 4000),
            geometry: Self.retinaMainDisplay
        )
        Self.assertClose(result, CGPoint(x: 1512, y: 0))
    }
}
