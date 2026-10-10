//
//  CompanionManager+LocalControl.swift
//  HeyMate
//
//  Carries out local control commands. Pointing goes through the same
//  detected-element state a reply uses, so the floating cursor flies there
//  exactly as it would for an answer. Nothing here moves the real pointer
//  or synthesizes input.
//

import AppKit
import Foundation

@MainActor
private enum LocalControlState {
    static var server: LocalControlServer?
    /// The voice speaking for a control request, so a new one cuts it off.
    static var speaker: (any TTSClient)?
}

extension CompanionManager {
    func startExternalControlBridgeIfNeeded() {
        guard LocalControlState.server == nil else { return }
        let server = LocalControlServer { [weak self] command in
            guard let self else { return .error(503, "HeyMate is not ready") }
            return await self.perform(command)
        }
        LocalControlState.server = server
        server.start()
    }

    func stopExternalControlBridge() {
        LocalControlState.server?.stop()
        LocalControlState.server = nil
        LocalControlState.speaker?.stopPlayback()
        LocalControlState.speaker = nil
    }

    private func perform(_ command: LocalControlCommand) async -> LocalControlResponse {
        switch command {
        case .health:
            return .ok(["service": "heymate"])
        case .showCursor(let point, let caption, let duration):
            return .ok(pointCursor(at: point, label: caption, duration: duration, kind: "cursor"))
        case .showCaption(let text, let point, let duration):
            return .ok(pointCursor(at: point ?? NSEvent.mouseLocation, label: text, duration: duration, kind: "caption"))
        case .captureScreenshot(let focused):
            return await saveScreenshots(focusedOnly: focused)
        case .speak(let text):
            return speak(text)
        case .clear:
            clearPointingTarget()
            return .ok(["cleared": true])
        case .listConnectorTools:
            // A job can start before any chat has opened a connector session.
            await awaitConnectorActivation()
            return .ok(["tools": connectorToolDescriptions()])
        case .callConnectorTool(let namespacedID, let argumentsJSON):
            return await callConnectorTool(namespacedID, argumentsJSON: argumentsJSON)
        case .createMate(let name, let job):
            return createMateForJob(name: name, job: job)
        }
    }

    // MARK: - Pointing

    private func pointCursor(at point: CGPoint, label: String?, duration: TimeInterval, kind: String) -> [String: Any] {
        let (target, display) = Self.nearestOnScreenPoint(to: point)
        if !overlayWindowManager.isShowingOverlay() {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        }
        let label = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        pointingTarget = CursorPointingTarget(location: target, displayFrame: display, caption: label?.isEmpty == false ? label : nil)
        return ["displayed": kind, "x": target.x, "y": target.y, "durationMs": Int(duration * 1000)]
    }

    /// The point moved onto the screen that contains it, or else the screen
    /// nearest to it, kept one point inside that screen's edges.
    static func nearestOnScreenPoint(to point: CGPoint) -> (point: CGPoint, display: CGRect) {
        func clamp(_ point: CGPoint, into rect: CGRect) -> CGPoint {
            CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
        }
        func distanceSquared(_ rect: CGRect) -> CGFloat {
            let nearest = clamp(point, into: rect)
            return (point.x - nearest.x) * (point.x - nearest.x) + (point.y - nearest.y) * (point.y - nearest.y)
        }
        let screens = NSScreen.screens.map(\.frame)
        guard let display = screens.first(where: { $0.contains(point) }) ?? screens.min(by: { distanceSquared($0) < distanceSquared($1) })
        else { return (point, CGRect(origin: point, size: .zero)) }
        let inner = CGRect(
            x: display.minX, y: display.minY,
            width: max(0, display.width - 1), height: max(0, display.height - 1)
        )
        return (clamp(point, into: inner), display)
    }

    // MARK: - Screenshots

    /// Saves screenshots to a private temporary folder and returns their
    /// paths and geometry. Each folder is deleted after ten minutes, and
    /// older ones left by an earlier launch are swept first.
    private func saveScreenshots(focusedOnly: Bool) async -> LocalControlResponse {
        if ExcludedApps.isCurrentlyExcluded(bundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
            return .error(403, "Frontmost app is excluded from screen capture")
        }
        do {
            CaptureAudit.shared.recordCaptureAttempt(context: CaptureAudit.Context.externalControlScreenshot)
            let all = try await ScreenCapture.allScreens()
            let cursorScreens = all.filter(\.isCursorScreen)
            let selected = focusedOnly && !cursorScreens.isEmpty ? cursorScreens : all
            let screens = try await Self.writeScreenshots(selected)
            return .ok(["screens": screens, "count": screens.count, "focused": focusedOnly])
        } catch {
            return .error(500, error.localizedDescription)
        }
    }

    private static let screenshotLifetime: TimeInterval = 600

    /// File work happens off the main thread.
    @concurrent
    private nonisolated static func writeScreenshots(_ snapshots: [ScreenSnapshot]) async throws -> [[String: Any]] {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("HeyMateExternalControlScreenshots", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)

        let staleBefore = Date().addingTimeInterval(-screenshotLifetime)
        let existing = (try? files.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        for entry in existing {
            if let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified < staleBefore {
                try? files.removeItem(at: entry)
            }
        }

        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let described: [[String: Any]] = try snapshots.enumerated().map { index, snapshot in
            let file = folder.appendingPathComponent("screen-\(stamp)-\(index + 1).jpg")
            try snapshot.imageData.write(to: file, options: .atomic)
            let frame = snapshot.displayFrame
            return [
                "label": snapshot.label,
                "path": file.path,
                "isCursorScreen": snapshot.isCursorScreen,
                "displayFrame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height],
                "displayWidthInPoints": snapshot.displayWidthInPoints,
                "displayHeightInPoints": snapshot.displayHeightInPoints,
                "screenshotWidthInPixels": snapshot.screenshotWidthInPixels,
                "screenshotHeightInPixels": snapshot.screenshotHeightInPixels,
            ]
        }
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(screenshotLifetime))
            try? FileManager.default.removeItem(at: folder)
        }
        return described
    }

    // MARK: - Speech

    /// Speaks with the voice chosen in Settings, cutting off the previous
    /// request. Silent mode means no sound, whoever asks.
    private func speak(_ text: String) -> LocalControlResponse {
        if isSilentModeEnabled {
            return .accepted(["speaking": false, "silentMode": true, "textLength": text.count])
        }
        let speaker = Self.makeSpeakingClient(for: selectedSpeakProvider, workerBaseURL: workerBaseURLForDisplay)
        LocalControlState.speaker?.stopPlayback()
        LocalControlState.speaker = speaker
        Task {
            do {
                try await speaker.speakText(text)
            } catch {
                HeyMateLog.log("⚠️ Local control speech failed: \(error.localizedDescription)")
            }
        }
        return .accepted(["speaking": true, "textLength": text.count])
    }

    // MARK: - Connected accounts

    /// Tools a conversation is never offered, whatever the connector exposes.
    ///
    /// Connection management: asked about a connected app, a model would
    /// call it to "check" the account first, invent a session id, read the
    /// empty answer as "not connected" and send the user a sign-in link for
    /// an account that works. Connecting apps belongs to Settings.
    ///
    /// Remote shells: a spoken question is no mandate to run code on someone
    /// else's machine.
    nonisolated static func isWithheldFromTalk(_ toolName: String) -> Bool {
        withheldToolNames.contains(toolName.uppercased())
    }

    nonisolated static let withheldToolNames: Set<String> = [
        "COMPOSIO_MANAGE_CONNECTIONS",
        "COMPOSIO_REMOTE_BASH_TOOL",
        "COMPOSIO_REMOTE_WORKBENCH",
    ]

    /// Each offered tool with its schema as the provider wrote it. A schema
    /// that won't parse becomes an empty object schema rather than hiding the
    /// tool: vaguely described is still callable, missing is not.
    private func connectorToolDescriptions() -> [[String: Any]] {
        connectorRuntime.availableMCPTools
            .filter { isConnectorEnabledForChat($0.connectorID) && !Self.isWithheldFromTalk($0.tool.name) }
            .map { tool in
                let schema = (try? JSONSerialization.jsonObject(with: Data(tool.tool.inputSchemaJSON.utf8))) as? [String: Any]
                return [
                    "name": tool.id,
                    "description": "[\(tool.connectorDisplayName)] \(tool.tool.description)",
                    "inputSchema": schema ?? ["type": "object", "properties": [String: Any]()],
                ]
            }
    }

    /// Runs the tool on the session HeyMate already holds, under the same
    /// approval rules as a Talk turn. A refused or failed tool still answers
    /// 200 with `isError`, so the model reads what happened and reacts.
    private func callConnectorTool(_ namespacedID: String, argumentsJSON: String) async -> LocalControlResponse {
        await awaitConnectorActivation()
        guard let tool = connectorRuntime.availableMCPTools.first(where: { $0.id == namespacedID }),
              let connector = ConnectorCatalog.connector(withID: tool.connectorID) else {
            return .error(404, "No connected server provides \(namespacedID)")
        }
        // Checked here too: a name learned elsewhere must not be a way in.
        guard !Self.isWithheldFromTalk(tool.tool.name) else {
            return .error(403, "\(tool.tool.name) is not available from a conversation.")
        }
        let result = await executeConnectorTalkTool(
            namespacedToolID: namespacedID,
            connectorIdentifier: tool.connectorID,
            connectorDisplayName: connector.displayName,
            maximumRisk: connector.maximumRisk,
            arguments: TalkToolCatalog.arguments(fromInputArgumentsJSON: argumentsJSON)
        )
        return .ok(["text": result.text, "isError": result.isError])
    }

    /// Adds a mate for a running job whose plan was already approved. It
    /// never opens a chat over the user's, and a taken name is refused
    /// rather than quietly changed.
    private func createMateForJob(name: String?, job: String) -> LocalControlResponse {
        let takenNames = mateDirectory.mates.filter { !$0.archived }.map(\.name)
        let name = name ?? MateNameGenerator.name(for: job, existingNames: takenNames)
        guard !mateDirectory.mateStore.isNameTaken(name) else {
            return .error(409, "A mate named \(name) already exists")
        }
        guard let mate = createMate(name: name, job: job, opensChat: false) else {
            return .error(500, "Could not create the mate")
        }
        // The folder is assigned once the mate is stored, so read it back.
        let folder = mateDirectory.mates.first { $0.id == mate.id }?.folderPath ?? ""
        return .ok(["created": true, "name": mate.name, "job": mate.job, "folder": folder])
    }
}
