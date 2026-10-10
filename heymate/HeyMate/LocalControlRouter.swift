//
//  LocalControlRouter.swift
//  HeyMate
//
//  What the local control server understands. Trusted tools on this Mac
//  (HeyMate's own MCP server, agents it runs) can point the cursor, show a
//  caption, take screenshots, speak, use the connected accounts and add a
//  mate. They can never click, type or drag: those requests are refused
//  outright, whatever path they arrive on.
//
//  Pure request-to-command mapping, so it is tested without a socket.
//

import CoreGraphics
import Foundation

nonisolated enum LocalControlCommand: Equatable {
    case health
    case showCursor(point: CGPoint, caption: String?, duration: TimeInterval)
    case showCaption(text: String, point: CGPoint?, duration: TimeInterval)
    case captureScreenshot(focused: Bool)
    case speak(text: String)
    case clear
    /// Every tool the connected accounts expose, so a child CLI can offer
    /// them without opening its own session with the provider.
    case listConnectorTools
    /// Runs one of those tools on the session HeyMate already holds. The
    /// user's approval policy is applied here, never by the caller.
    case callConnectorTool(namespacedID: String, argumentsJSON: String)
    /// A job's folder is sandboxed away from HeyMate's settings, so this is
    /// how an approved plan ("make me three mates") adds one.
    case createMate(name: String?, job: String)

    /// Reaches the user's accounts or changes their roster, so it needs a
    /// token even when the overlay commands don't.
    var touchesConnectedAccounts: Bool {
        switch self {
        case .listConnectorTools, .callConnectorTool, .createMate: return true
        default: return false
        }
    }
}

nonisolated struct LocalControlResponse {
    var statusCode: Int
    var body: [String: Any]

    static func ok(_ fields: [String: Any] = [:]) -> LocalControlResponse {
        LocalControlResponse(statusCode: 200, body: fields.merging(["ok": true]) { field, _ in field })
    }

    static func accepted(_ fields: [String: Any] = [:]) -> LocalControlResponse {
        LocalControlResponse(
            statusCode: 202,
            body: fields.merging(["ok": true, "accepted": true]) { field, _ in field }
        )
    }

    static func error(_ statusCode: Int, _ message: String) -> LocalControlResponse {
        LocalControlResponse(statusCode: statusCode, body: ["ok": false, "error": message])
    }
}

nonisolated enum LocalControlRoute: Equatable {
    case accepted(LocalControlCommand)
    case rejected(statusCode: Int, message: String)
}

nonisolated enum LocalControlRouter {
    static func route(method: String, path rawPath: String, json body: [String: Any]) -> LocalControlRoute {
        let method = method.uppercased()
        let path = rawPath.hasPrefix("/") ? rawPath : "/" + rawPath
        let unknown = LocalControlRoute.rejected(statusCode: 404, message: "Unknown endpoint")

        // Pre-flight and liveness checks need no body.
        if method == "OPTIONS" || (method == "GET" && path == "/health") { return .accepted(.health) }
        if refusedPaths.contains(path) { return unknown }
        guard method == "POST" else {
            return method == "GET" ? unknown : .rejected(statusCode: 405, message: "Use POST for control commands")
        }
        if asksForInput(body) { return .rejected(statusCode: 400, message: "Click is not supported") }

        let fields = Fields(body)
        switch path {
        case "/cursor":
            guard let point = fields.point else { return .rejected(statusCode: 400, message: "Missing x and y") }
            return .accepted(.showCursor(point: point, caption: fields.string("caption"), duration: fields.duration))
        case "/caption":
            guard let text = fields.nonBlank("text") else { return .rejected(statusCode: 400, message: "Missing text") }
            return .accepted(.showCaption(text: text, point: fields.point, duration: fields.duration))
        case "/screenshot", "/screenshots":
            return .accepted(.captureScreenshot(focused: fields.bool("focused") ?? false))
        case "/speak":
            guard let text = fields.nonBlank("text") else { return .rejected(statusCode: 400, message: "Missing text") }
            return .accepted(.speak(text: text))
        case "/clear":
            return .accepted(.clear)
        case "/connector/tools":
            return .accepted(.listConnectorTools)
        case "/connector/call":
            // Never fall back to some default tool: no name, no call.
            guard let tool = fields.nonBlank("tool") else { return .rejected(statusCode: 400, message: "Missing tool") }
            // Arguments stay as text. Their schema is the provider's, and
            // re-modelling it here would only be a place to mangle it.
            let arguments = fields.string("arguments") ?? ""
            return .accepted(.callConnectorTool(namespacedID: tool, argumentsJSON: arguments.isEmpty ? "{}" : arguments))
        case "/mate/create":
            guard let job = fields.nonBlank("job") else { return .rejected(statusCode: 400, message: "Missing job") }
            return .accepted(.createMate(name: fields.nonBlank("name"), job: job))
        default:
            return unknown
        }
    }

    /// Paths that look like input control or a model API. They are answered
    /// as unknown, so nothing suggests they might work with other arguments.
    private static let refusedPaths: Set<String> = [
        "/click", "/drag", "/type", "/cursors", "/scribble", "/highlight", "/rectangle",
        "/notify", "/notification", "/mcp", "/mcp/call", "/mcp/calls", "/tools/call",
        "/tools/calls", "/v1/messages", "/v1/responses", "/v1/chat/completions",
    ]

    private static let inputActions: Set<String> = ["click", "left_click", "right_click", "mouse_click", "drag", "type"]

    /// A body that asks for a click, drag or keystroke, on any path.
    private static func asksForInput(_ body: [String: Any]) -> Bool {
        let fields = Fields(body)
        if fields.bool("click") == true { return true }
        let action = fields.string("action") ?? fields.string("type") ?? fields.string("tool")
        return action.map { inputActions.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) } ?? false
    }

    /// Lenient typed reads of a JSON body: numbers and booleans may arrive
    /// as strings, and anything not finite counts as missing.
    nonisolated struct Fields {
        let body: [String: Any]

        init(_ body: [String: Any]) {
            self.body = body
        }

        func string(_ key: String) -> String? {
            body[key] as? String
        }

        func nonBlank(_ key: String) -> String? {
            guard let text = string(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }

        func number(_ key: String) -> Double? {
            Self.number(body[key])
        }

        func bool(_ key: String) -> Bool? {
            switch body[key] {
            case let value as Bool: return value
            case let value as String: return ["true", "yes", "1"].contains(value.lowercased())
            case let value as Int: return value != 0
            default: return nil
            }
        }

        /// `{"point": {"x", "y"}}` or top-level `x` and `y`.
        var point: CGPoint? {
            let source = (body["point"] as? [String: Any]).flatMap { nested in
                Self.number(nested["x"]).flatMap { x in Self.number(nested["y"]).map { (x, $0) } }
            } ?? number("x").flatMap { x in number("y").map { (x, $0) } }
            return source.map { CGPoint(x: $0.0, y: $0.1) }
        }

        /// How long to show something: `durationMs` or `ttlMs`, else
        /// `duration` in seconds, else 4 s; always within 0.2–60 s.
        var duration: TimeInterval {
            let seconds = (number("durationMs") ?? number("ttlMs")).map { $0 / 1000 } ?? number("duration") ?? 4
            return min(max(seconds, 0.2), 60)
        }

        private static func number(_ value: Any?) -> Double? {
            let parsed: Double?
            switch value {
            case let value as Double: parsed = value
            case let value as Int: parsed = Double(value)
            case let value as String: parsed = Double(value)
            default: parsed = nil
            }
            return parsed.flatMap { $0.isFinite ? $0 : nil }
        }
    }
}

nonisolated enum LocalControlAuth {
    static let tokenHeaderName = "x-heymate-token"
    static let secretsKey = "HEYMATE_BRIDGE_TOKEN"
    /// Keychain account for the token minted when the secrets file sets
    /// none; erased with the rest of HeyMate's data.
    static let mintedTokenConnectorID = "heymate.bridge"

    /// With a configured token every request must present it, as a bearer
    /// token or in `x-heymate-token`. With none, the loopback-only bind is
    /// the gate (enough for drawing on the screen).
    static func isAuthorized(
        headers: [String: String],
        configuredToken: String? = HeyMateSecrets.lookup(secretsKey)
    ) -> Bool {
        guard let configuredToken, !configuredToken.isEmpty else { return true }
        guard let presented = presentedToken(in: headers) else { return false }
        return constantTimeEqual(presented, configuredToken)
    }

    /// For routes that reach the user's accounts, a missing token is a
    /// refusal: another local process drawing on screen is harmless,
    /// reading the user's mail is not.
    static func isAuthorizedForConnectedAccounts(headers: [String: String], expectedToken: String?) -> Bool {
        guard let expectedToken, !expectedToken.isEmpty else { return false }
        return isAuthorized(headers: headers, configuredToken: expectedToken)
    }

    /// The configured token, else the stored minted one, else a newly
    /// minted one (nil only if the keychain refuses to store it).
    static func resolvedToken(configuredToken: String? = HeyMateSecrets.lookup(secretsKey)) -> String? {
        if let configuredToken, !configuredToken.isEmpty { return configuredToken }
        if let stored = ConnectorSecretStore.secret(forConnectorID: mintedTokenConnectorID), !stored.isEmpty {
            return stored
        }
        let minted = UUID().uuidString
        return ConnectorSecretStore.setSecret(minted, forConnectorID: mintedTokenConnectorID) ? minted : nil
    }

    /// An `Authorization: Bearer …` header wins; otherwise `x-heymate-token`.
    private static func presentedToken(in headers: [String: String]) -> String? {
        if let authorization = headers["authorization"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           authorization.lowercased().hasPrefix("bearer ") {
            return authorization.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let header = headers[tokenHeaderName]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !header.isEmpty else { return nil }
        return header
    }

    /// Compares without returning early, so timing reveals nothing about
    /// how much of a guess was right.
    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        var difference = left.count ^ right.count
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= Int(a ^ b)
        }
        return difference == 0
    }
}

nonisolated enum LocalControlLoopback {
    /// localhost, ::1 (either spelling) or any 127.x.x.x address.
    static func isAllowed(host: String) -> Bool {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["localhost", "::1", "0:0:0:0:0:0:0:1"].contains(host) { return true }
        let octets = host.split(separator: ".")
        return octets.count == 4 && octets[0] == "127"
    }
}
