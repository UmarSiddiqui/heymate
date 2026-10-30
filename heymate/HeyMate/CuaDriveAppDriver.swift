//
//  CuaDriveAppDriver.swift
//  HeyMate
//
//  The drive engine's hands, through Cua's driver: the same driver
//  HeyClicky drives with. Cua reads the window (element tokens that survive
//  backgrounded and off-Space windows, menu items included), presses and
//  types without stealing focus where macOS allows it, and drags with a
//  human-paced gesture. HeyMate keeps everything that decides and guards:
//  consent, the never-press list, take-back, the step cap and the log.
//
//  Pixel clicks on a full-screen screenshot still go through HeyMate's own
//  executor, since Cua's pixel space is per window.
//

import AppKit
import Foundation

@MainActor
final class CuaDriveAppDriver: DriveAppDriving {
    private(set) var lastPoint: CGPoint?
    var userTookOver = false
    var onWillAct: ((CGPoint) -> Void)?

    private let client: CuaDriverClient
    private let fallback: DriveAppDriver
    private var started = false
    /// Cua's element token for each of our tokens, last snapshot only.
    private var tokens: [Int: String] = [:]
    private var windowID: Int?
    private var processIdentifier: pid_t = 0

    /// Elements per snapshot, before HeyMate's own prompt cap.
    static let maximumElements = 400
    /// Menu items are useful (Cua can press them) but numerous; window
    /// controls come first and menus fill what is left.
    static let maximumMenuItems = 60

    init(executable: URL) {
        client = CuaDriverClient(executable: executable)
        fallback = DriveAppDriver()
    }

    deinit {
        let client = client
        Task { @MainActor in client.stop() }
    }

    private func ensureStarted() async throws {
        guard !started else { return }
        try await client.start()
        started = true
        HeyMateLog.log("🚗 Drive: using Cua's driver")
    }

    // MARK: Reading

    func snapshot(processIdentifier: pid_t) async -> DriveSnapshot? {
        do {
            try await ensureStarted()
            self.processIdentifier = processIdentifier
            let listing = try await client.call("list_windows", ["pid": Int(processIdentifier), "on_screen_only": true])
            let windows = (listing["windows"] as? [[String: Any]] ?? [])
                .filter { ($0["pid"] as? Int) == Int(processIdentifier) }
                .sorted { ($0["z_index"] as? Int ?? .max) < ($1["z_index"] as? Int ?? .max) }
            guard let window = windows.first, let id = window["window_id"] as? Int else { return nil }
            windowID = id
            let state = try await client.call("get_window_state", [
                "pid": Int(processIdentifier),
                "window_id": id,
                "include_screenshot": false,
                "max_elements": Self.maximumElements,
            ])
            return Self.project(state, processIdentifier: processIdentifier, tokens: &tokens)
        } catch {
            HeyMateLog.log("⚠️ Drive: Cua snapshot failed — \(error.localizedDescription)")
            return nil
        }
    }

    /// Cua's element list → HeyMate's tokens. Pure, for tests.
    static func project(_ state: [String: Any], processIdentifier: pid_t, tokens: inout [Int: String]) -> DriveSnapshot {
        let raw = state["elements"] as? [[String: Any]] ?? []
        var windowElements: [DriveElement] = []
        var menuElements: [DriveElement] = []
        var visible: [String] = []
        var map: [Int: String] = [:]
        var pendingTokens: [(DriveElement, String, isMenu: Bool)] = []
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0

        for element in raw {
            let role = element["role"] as? String ?? ""
            let label = (element["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let value = (element["value"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if !label.isEmpty { visible.append(label) }
            if let value, !value.isEmpty { visible.append(value) }

            let actions = element["actions"] as? [String] ?? []
            let isTextEntry = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
            guard role != "AXWindow", !label.isEmpty || isTextEntry,
                  (element["enabled"] as? Bool) ?? true,
                  !actions.isEmpty || isTextEntry,
                  let cuaToken = element["element_token"] as? String else { continue }
            let isMenu = role == "AXMenuItem" || role == "AXMenuBarItem"
            let frameObject = element["frame"] as? [String: Any]
            let frame: CGRect = frameObject.map { object in
                let x = (object["x"] as? Double) ?? 0, y = (object["y"] as? Double) ?? 0
                let w = (object["w"] as? Double) ?? 0, h = (object["h"] as? Double) ?? 0
                return CGRect(x: x, y: primaryHeight - y - h, width: w, height: h)
            } ?? .zero
            let driveElement = DriveElement(
                token: 0,
                role: role,
                label: label.isEmpty ? (element["placeholder"] as? String ?? role) : label,
                value: value,
                frame: frame,
                isFocused: (element["focused"] as? Bool) ?? false
            )
            pendingTokens.append((driveElement, cuaToken, isMenu))
        }

        let windowFirst = pendingTokens.filter { !$0.isMenu } + pendingTokens.filter(\.isMenu)
        for (element, cuaToken, isMenu) in windowFirst {
            if isMenu, menuElements.count >= maximumMenuItems { continue }
            let token = windowElements.count + menuElements.count + 1
            let numbered = DriveElement(token: token, role: element.role, label: element.label, value: element.value,
                                        frame: element.frame, isFocused: element.isFocused)
            if isMenu { menuElements.append(numbered) } else { windowElements.append(numbered) }
            map[token] = cuaToken
        }
        visible += markdownText(state["tree_markdown"] as? String ?? "")
        tokens = map
        return DriveSnapshot(
            applicationName: state["app_name"] as? String ?? "the app",
            processIdentifier: processIdentifier,
            windowTitle: state["window_title"] as? String,
            elements: windowElements + menuElements,
            visibleStrings: visible
        )
    }

    /// Text Cua lists only in its markdown: static text and values, such as
    /// `AXStaticText = "12" (Edit field)`. Read so the model can see results.
    static func markdownText(_ markdown: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"= "((?:[^"\\]|\\.)*)"|^\s*- AX\w+ \(([^)]+)\)"#,
                                                        options: [.anchorsMatchLines]) else { return [] }
        let range = NSRange(markdown.startIndex..., in: markdown)
        return expression.matches(in: markdown, range: range).compactMap { match in
            for group in 1...2 {
                if let found = Range(match.range(at: group), in: markdown) {
                    let text = String(markdown[found]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : text
                }
            }
            return nil
        }
    }

    // MARK: Acting

    func perform(_ decision: DriveDecision, in snapshot: DriveSnapshot, request: DriveRequest, screenshot: ScreenSnapshot?) async throws -> String {
        guard !userTookOver else { throw CancellationError() }
        try Task.checkCancellation()
        try await ensureStarted()
        let pid = Int(processIdentifier == 0 ? snapshot.processIdentifier : processIdentifier)

        switch decision {
        case .press(let token):
            let (element, cuaToken) = try target(token, in: snapshot)
            point(at: element)
            try await client.call("click", ["pid": pid, "element_token": cuaToken])
            return "Pressed \"\(element.label)\"."

        case .type(let token, let modelText, let submit):
            var text = modelText
            var arguments: [String: Any] = ["pid": pid]
            if let token {
                let (element, cuaToken) = try target(token, in: snapshot)
                if let supplied = DriveEngine.suppliedValue(for: element, values: request.values) { text = supplied }
                point(at: element)
                arguments["element_token"] = cuaToken
                // Replace what is there rather than appending to it.
                try await client.call("hotkey", ["pid": pid, "keys": ["cmd", "a"], "element_token": cuaToken])
            } else if let windowID {
                arguments["window_id"] = windowID
            }
            arguments["text"] = text
            try await client.call("type_text", arguments)
            if submit {
                var keyArguments: [String: Any] = ["pid": pid, "key": "return"]
                if let cuaToken = arguments["element_token"] { keyArguments["element_token"] = cuaToken }
                try await client.call("press_key", keyArguments)
            }
            return "Typed \(text.count) characters\(submit ? " and pressed Return" : "")."

        case .key(let combination):
            let parts = Self.keyParts(combination)
            guard let key = parts.last else { throw DriveActionError.unsupported("key \(combination)") }
            if parts.count == 1 {
                try await client.call("press_key", ["pid": pid, "key": key])
            } else {
                try await client.call("hotkey", ["pid": pid, "keys": parts])
            }
            return "Pressed \(combination)."

        case .scroll(let direction):
            var arguments: [String: Any] = ["pid": pid, "direction": direction, "amount": 5]
            if let windowID { arguments["window_id"] = windowID }
            try await client.call("scroll", arguments)
            return "Scrolled \(direction)."

        case .openApplication(let name):
            try await client.call("launch_app", ["name": name])
            try await Task.sleep(for: .milliseconds(900))
            return "Opened \(name)."

        case .drag(let fromToken, let toToken):
            let (from, _) = try target(fromToken, in: snapshot)
            let (to, _) = try target(toToken, in: snapshot)
            guard let windowID else { throw DriveActionError.unsupported("drag without a window") }
            let geometry = try await client.call("get_window_state", [
                "pid": pid, "window_id": windowID, "include_accessibility_tree": false, "max_image_dimension": 0,
            ])
            let start = try Self.windowPixel(for: from, geometry: geometry)
            let end = try Self.windowPixel(for: to, geometry: geometry)
            point(at: from)
            try await client.call("drag", [
                "pid": pid, "window_id": windowID,
                "from_x": start.x, "from_y": start.y, "to_x": end.x, "to_y": end.y,
                "delivery_mode": "foreground", "duration_ms": 700, "steps": 28,
            ])
            lastPoint = CGPoint(x: to.frame.midX, y: to.frame.midY)
            onWillAct?(lastPoint!)
            return "Dragged \"\(from.label)\" onto \"\(to.label)\"."

        case .clickPoint, .wait, .done, .blocked:
            return try await fallback.perform(decision, in: snapshot, request: request, screenshot: screenshot)
        }
    }

    private func target(_ token: Int, in snapshot: DriveSnapshot) throws -> (DriveElement, String) {
        guard let element = snapshot.element(withToken: token), let cuaToken = tokens[token] else {
            throw DriveActionError.missingElement(token)
        }
        return (element, cuaToken)
    }

    private func point(at element: DriveElement) {
        let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
        lastPoint = center
        onWillAct?(center)
    }

    /// "cmd+shift+n" → ["cmd", "shift", "n"], with the names Cua expects.
    static func keyParts(_ combination: String) -> [String] {
        let aliases = ["command": "cmd", "⌘": "cmd", "control": "ctrl", "⌃": "ctrl", "alt": "option", "opt": "option",
                       "⌥": "option", "⇧": "shift", "enter": "return", "esc": "escape"]
        return combination.lowercased().split(separator: "+").map {
            let part = $0.trimmingCharacters(in: .whitespaces)
            return aliases[part] ?? part
        }.filter { !$0.isEmpty }
    }

    /// An element's center in Cua's window-local screenshot pixels.
    static func windowPixel(for element: DriveElement, geometry: [String: Any]) throws -> CGPoint {
        guard let bounds = geometry["window_bounds"] as? [String: Any],
              let originX = bounds["x"] as? Double, let originY = bounds["y"] as? Double else {
            throw CuaDriverClientError.malformed("no window bounds")
        }
        let scale = geometry["screenshot_scale"] as? Double ?? 1
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        // Back to top-left global points, then into the window and its pixels.
        let topLeftY = primaryHeight - element.frame.midY
        return CGPoint(x: (element.frame.midX - originX) * scale, y: (topLeftY - originY) * scale)
    }
}
