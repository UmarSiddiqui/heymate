//
//  CompanionManager+ExternalControl.swift
//  HeyMate
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
            port: HeyMateExternalControlBridge.processPort
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
        case .listConnectorTools:
            // A job can start before the user has opened a chat, and until
            // then no connector session exists to list.
            await awaitConnectorActivation()
            return listExternalControlConnectorTools()
        case .callConnectorTool(let namespacedID, let argumentsJSON):
            return await callExternalControlConnectorTool(
                namespacedID: namespacedID,
                argumentsJSON: argumentsJSON
            )
        case .createMate(let name, let job):
            return createExternalControlMate(name: name, job: job)
        }
    }

    /// Creates a mate on behalf of a running job. The job's plan was already
    /// approved, so this does not ask again, but it never takes over the
    /// user's open chat and it refuses a name already in the roster rather
    /// than quietly renaming the mate the plan asked for.
    private func createExternalControlMate(name: String?, job: String) -> HeyMateExternalControlResponse {
        let existingNames = mateDirectory.mates.filter { !$0.archived }.map(\.name)
        let resolvedName = name ?? MateNameGenerator.name(for: job, existingNames: existingNames)
        if mateDirectory.mateStore.isNameTaken(resolvedName) {
            return .error(409, "A mate named \(resolvedName) already exists")
        }
        guard let mate = createMate(name: resolvedName, job: job, opensChat: false) else {
            return .error(500, "Could not create the mate")
        }
        // The folder is assigned after the mate is stored, so read it back.
        let folderPath = mateDirectory.mates.first(where: { $0.id == mate.id })?.folderPath
        return .ok([
            "created": true,
            "name": mate.name,
            "job": mate.job,
            "folder": folderPath ?? ""
        ])
    }

    // MARK: - Connector tools

    /// The live tool surface, described well enough for a child CLI to
    /// advertise it verbatim. The schema is passed through as the vendor
    /// wrote it; anything unparseable degrades to an empty object schema
    /// rather than dropping the tool, because a tool with a vague schema is
    /// still callable and a missing one is not.
    private func listExternalControlConnectorTools() -> HeyMateExternalControlResponse {
        let tools: [[String: Any]] = connectorRuntime.availableMCPTools
            .filter { isConnectorEnabledForChat($0.connectorID) }
            .filter { !Self.isWithheldFromTalk($0.tool.name) }
            .map { namespaced in
            let parsedSchema = (try? JSONSerialization.jsonObject(
                with: Data(namespaced.tool.inputSchemaJSON.utf8)
            )) as? [String: Any]
            return [
                "name": namespaced.id,
                "description": "[\(namespaced.connectorDisplayName)] \(namespaced.tool.description)",
                "inputSchema": parsedSchema ?? ["type": "object", "properties": [String: Any]()]
            ]
        }
        return .ok(["tools": tools])
    }

    /// Tools a Talk turn is not offered, whatever the connector exposes.
    ///
    /// Connection management is the sharp one. Asked about a connected app,
    /// the model would call it to "verify" the account before reading
    /// anything — inventing a session id to do it (`session_id: wind`), then
    /// reading the empty answer as proof the app was never connected and
    /// handing the user a sign-in link for an account that already works.
    /// HeyMate owns connecting apps in Settings → Integrations, so the model
    /// has no reason to hold that lever at all.
    ///
    /// The remote shells go for a different reason: a spoken question is not
    /// a mandate to run code on someone else's machine.
    nonisolated static func isWithheldFromTalk(_ toolName: String) -> Bool {
        withheldToolNames.contains(toolName.uppercased())
    }

    nonisolated static let withheldToolNames: Set<String> = [
        "COMPOSIO_MANAGE_CONNECTIONS",
        "COMPOSIO_REMOTE_BASH_TOOL",
        "COMPOSIO_REMOTE_WORKBENCH"
    ]

    /// Runs the call against the session `ConnectorRuntime` already holds —
    /// no second sign-in, no per-turn server spawn — behind the same approval
    /// policy a Talk turn uses.
    private func callExternalControlConnectorTool(
        namespacedID: String,
        argumentsJSON: String
    ) async -> HeyMateExternalControlResponse {
        await awaitConnectorActivation()
        guard let namespaced = connectorRuntime.availableMCPTools.first(where: { $0.id == namespacedID }),
              let connector = ConnectorCatalog.connector(withID: namespaced.connectorID) else {
            return .error(404, "No connected server provides \(namespacedID)")
        }
        // Withheld at the call as well as the listing: a name learned from
        // somewhere other than `tools/list` must not become a way in.
        guard !Self.isWithheldFromTalk(namespaced.tool.name) else {
            return .error(403, "\(namespaced.tool.name) is not available from a conversation.")
        }

        let result = await executeConnectorTalkTool(
            namespacedToolID: namespacedID,
            connectorIdentifier: namespaced.connectorID,
            connectorDisplayName: connector.displayName,
            maximumRisk: connector.maximumRisk,
            arguments: TalkToolCatalog.arguments(fromInputArgumentsJSON: argumentsJSON)
        )
        // A refused or failed tool is a fact the model should read and react
        // to, so it comes back as a 200 carrying `isError` rather than as an
        // HTTP failure the MCP server would have to invent wording for.
        return .ok(["text": result.text, "isError": result.isError])
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
            let captures = try await ScreenCapture.allScreens()
            let selectedCaptures: [ScreenSnapshot]
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
        // Silent mode is a promise HeyMate makes no sound, including when
        // another tool asks it to speak.
        if isSilentModeEnabled {
            return .accepted(["speaking": false, "silentMode": true, "textLength": text.count])
        }
        let client = Self.makeSpeakingClient(
            for: selectedSpeakProvider,
            workerBaseURL: workerBaseURLForDisplay
        )
        HeyMateExternalControlSpeech.activeClient?.stopPlayback()
        HeyMateExternalControlSpeech.activeClient = client
        Task { @MainActor in
            do {
                try await client.speakText(text)
            } catch {
                HeyMateLog.log("⚠️ HeyMate bridge speak failed: \(error.localizedDescription)")
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
