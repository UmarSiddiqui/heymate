//
//  CompanionManager+ExternalControl.swift
//  leanring-buddy
//
//  Overlay / TTS / screenshot handlers for the loopback control bridge.
//  Pointing reuses detectedElementScreenLocation so the existing buddy
//  choreography flies to the target. Never warps NSCursor or posts CGEvents.
//

import AppKit
import Foundation

@MainActor
private enum HeyMateExternalControlRuntime {
    static var server: HeyMateExternalControlBridgeServer?
}

@MainActor
private enum HeyMateExternalControlSpeech {
    static var activeClient: (any TTSClient)?
}

extension CompanionManager {

    func startExternalControlBridgeIfNeeded() {
        guard HeyMateExternalControlRuntime.server == nil else { return }
        let server = HeyMateExternalControlBridgeServer(
            port: HeyMateExternalControlBridge.resolvedPort()
        ) { [weak self] command in
            guard let self else {
                return .error(503, "HeyMate is not ready")
            }
            return await self.handleExternalControlCommand(command)
        }
        HeyMateExternalControlRuntime.server = server
        server.start()
    }

    func stopExternalControlBridge() {
        HeyMateExternalControlRuntime.server?.stop()
        HeyMateExternalControlRuntime.server = nil
        HeyMateExternalControlSpeech.activeClient?.stopPlayback()
        HeyMateExternalControlSpeech.activeClient = nil
    }

    private func handleExternalControlCommand(
        _ command: HeyMateExternalControlCommand
    ) async -> HeyMateExternalControlResponse {
        switch command {
        case .health:
            return .ok(["service": "heymate"])
        case .showCursor(let point, let caption, let duration):
            let displayed = showExternalControlCursor(at: point, caption: caption)
            return .ok([
                "displayed": "cursor",
                "x": displayed.point.x,
                "y": displayed.point.y,
                "durationMs": Int(duration * 1000)
            ])
        case .showCaption(let text, let point, let duration):
            let resolvedPoint = point ?? NSEvent.mouseLocation
            let displayed = showExternalControlCursor(at: resolvedPoint, caption: text)
            return .ok([
                "displayed": "caption",
                "x": displayed.point.x,
                "y": displayed.point.y,
                "durationMs": Int(duration * 1000)
            ])
        case .captureScreenshot(let focused):
            return await captureExternalControlScreenshots(focused: focused)
        case .speak(let text):
            return speakExternalControlText(text)
        case .clear:
            clearDetectedElementLocation()
            return .ok(["cleared": true])
        }
    }

    @discardableResult
    private func showExternalControlCursor(
        at point: CGPoint,
        caption: String?
    ) -> (point: CGPoint, displayFrame: CGRect) {
        let clamped = Self.clampedExternalCursorPoint(point)
        ensureOverlayVisibleForExternalPointing()
        detectedElementScreenLocation = clamped.point
        detectedElementDisplayFrame = clamped.displayFrame
        let trimmedCaption = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        detectedElementBubbleText = (trimmedCaption?.isEmpty == false) ? trimmedCaption : nil
        return clamped
    }

    private func ensureOverlayVisibleForExternalPointing() {
        guard !overlayWindowManager.isShowingOverlay() else { return }
        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
    }

    private func captureExternalControlScreenshots(focused: Bool) async -> HeyMateExternalControlResponse {
        let frontmostBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if ExcludedApps.isCurrentlyExcluded(bundleId: frontmostBundleId) {
            return .error(
                403,
                "Frontmost app is excluded from screen capture"
            )
        }

        do {
            CaptureAudit.shared.recordCaptureAttempt(context: CaptureAudit.Context.externalControlScreenshot)
            let captures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            let selectedCaptures: [CompanionScreenCapture]
            if focused {
                let cursorCaptures = captures.filter(\.isCursorScreen)
                selectedCaptures = cursorCaptures.isEmpty ? captures : cursorCaptures
            } else {
                selectedCaptures = captures
            }

            let rootDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("HeyMateExternalControlScreenshots", isDirectory: true)
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

            let now = Date()
            if let oldEntries = try? FileManager.default.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) {
                for entry in oldEntries {
                    let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                    if let modifiedAt = values?.contentModificationDate,
                       now.timeIntervalSince(modifiedAt) > 600 {
                        try? FileManager.default.removeItem(at: entry)
                    }
                }
            }

            let directory = rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let screens: [[String: Any]] = try selectedCaptures.enumerated().map { index, capture in
                let fileURL = directory.appendingPathComponent("screen-\(timestamp)-\(index + 1).jpg")
                try capture.imageData.write(to: fileURL, options: .atomic)
                return [
                    "label": capture.label,
                    "path": fileURL.path,
                    "isCursorScreen": capture.isCursorScreen,
                    "displayFrame": [
                        "x": capture.displayFrame.origin.x,
                        "y": capture.displayFrame.origin.y,
                        "width": capture.displayFrame.width,
                        "height": capture.displayFrame.height
                    ],
                    "displayWidthInPoints": capture.displayWidthInPoints,
                    "displayHeightInPoints": capture.displayHeightInPoints,
                    "screenshotWidthInPixels": capture.screenshotWidthInPixels,
                    "screenshotHeightInPixels": capture.screenshotHeightInPixels
                ]
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(nanoseconds: 600_000_000_000)
                try? FileManager.default.removeItem(at: directory)
            }
            return .ok(["screens": screens, "count": screens.count, "focused": focused])
        } catch {
            return .error(500, error.localizedDescription)
        }
    }

    private func speakExternalControlText(_ text: String) -> HeyMateExternalControlResponse {
        let client: any TTSClient
        switch selectedSpeakProvider {
        case .macOS:
            client = MacOSSpeechSynthesizerClient()
        case .elevenLabs:
            client = ElevenLabsTTSClient(proxyURL: "\(workerBaseURLForDisplay)/tts")
        }
        HeyMateExternalControlSpeech.activeClient?.stopPlayback()
        HeyMateExternalControlSpeech.activeClient = client
        Task { @MainActor in
            do {
                try await client.speakText(text)
            } catch {
                print("⚠️ HeyMate bridge speak failed: \(error.localizedDescription)")
            }
        }
        return .accepted(["speaking": true, "textLength": text.count])
    }

    private static func clampedExternalCursorPoint(_ point: CGPoint) -> (point: CGPoint, displayFrame: CGRect) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return (point, CGRect(origin: point, size: .zero))
        }

        let screen = screens.first(where: { $0.frame.contains(point) })
            ?? screens.min { lhs, rhs in
                Self.distanceSquared(from: point, to: lhs.frame)
                    < Self.distanceSquared(from: point, to: rhs.frame)
            }
            ?? NSScreen.main
            ?? screens[0]
        let frame = screen.frame
        let clamped = CGPoint(
            x: min(max(point.x, frame.minX), max(frame.minX, frame.maxX - 1)),
            y: min(max(point.y, frame.minY), max(frame.minY, frame.maxY - 1))
        )
        return (clamped, frame)
    }

    private static func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let deltaX = point.x - clampedX
        let deltaY = point.y - clampedY
        return deltaX * deltaX + deltaY * deltaY
    }
}
