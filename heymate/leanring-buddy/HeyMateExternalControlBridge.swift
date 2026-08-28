//
//  HeyMateExternalControlBridge.swift
//  leanring-buddy
//
//  Loopback-only HTTP control surface so trusted local agents can drive
//  HeyMate's overlay (point/caption), screenshots, and TTS without entering
//  Talk / Dictate / agent state machines and without warping NSCursor or
//  synthesizing CGEvent clicks.
//

import CoreGraphics
import Foundation
import Network

private let heyMateExternalControlMaximumHeaderBytes = 32 * 1024
private let heyMateExternalControlMaximumBodyBytes = 1 * 1024 * 1024

nonisolated enum HeyMateExternalControlBridge {
    static let defaultPort: UInt16 = 18732
    static let portEnvironmentKey = "HEYMATE_BRIDGE_PORT"

    static func resolvedPort(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UInt16 {
        guard let raw = environment[portEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let parsed = UInt16(raw),
              parsed > 0 else {
            return defaultPort
        }
        return parsed
    }
}

nonisolated enum HeyMateExternalControlCommand: Equatable {
    case health
    case showCursor(point: CGPoint, caption: String?, duration: TimeInterval)
    case showCaption(text: String, point: CGPoint?, duration: TimeInterval)
    case captureScreenshot(focused: Bool)
    case speak(text: String)
    case clear
}

nonisolated struct HeyMateExternalControlResponse {
    var statusCode: Int
    var body: [String: Any]

    static func ok(_ body: [String: Any] = [:]) -> HeyMateExternalControlResponse {
        HeyMateExternalControlResponse(
            statusCode: 200,
            body: ["ok": true].merging(body) { _, new in new }
        )
    }

    static func accepted(_ body: [String: Any] = [:]) -> HeyMateExternalControlResponse {
        HeyMateExternalControlResponse(
            statusCode: 202,
            body: ["ok": true, "accepted": true].merging(body) { _, new in new }
        )
    }

    static func error(_ statusCode: Int, _ message: String) -> HeyMateExternalControlResponse {
        HeyMateExternalControlResponse(
            statusCode: statusCode,
            body: ["ok": false, "error": message]
        )
    }
}

nonisolated enum HeyMateExternalControlRoute: Equatable {
    case accepted(HeyMateExternalControlCommand)
    case rejected(statusCode: Int, message: String)
}

nonisolated enum HeyMateExternalControlRouter {

    static func route(method: String, path: String, json: [String: Any]) -> HeyMateExternalControlRoute {
        let normalizedMethod = method.uppercased()
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"

        if normalizedMethod == "OPTIONS" {
            return .accepted(.health)
        }

        if normalizedMethod == "GET", normalizedPath == "/health" {
            return .accepted(.health)
        }

        if isUnsupportedControlPath(normalizedPath) {
            return .rejected(statusCode: 404, message: "Unknown endpoint")
        }

        guard normalizedMethod == "POST" else {
            if normalizedMethod == "GET" {
                return .rejected(statusCode: 404, message: "Unknown endpoint")
            }
            return .rejected(statusCode: 405, message: "Use POST for control commands")
        }

        if isClickShaped(json) {
            return .rejected(statusCode: 400, message: "Click is not supported")
        }

        switch normalizedPath {
        case "/cursor":
            guard let point = point(from: json) else {
                return .rejected(statusCode: 400, message: "Missing x and y")
            }
            return .accepted(.showCursor(
                point: point,
                caption: string(json["caption"]),
                duration: duration(from: json)
            ))
        case "/caption":
            guard let text = string(json["text"])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return .rejected(statusCode: 400, message: "Missing text")
            }
            return .accepted(.showCaption(
                text: text,
                point: point(from: json),
                duration: duration(from: json)
            ))
        case "/screenshot", "/screenshots":
            return .accepted(.captureScreenshot(focused: bool(json["focused"]) ?? false))
        case "/speak":
            guard let text = string(json["text"])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                return .rejected(statusCode: 400, message: "Missing text")
            }
            return .accepted(.speak(text: text))
        case "/clear":
            return .accepted(.clear)
        default:
            return .rejected(statusCode: 404, message: "Unknown endpoint")
        }
    }

    private static func isUnsupportedControlPath(_ path: String) -> Bool {
        switch path {
        case "/click", "/drag", "/type", "/cursors", "/scribble",
             "/highlight", "/rectangle", "/notify", "/notification",
             "/mcp", "/mcp/call", "/mcp/calls", "/tools/call", "/tools/calls",
             "/v1/messages", "/v1/responses", "/v1/chat/completions":
            return true
        default:
            return false
        }
    }

    private static func isClickShaped(_ json: [String: Any]) -> Bool {
        if bool(json["click"]) == true { return true }
        let action = (string(json["action"]) ?? string(json["type"]) ?? string(json["tool"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch action {
        case "click", "left_click", "right_click", "mouse_click", "drag", "type":
            return true
        default:
            return false
        }
    }

    static func point(from json: [String: Any]) -> CGPoint? {
        if let nested = dictionary(json["point"]),
           let x = double(nested["x"]),
           let y = double(nested["y"]) {
            guard x.isFinite, y.isFinite else { return nil }
            return CGPoint(x: x, y: y)
        }
        guard let x = double(json["x"]), let y = double(json["y"]) else { return nil }
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    static func duration(from json: [String: Any]) -> TimeInterval {
        let milliseconds = double(json["durationMs"]) ?? double(json["ttlMs"])
        if let milliseconds {
            return max(0.2, min(milliseconds / 1000.0, 60.0))
        }
        return max(0.2, min(double(json["duration"]) ?? 4.0, 60.0))
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func double(_ value: Any?) -> Double? {
        if let value = value as? Double { return value.isFinite ? value : nil }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String, let parsed = Double(value) {
            return parsed.isFinite ? parsed : nil
        }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? String {
            return ["true", "yes", "1"].contains(value.lowercased())
        }
        if let value = value as? Int { return value != 0 }
        return nil
    }

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }
}

nonisolated enum HeyMateExternalControlAuth {
    static let tokenHeaderName = "x-heymate-token"
    static let secretsKey = "HEYMATE_BRIDGE_TOKEN"

    /// When a token is configured, every request must present it. When none
    /// is configured, the loopback bind is the only gate.
    static func isAuthorized(
        headers: [String: String],
        configuredToken: String? = HeyMateSecrets.lookup(secretsKey)
    ) -> Bool {
        guard let configuredToken, !configuredToken.isEmpty else { return true }

        if let rawAuthorization = headers["authorization"] {
            let trimmed = rawAuthorization.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 7, trimmed.prefix(7).lowercased() == "bearer " {
                let provided = trimmed.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                return provided == configuredToken
            }
        }

        if let headerToken = headers[tokenHeaderName]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !headerToken.isEmpty {
            return headerToken == configuredToken
        }

        return false
    }
}

nonisolated enum HeyMateExternalControlLoopback {
    static func isAllowed(host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "localhost" || normalized == "::1" || normalized == "0:0:0:0:0:0:0:1" {
            return true
        }
        let parts = normalized.split(separator: ".")
        return parts.count == 4 && parts[0] == "127"
    }
}

nonisolated struct HeyMateExternalControlHTTPRequest {
    enum ParseResult {
        case incomplete
        case malformed(String)
        case request(HeyMateExternalControlHTTPRequest)
    }

    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var jsonBody: [String: Any] {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body),
              let dictionary = object as? [String: Any] else {
            return [:]
        }
        return dictionary
    }

    static func parse(_ data: Data) -> ParseResult {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > heyMateExternalControlMaximumHeaderBytes
                ? .malformed("HTTP request headers exceed the maximum size.")
                : .incomplete
        }
        guard headerRange.lowerBound <= heyMateExternalControlMaximumHeaderBytes else {
            return .malformed("HTTP request headers exceed the maximum size.")
        }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .malformed("HTTP request headers must be UTF-8.")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .malformed("HTTP request line is missing.")
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              parts[2].hasPrefix("HTTP/") else {
            return .malformed("HTTP request line is invalid.")
        }

        var headers: [String: String] = [:]
        var sawContentLength = false
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                return .malformed("HTTP request header is invalid.")
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                return .malformed("HTTP request header name is missing.")
            }
            if key == "content-length" {
                guard !sawContentLength else {
                    return .malformed("Multiple Content-Length headers are not allowed.")
                }
                sawContentLength = true
            }
            headers[key] = value
        }

        if let transferEncoding = headers["transfer-encoding"],
           !transferEncoding.isEmpty,
           transferEncoding.lowercased() != "identity" {
            return .malformed("Transfer-Encoding is not supported.")
        }

        let bodyStart = headerRange.upperBound
        let contentLength: Int
        if let declaredLength = headers["content-length"] {
            guard !declaredLength.isEmpty,
                  declaredLength.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let parsedLength = Int(declaredLength),
                  parsedLength <= heyMateExternalControlMaximumBodyBytes else {
                return .malformed("Content-Length is invalid or exceeds the maximum request size.")
            }
            contentLength = parsedLength
        } else {
            contentLength = 0
        }

        guard bodyStart <= data.count else {
            return .malformed("HTTP request body offset is invalid.")
        }
        guard contentLength <= data.count - bodyStart else {
            return .incomplete
        }
        let bodyEnd = bodyStart + contentLength
        return .request(
            HeyMateExternalControlHTTPRequest(
                method: parts[0].uppercased(),
                path: URLComponents(string: parts[1])?.path ?? parts[1],
                headers: headers,
                body: Data(data[bodyStart..<bodyEnd])
            )
        )
    }
}

typealias HeyMateExternalControlHandler = @MainActor (HeyMateExternalControlCommand) async -> HeyMateExternalControlResponse

nonisolated final class HeyMateExternalControlBridgeServer: @unchecked Sendable {
    private let port: UInt16
    private let handler: HeyMateExternalControlHandler
    private let queue = DispatchQueue(label: "com.heymate.app.external-control-bridge")
    private var listener: NWListener?

    init(
        port: UInt16 = HeyMateExternalControlBridge.defaultPort,
        handler: @escaping HeyMateExternalControlHandler
    ) {
        self.port = port
        self.handler = handler
    }

    func start() {
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            if let address = IPv4Address("127.0.0.1"),
               let endpointPort = NWEndpoint.Port(rawValue: port) {
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(address), port: endpointPort)
            }

            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    print("HeyMate external control bridge listening on http://127.0.0.1:\(self.port)")
                case .failed(let error):
                    print("HeyMate external control bridge failed: \(error)")
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            print("HeyMate external control bridge could not start: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        if !isLoopback(connection) {
            sendJSON(["ok": false, "error": "Loopback clients only"], statusCode: 403, on: connection)
            return
        }
        receiveRequest(on: connection, buffer: Data())
    }

    private func isLoopback(_ connection: NWConnection) -> Bool {
        switch connection.endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let address):
                return address == .loopback
                    || HeyMateExternalControlLoopback.isAllowed(host: address.debugDescription)
            case .ipv6(let address):
                return address == .loopback
                    || HeyMateExternalControlLoopback.isAllowed(host: address.debugDescription)
            case .name(let name, _):
                return HeyMateExternalControlLoopback.isAllowed(host: name)
            @unknown default:
                return false
            }
        default:
            // Listener is bound to 127.0.0.1; unknown endpoint shapes stay local.
            return true
        }
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.sendJSON(["ok": false, "error": error.localizedDescription], statusCode: 400, on: connection)
                return
            }

            var nextBuffer = buffer
            if let data { nextBuffer.append(data) }

            switch HeyMateExternalControlHTTPRequest.parse(nextBuffer) {
            case .request(let request):
                self.handle(request, on: connection)
                return
            case .malformed(let reason):
                self.sendJSON(["ok": false, "error": reason], statusCode: 400, on: connection)
                return
            case .incomplete:
                break
            }

            if isComplete || nextBuffer.count > heyMateExternalControlMaximumHeaderBytes + heyMateExternalControlMaximumBodyBytes {
                self.sendJSON(["ok": false, "error": "Malformed HTTP request"], statusCode: 400, on: connection)
                return
            }

            self.receiveRequest(on: connection, buffer: nextBuffer)
        }
    }

    private func handle(_ request: HeyMateExternalControlHTTPRequest, on connection: NWConnection) {
        guard HeyMateExternalControlAuth.isAuthorized(headers: request.headers) else {
            sendJSON(["ok": false, "error": "Unauthorized"], statusCode: 401, on: connection)
            return
        }

        let route = HeyMateExternalControlRouter.route(
            method: request.method,
            path: request.path,
            json: request.jsonBody
        )

        switch route {
        case .rejected(let statusCode, let message):
            sendJSON(["ok": false, "error": message], statusCode: statusCode, on: connection)
        case .accepted(.health):
            sendJSON(["ok": true, "service": "heymate"], statusCode: 200, on: connection)
        case .accepted(let command):
            Task { @MainActor in
                let response = await self.handler(command)
                self.queue.async {
                    self.sendJSON(response.body, statusCode: response.statusCode, on: connection)
                }
            }
        }
    }

    private func sendJSON(_ body: [String: Any], statusCode: Int, on connection: NWConnection) {
        let responseData = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        let reason = Self.reasonPhrase(for: statusCode)
        var headers = "HTTP/1.1 \(statusCode) \(reason)\r\n"
        headers += "Content-Type: application/json\r\n"
        headers += "Content-Length: \(responseData.count)\r\n"
        headers += "Connection: close\r\n"
        headers += "Access-Control-Allow-Origin: http://127.0.0.1\r\n"
        headers += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        headers += "Access-Control-Allow-Headers: Content-Type, Authorization, X-HeyMate-Token\r\n"
        headers += "\r\n"
        var data = Data(headers.utf8)
        data.append(responseData)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }
}
