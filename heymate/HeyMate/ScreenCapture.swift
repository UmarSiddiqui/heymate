//
//  ScreenCapture.swift
//  HeyMate
//
//  Screenshots for a voice turn: every display (cursor display first) or
//  just the window the user is working in. HeyMate's own windows are left
//  out so the model sees the user's content, not the overlay.
//
//  Frames are in AppKit global coordinates (bottom-left origin), the same
//  space as NSEvent.mouseLocation and the overlay, so a point the model
//  names in the image maps straight back onto the screen.
//

import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct ScreenSnapshot {
    let imageData: Data
    /// How the model is told which image this is.
    let label: String
    /// The image to point into when the model doesn't say which.
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

enum ScreenCapture {
    enum Failure: LocalizedError {
        case noDisplay
        case nothingCaptured
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .noDisplay: return "No display available for capture"
            case .nothingCaptured: return "Failed to capture any screen"
            case .encodingFailed: return "Failed to encode the screenshot"
            }
        }
    }

    /// Longest edge of every screenshot. Enough for the model to read UI
    /// text, small enough to keep uploads and token counts down.
    private nonisolated static let longestEdge = 1280
    private nonisolated static let jpegQuality = 0.8

    /// Every connected display, the one under the cursor first. Displays are
    /// captured in parallel.
    static func allScreens() async throws -> [ScreenSnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else { throw Failure.noDisplay }

        let ownBundleID = Bundle.main.bundleIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ownBundleID }
        let mouse = NSEvent.mouseLocation
        let screensByID = Dictionary(NSScreen.screens.map { ($0.displayID, $0) }, uniquingKeysWith: { first, _ in first })

        // SCDisplay.frame is in Core Graphics space (top-left origin), which
        // disagrees with AppKit for every display but the primary one, so the
        // matching NSScreen's frame is used whenever there is one.
        let displays: [(display: SCDisplay, frame: CGRect, hasCursor: Bool)] = content.displays.map { display in
            let frame = screensByID[display.displayID]?.frame
                ?? CGRect(origin: display.frame.origin, size: CGSize(width: display.width, height: display.height))
            return (display, frame, frame.contains(mouse))
        }
        let ordered = displays.filter(\.hasCursor) + displays.filter { !$0.hasCursor }

        let images = try await withThrowingTaskGroup(of: (Int, CGImage, CGSize).self) { group in
            for (index, entry) in ordered.enumerated() {
                group.addTask {
                    let size = scaledSize(width: entry.display.width, height: entry.display.height)
                    let filter = SCContentFilter(display: entry.display, excludingWindows: ownWindows)
                    return (index, try await capture(filter, size: size), size)
                }
            }
            var results: [Int: (CGImage, CGSize)] = [:]
            for try await (index, image, size) in group { results[index] = (image, size) }
            return results
        }

        let snapshots: [ScreenSnapshot] = ordered.enumerated().compactMap { index, entry in
            guard let (image, size) = images[index], let jpeg = jpegData(from: image) else { return nil }
            return ScreenSnapshot(
                imageData: jpeg,
                label: label(forDisplayAt: index, of: ordered.count, hasCursor: entry.hasCursor),
                isCursorScreen: entry.hasCursor,
                displayWidthInPoints: Int(entry.frame.width),
                displayHeightInPoints: Int(entry.frame.height),
                displayFrame: entry.frame,
                screenshotWidthInPixels: Int(size.width),
                screenshotHeightInPixels: Int(size.height)
            )
        }
        guard !snapshots.isEmpty else { throw Failure.nothingCaptured }
        return snapshots
    }

    /// Only the frontmost window of the active app: a sharper, cheaper image
    /// without desktop clutter or a second monitor. Falls back to every
    /// screen when there is no such window (the desktop, or HeyMate itself
    /// in front), so choosing this can never leave Talk blind.
    static func focusedWindow() async throws -> [ScreenSnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else { throw Failure.noDisplay }

        let frontmost = NSWorkspace.shared.frontmostApplication
        let ownBundleID = Bundle.main.bundleIdentifier
        let window = content.windows.first { window in
            guard let bundleID = window.owningApplication?.bundleIdentifier,
                  bundleID != ownBundleID,
                  bundleID == frontmost?.bundleIdentifier else { return false }
            // Palettes and floating toolbars aren't where the user works.
            return window.isOnScreen && window.frame.width > 100 && window.frame.height > 100
        }
        guard let window else { return try await allScreens() }

        let width = Int(window.frame.width)
        let height = Int(window.frame.height)
        let size = scaledSize(width: width, height: height)
        let image = try await capture(SCContentFilter(desktopIndependentWindow: window), size: size)
        guard let jpeg = jpegData(from: image) else { throw Failure.encodingFailed }

        let appName = frontmost?.localizedName ?? "unknown app"
        let title = window.title ?? ""

        // Window frames come in Core Graphics space; flip against the primary
        // display. The model's coordinates are relative to this image, which
        // holds only the window, so the frame must be the window's own.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? CGFloat(height)
        let frame = CGRect(
            x: window.frame.minX,
            y: primaryHeight - window.frame.minY - CGFloat(height),
            width: CGFloat(width),
            height: CGFloat(height)
        )

        return [ScreenSnapshot(
            imageData: jpeg,
            label: title.isEmpty ? "focused window (\(appName))" : "focused window (\(appName) — \(title))",
            // The only image, so it is also where pointing lands, even when
            // the pointer rests outside the window.
            isCursorScreen: true,
            displayWidthInPoints: width,
            displayHeightInPoints: height,
            displayFrame: frame,
            screenshotWidthInPixels: Int(size.width),
            screenshotHeightInPixels: Int(size.height)
        )]
    }

    // MARK: - Helpers

    nonisolated static func scaledSize(width: Int, height: Int) -> CGSize {
        guard width > 0, height > 0 else { return CGSize(width: longestEdge, height: longestEdge) }
        let aspect = CGFloat(width) / CGFloat(height)
        return width >= height
            ? CGSize(width: longestEdge, height: Int(CGFloat(longestEdge) / aspect))
            : CGSize(width: Int(CGFloat(longestEdge) * aspect), height: longestEdge)
    }

    static func label(forDisplayAt index: Int, of count: Int, hasCursor: Bool) -> String {
        if count == 1 { return "user's screen (cursor is here)" }
        let position = "screen \(index + 1) of \(count)"
        return hasCursor
            ? "\(position) — cursor is on this screen (primary focus)"
            : "\(position) — secondary screen"
    }

    private nonisolated static func capture(_ filter: SCContentFilter, size: CGSize) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// ImageIO encodes straight from the CGImage, skipping the bitmap copy
    /// NSBitmapImageRep makes first.
    private nonisolated static func jpegData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
