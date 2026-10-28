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
    static var drawingReplay: Task<Void, Never>?
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
        case .draw(let actionsJSON):
            return draw(actionsJSON)
        case .drawPieces(let commandsJSON):
            let commands = (try? JSONSerialization.jsonObject(with: Data(commandsJSON.utf8))) as? [[String: Any]] ?? []
            return drawPieces(commands)
        case .showModel3D(let specJSON):
            return showModel3D(specJSON)
        case .openNotes:
            return openNotes()
        case .explain(let program, let streamed):
            return explain(program, streamed: streamed)
        case .drawingState:
            return .ok(await explainerWindowController.rendererState())
        case .ask(let text, let newChat):
            if newChat { startNewChat() }
            sendTranscriptToClaudeWithScreenshot(transcript: text, shouldCaptureScreen: true)
            return .accepted(["asked": text])
        case .drawnTour(let text, let interview):
            startNewChat()
            let lines = interview.split(separator: "\n").map { OnboardingInterviewLine(speaker: .user, text: String($0)) }
            Task { _ = await runDrawnTourStep(text, interview: lines, name: nil) }
            return .accepted(["drawing": text])
        case .clear:
            LocalControlState.drawingReplay?.cancel()
            LocalControlState.drawingReplay = nil
            clearPointingTarget()
            explainerWindowController.dismiss()
            return .ok(["cleared": true])
        case .listTalkTools(let scope):
            return .ok(["tools": scopedTalkToolDescriptions(token: scope)])
        case .callTalkTool(let scope, let name, let argumentsJSON):
            let result = executeScopedTalkTool(token: scope, name: name,
                                               arguments: TalkToolCatalog.arguments(fromInputArgumentsJSON: argumentsJSON))
            return .ok(["text": result.text, "isError": result.isError])
        case .listScopedConnectorTools(let scope):
            return .ok(["tools": scopedConnectorToolDescriptions(token: scope)])
        case .callScopedConnectorTool(let scope, let name, let argumentsJSON):
            let result = await executeScopedConnectorTool(token: scope, name: name,
                arguments: TalkToolCatalog.arguments(fromInputArgumentsJSON: argumentsJSON))
            return .ok(["text": result.text, "isError": result.isError])
        case .listConnectorTools:
            await awaitConnectorActivation()
            return .ok(["tools": connectorToolDescriptions()])
        case .callConnectorTool(let namespacedID, let argumentsJSON):
            return await callConnectorTool(namespacedID, argumentsJSON: argumentsJSON)
        case .createMate(let name, let job):
            return createMateForJob(name: name, job: job)
        @unknown default:
            return .error(400, "Unknown command")
        }
    }

    // MARK: - Drawing

    /// Plays a drawing program the way a reply's ```js block plays: each
    /// say() line spoken while its strokes draw.
    private func explain(_ program: String, streamed: Bool = false) -> LocalControlResponse {
        let reply = GuidedReplyParser.parse("```js\n" + program + "\n```")
        guard reply.explainerProgram != nil else { return .error(400, "The program has no say() lines") }
        LocalControlState.drawingReplay?.cancel()
        explainerWindowController.resetStreamDismissal()
        if streamed {
            // Replay token-sized prefixes through the same controller used by model text deltas.
            LocalControlState.drawingReplay = Task { [weak self] in
                let owner = NSObject()
                var end = program.startIndex
                while end < program.endIndex {
                    guard !Task.isCancelled, let self else { return }
                    end = program.index(end, offsetBy: 120, limitedBy: program.endIndex) ?? program.endIndex
                    let done = end == program.endIndex
                    self.streamExplainer("```js\n" + String(program[..<end]) + (done ? "\n```" : ""),
                                         owner: ObjectIdentifier(owner), screenCaptures: [])
                    if !done { try? await Task.sleep(for: .milliseconds(100)) }
                }
                // Keep owner alive until every prefix has been delivered.
                withExtendedLifetime(owner) {}
            }
            return .accepted(["lines": reply.explainerLineCount, "streamed": true])
        }
        Task { [weak self] in
            _ = try? await self?.playGuidedReply(reply, screenCaptures: [])
        }
        return .accepted(["lines": reply.explainerLineCount])
    }

    /// Runs a caller-supplied visualActions block through the same validation
    /// and choreography a model reply gets. Without fresh captures the draw
    /// falls back to live display frames.
    private func draw(_ actionsJSON: String) -> LocalControlResponse {
        let actions = VisualActionParser.extract(from: actionsJSON).actions
        guard !actions.isEmpty else { return .error(400, "No valid actions") }
        applyVisualActions(actions, screenCaptures: [])
        return .ok(["drawn": actions.count])
    }

    /// Runs ReferenceRenderer-style drawing pieces (ring, ink, write, frame, etc.)
    /// as Swift-native drawing actions on screen.
    private func drawPieces(_ commands: [[String: Any]]) -> LocalControlResponse {
        // matches ReferenceRenderer mate-draw-engine.js / mate-draw-pieces.js parameter screen pen, ink, dash 8/5 and fillAlpha 0.07.
        var actions: [VisualAction] = []
        for cmd in commands {
            guard let type = cmd["type"] as? String else { continue }
            let label = cmd["label"] as? String
            switch type {
            case "point":
                guard let x = cmd["x"] as? Double, let y = cmd["y"] as? Double else { continue }
                actions.append(VisualAction(
                    type: .point, screenId: nil, x: x, y: y,
                    points: nil, center: nil, radius: nil, rect: nil,
                    label: label, ttlMs: nil,
                    style: DrawingStyle(brush: .screenPen, color: .mateInk, glow: true)
                ))
            case "circle":
                guard let x = cmd["x"] as? Double, let y = cmd["y"] as? Double,
                      let r = cmd["r"] as? Double else { continue }
                actions.append(VisualAction(
                    type: .circle, screenId: nil, x: nil, y: nil,
                    points: nil,
                    center: [x, y], radius: [r, r], rect: nil,
                    label: label, ttlMs: nil,
                    style: DrawingStyle(brush: .screenPen, color: .mateInk, glow: true, wash: false)
                ))
            case "target", "hover":
                guard let x = cmd["x"] as? Double, let y = cmd["y"] as? Double else { continue }
                guard let w = cmd["w"] as? Double, let h = cmd["h"] as? Double else {
                    // matches ReferenceRenderer mate-draw-engine.js / mate-draw-pieces.js parameter center-dot screen pointer.
                    actions.append(VisualAction(type: .point, screenId: nil, x: x, y: y,
                                               points: nil, center: nil, radius: nil, rect: nil,
                                               label: label, ttlMs: nil, style: .screenPen))
                    continue
                }
                let p = CGFloat(4)
                let pts = roundedRectPoints(x: CGFloat(x) - p, y: CGFloat(y) - p,
                                            width: CGFloat(w) + 2 * p, height: CGFloat(h) + 2 * p,
                                            cornerRadius: (CGFloat(h) + 2 * p) / 2)
                actions.append(VisualAction(
                    type: .polyline, screenId: nil, x: nil, y: nil,
                    points: (pts + [pts[0]]).map { [Double($0.x), Double($0.y)] },
                    center: nil, radius: nil, rect: nil,
                    label: label, ttlMs: nil,
                    style: DrawingStyle(brush: .screenPen, color: .mateInk,
                                        dash: [8, 5], glow: true, wash: false)
                ))
            case "frame":
                guard let x = cmd["x"] as? Double, let y = cmd["y"] as? Double,
                      let w = cmd["w"] as? Double, let h = cmd["h"] as? Double else { continue }
                let p = CGFloat(3)
                let bx = CGFloat(x) - p, by = CGFloat(y) - p
                let bw = CGFloat(w) + 2 * p, bh = CGFloat(h) + 2 * p
                let r = min(8, bw / 2, bh / 2)
                let pts = roundedRectPoints(x: bx, y: by, width: bw, height: bh, cornerRadius: r)
                actions.append(VisualAction(
                    type: .polygon, screenId: nil, x: nil, y: nil,
                    points: pts.map { [Double($0.x), Double($0.y)] },
                    center: nil, radius: nil, rect: nil,
                    label: nil, ttlMs: nil,
                    style: DrawingStyle(brush: .wash(width: 1, alpha: 0.07), color: .mateInk,
                                        glow: false, wash: true)
                ))
                actions.append(VisualAction(
                    type: .polyline, screenId: nil, x: nil, y: nil,
                    points: (pts + [pts[0]]).map { [Double($0.x), Double($0.y)] },
                    center: nil, radius: nil, rect: nil,
                    label: label, ttlMs: nil,
                    style: DrawingStyle(brush: .screenPen, color: .mateInk,
                                        dash: [8, 5], glow: true, wash: false)
                ))
            case "ring":
                guard let x = cmd["x"] as? Double, let y = cmd["y"] as? Double,
                      let w = cmd["w"] as? Double, let h = cmd["h"] as? Double else { continue }
                let p = CGFloat(4)
                let bw = CGFloat(w) + 2 * p, bh = CGFloat(h) + 2 * p
                let short = min(bw, bh), long = max(bw, bh)
                let rr: CGFloat
                if short <= 56 { rr = short / 2 }
                else if long <= 120 && long < short * 1.4 { rr = short / 2 }
                else { rr = max(8, min(18, short * 0.12)) }
                let pts = roundedRectPoints(x: CGFloat(x) - p, y: CGFloat(y) - p,
                                            width: bw, height: bh, cornerRadius: rr)
                let closed = pts + [pts[0], pts[1]]
                actions.append(VisualAction(
                    type: .polyline, screenId: nil, x: nil, y: nil,
                    points: closed.map { [Double($0.x), Double($0.y)] },
                    center: nil, radius: nil, rect: nil,
                    label: label, ttlMs: nil,
                    style: DrawingStyle(brush: .screenPen, color: .mateInk, glow: true, wash: false)
                ))
            case "arrow":
                guard let pts = cmd["points"] as? [[Double]] else { continue }
                let points: [CGPoint] = pts.compactMap { p in
                    guard p.count == 2 else { return nil }
                    return CGPoint(x: CGFloat(p[0]), y: CGFloat(p[1]))
                }
                guard points.count >= 2 else { continue }
                actions.append(VisualAction(
                    type: .arrow, screenId: nil, x: nil, y: nil,
                    points: points.map { [Double($0.x), Double($0.y)] },
                    center: nil, radius: nil, rect: nil,
                    label: label, ttlMs: nil,
                    style: DrawingStyle(brush: .screenPen, color: .mateInk, glow: true, wash: false)
                ))
            case "ink":
                guard let pts = cmd["points"] as? [[Double]] else { continue }
                let arrow = cmd["arrow"] as? Bool ?? false
                let points: [CGPoint] = pts.compactMap { p in
                    guard p.count == 2 else { return nil }
                    return CGPoint(x: CGFloat(p[0]), y: CGFloat(p[1]))
                }
                guard points.count >= 2 else { continue }
                let inkType: VisualAction.Kind = arrow ? .arrow : .polyline
                let inkPoints = points.map { [Double($0.x), Double($0.y)] }
                let inkStyle = DrawingStyle(brush: .screenPen, color: .mateInk, glow: true, wash: false)
                actions.append(VisualAction(
                    type: inkType, screenId: nil, x: nil, y: nil,
                    points: inkPoints, center: nil, radius: nil, rect: nil,
                    label: label, ttlMs: nil, style: inkStyle
                ))
            case "write":
                guard let x = cmd["x"] as? Double, let y = cmd["y"] as? Double,
                      let text = cmd["text"] as? String else { continue }
                actions.append(VisualAction(
                    type: .caption, screenId: nil, x: x, y: y,
                    points: nil, center: nil, radius: nil,
                    rect: [x, y, Double(text.count) * 12 * 0.5, 12 * 1.25],
                    label: text, ttlMs: nil, style: nil
                ))
            case "num":
                guard let x = cmd["x"] as? Double, let y = cmd["y"] as? Double,
                      let n = cmd["n"] as? Int else { continue }
                let r = CGFloat(9)
                actions.append(VisualAction(
                    type: .circle, screenId: nil, x: nil, y: nil,
                    points: nil,
                    center: [x, y], radius: [r, r], rect: nil,
                    label: nil, ttlMs: nil,
                    style: DrawingStyle(brush: .wash(width: 1, alpha: 0.9), color: .violet,
                                        glow: false, wash: true)
                ))
                actions.append(VisualAction(
                    type: .caption, screenId: nil, x: x, y: y + Double(r * 1.15 * 0.355 + 0.8),
                    points: nil, center: nil, radius: nil, rect: nil,
                    label: String(n), ttlMs: nil, style: nil
                ))
            case "underline":
                guard let x = cmd["x"] as? Double, let y = cmd["y"] as? Double,
                      let w = cmd["w"] as? Double else { continue }
                let yy = y + 3
                actions.append(VisualAction(
                    type: .polyline, screenId: nil, x: nil, y: nil,
                    points: [[x, yy], [x + w, yy]],
                    center: nil, radius: nil, rect: nil,
                    label: nil, ttlMs: nil,
                    style: DrawingStyle(brush: .pen(width: 3, alpha: 1.0), color: .mateInk, glow: true, wash: false)
                ))
            case "connect":
                guard let ax = cmd["ax"] as? Double, let ay = cmd["ay"] as? Double,
                      let bx = cmd["bx"] as? Double, let by = cmd["by"] as? Double else { continue }
                let aPt = CGPoint(x: CGFloat(ax), y: CGFloat(ay))
                let bPt = CGPoint(x: CGFloat(bx), y: CGFloat(by))
                let dx = bPt.x - aPt.x, dy = bPt.y - aPt.y
                let len = hypot(dx, dy)
                guard len > 0 else { continue }
                let nx = -dy / len, ny = dx / len
                let bend: CGFloat = 0.2
                let ctrl = CGPoint(x: (aPt.x + bPt.x) / 2 + nx * len * bend,
                                   y: (aPt.y + bPt.y) / 2 + ny * len * bend)
                actions.append(VisualAction(
                    type: .polyline, screenId: nil, x: nil, y: nil,
                    points: [aPt, ctrl, bPt].map { [Double($0.x), Double($0.y)] },
                    center: nil, radius: nil, rect: nil,
                    label: label, ttlMs: nil,
                    style: DrawingStyle(brush: .screenPen, color: .mateInk, glow: true, wash: false)
                ))
                if let label {
                    actions.append(VisualAction(
                        type: .caption, screenId: nil, x: Double(ctrl.x), y: Double(ctrl.y),
                        points: nil, center: nil, radius: nil, rect: nil,
                        label: label, ttlMs: nil, style: nil
                    ))
                }
            case "trace":
                guard let pts = cmd["points"] as? [[Double]] else { continue }
                let points: [CGPoint] = pts.compactMap { p in
                    guard p.count == 2 else { return nil }
                    return CGPoint(x: CGFloat(p[0]), y: CGFloat(p[1]))
                }
                guard points.count >= 2 else { continue }
                let closed = points + [points[0]]
                let traceStyle = DrawingStyle(brush: .wash(width: 1, alpha: 0.07), color: .mateInk,
                                              glow: false, wash: true)
                let traceClosedPoints = closed.map { [Double($0.x), Double($0.y)] }
                actions.append(VisualAction(
                    type: .polygon, screenId: nil, x: nil, y: nil,
                    points: traceClosedPoints, center: nil, radius: nil, rect: nil,
                    label: nil, ttlMs: nil, style: traceStyle
                ))
                let tracePenStyle = DrawingStyle(brush: .screenPen, color: .mateInk,
                                                 glow: true, wash: false)
                actions.append(VisualAction(
                    type: .polyline, screenId: nil, x: nil, y: nil,
                    points: traceClosedPoints, center: nil, radius: nil, rect: nil,
                    label: label, ttlMs: nil, style: tracePenStyle
                ))
            default:
                continue
            }
        }
        guard !actions.isEmpty else { return .error(400, "No valid commands") }
        applyVisualActions(actions, screenCaptures: [])
        return .ok(["drawn": actions.count])
    }

    /// Shows a 3D model supplied as a {"model3d": {...}} JSON block in a
    /// floating SceneKit window on the cursor's screen.
    private func showModel3D(_ specJSON: String) -> LocalControlResponse {
        guard let data = specJSON.data(using: .utf8),
              let wire = try? JSONDecoder().decode(Model3DParser.WireEnvelope.self, from: data),
              let model = wire.model3d.flatMap(Model3DParser.validate) else {
            return .error(400, "Invalid model3d spec")
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        model3DWindowController.show(model, on: screen?.frame ?? NSScreen.main?.frame ?? .zero)
        return .ok(["shown": model.title, "parts": model.parts.count])
    }

    /// Opens the desktop window on the Notes section.
    private func openNotes() -> LocalControlResponse {
        openDesktopWindow(section: .notes)
        return .ok(["opened": "notes"])
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

    @concurrent
    private nonisolated static func writeScreenshots(_ snapshots: [ScreenSnapshot]) async throws -> [[String: Any]] {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("HeyMateExternalControlScreenshots", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)

        let staleBefore = Date().addingTimeInterval(-screenshotLifetime)
        let existing = (try? files.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
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

    nonisolated static func isWithheldFromTalk(_ toolName: String) -> Bool {
        withheldToolNames.contains(toolName.uppercased())
    }

    nonisolated static let withheldToolNames: Set<String> = [
        "COMPOSIO_MANAGE_CONNECTIONS",
        "COMPOSIO_REMOTE_BASH_TOOL",
        "COMPOSIO_REMOTE_WORKBENCH",
    ]

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

    private func callConnectorTool(_ namespacedID: String, argumentsJSON: String) async -> LocalControlResponse {
        await awaitConnectorActivation()
        guard let tool = connectorRuntime.availableMCPTools.first(where: { $0.id == namespacedID }),
              let connector = ConnectorCatalog.connector(withID: tool.connectorID) else {
            return .error(404, "No connected server provides \(namespacedID)")
        }
        guard !Self.isWithheldFromTalk(tool.tool.name) else {
            return .error(403, "\(tool.tool.name) is not available from a conversation.")
        }
        let result = await executeConnectorTalkTool(
            namespacedToolID: namespacedID,
            connectorIdentifier: tool.connectorID,
            connectorDisplayName: tool.connectorDisplayName,
            maximumRisk: connector.maximumRisk,
            arguments: TalkToolCatalog.arguments(fromInputArgumentsJSON: argumentsJSON)
        )
        return .ok(["text": result.text, "isError": result.isError])
    }

    private func createMateForJob(name: String?, job: String) -> LocalControlResponse {
        let takenNames = mateDirectory.mates.filter { !$0.archived }.map(\.name)
        let name = name ?? MateNameGenerator.name(for: job, existingNames: takenNames)
        guard !mateDirectory.mateStore.isNameTaken(name) else {
            return .error(409, "An agent named \(name) already exists")
        }
        guard let mate = createMate(name: name, job: job, opensChat: false) else {
            return .error(500, "Could not create the agent")
        }
        let folder = mateDirectory.mates.first { $0.id == mate.id }?.folderPath ?? ""
        return .ok(["created": true, "name": mate.name, "job": mate.job, "folder": folder])
    }
}