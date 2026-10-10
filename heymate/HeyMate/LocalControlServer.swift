//
//  LocalControlServer.swift
//  HeyMate
//
//  A tiny HTTP/1.1 server on 127.0.0.1 that hands `LocalControlRouter`
//  commands to the app. One request per connection, JSON in and out,
//  bounded sizes, no chunked bodies. Loopback clients only.
//

import Darwin
import Foundation
import Network

nonisolated enum LocalControlPort {
    static let defaultPort: UInt16 = 18732
    static let environmentKey = "HEYMATE_BRIDGE_PORT"

    /// This process's port, chosen once before the listener starts so every
    /// child it spawns is told the same one. The default stays put for the
    /// usual single copy; a second copy (an Xcode build next to the installed
    /// app) gets a free port instead of talking to the first copy.
    static let current: UInt16 = choose(
        preferred: configured(),
        isFree: { probe(port: $0) != nil },
        fallback: { probe(port: 0) }
    )

    /// `HEYMATE_BRIDGE_PORT` when it holds a valid port, else the default.
    static func configured(environment: [String: String] = ProcessInfo.processInfo.environment) -> UInt16 {
        environment[environmentKey]
            .flatMap { UInt16($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { $0 > 0 ? $0 : nil } ?? defaultPort
    }

    static func choose(preferred: UInt16, isFree: (UInt16) -> Bool, fallback: () -> UInt16?) -> UInt16 {
        isFree(preferred) ? preferred : fallback() ?? preferred
    }

    /// Binds a loopback socket for a moment: proves `port` is free, or with
    /// 0 lets the kernel pick one. Returns the bound port.
    private static func probe(port: UInt16) -> UInt16? {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        defer { Darwin.close(socket) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                Darwin.bind(socket, pointer, length) == 0 && getsockname(socket, pointer, &length) == 0
            }
        }
        return bound ? UInt16(bigEndian: address.sin_port) : nil
    }
}

nonisolated struct LocalControlHTTPRequest {
    static let maximumHeaderBytes = 32 * 1024
    static let maximumBodyBytes = 1024 * 1024

    enum ParseResult {
        case incomplete
        case malformed(String)
        case request(LocalControlHTTPRequest)
    }

    let method: String
    let path: String
    /// Names lowercased.
    let headers: [String: String]
    let body: Data

    /// The body as a JSON object; empty when absent or not an object.
    var jsonBody: [String: Any] {
        guard !body.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }

    /// Parses what has arrived so far. `.incomplete` means wait for more.
    static func parse(_ data: Data) -> ParseResult {
        let tooLarge = ParseResult.malformed("HTTP request headers exceed the maximum size.")
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maximumHeaderBytes ? tooLarge : .incomplete
        }
        guard headerEnd.lowerBound - data.startIndex <= maximumHeaderBytes else { return tooLarge }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
            return .malformed("HTTP request headers must be UTF-8.")
        }

        var lines = head.components(separatedBy: "\r\n")[...]
        let requestLine = lines.popFirst()?.split(separator: " ", maxSplits: 2).map(String.init) ?? []
        guard requestLine.count == 3, !requestLine[0].isEmpty, !requestLine[1].isEmpty,
              requestLine[2].hasPrefix("HTTP/") else {
            return .malformed("HTTP request line is invalid.")
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .malformed("HTTP request header is invalid.") }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty else { return .malformed("HTTP request header name is missing.") }
            // Two lengths would let a proxy and this server disagree on
            // where the body ends (request smuggling).
            if name == "content-length", headers[name] != nil {
                return .malformed("Multiple Content-Length headers are not allowed.")
            }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let encoding = headers["transfer-encoding"], !encoding.isEmpty, encoding.lowercased() != "identity" {
            return .malformed("Transfer-Encoding is not supported.")
        }

        var bodyLength = 0
        if let declared = headers["content-length"] {
            guard !declared.isEmpty, declared.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let length = Int(declared), length <= maximumBodyBytes else {
                return .malformed("Content-Length is invalid or exceeds the maximum request size.")
            }
            bodyLength = length
        }

        let bodyStart = headerEnd.upperBound
        guard data.endIndex - bodyStart >= bodyLength else { return .incomplete }
        return .request(LocalControlHTTPRequest(
            method: requestLine[0].uppercased(),
            path: URLComponents(string: requestLine[1])?.path ?? requestLine[1],
            headers: headers,
            body: Data(data[bodyStart..<bodyStart + bodyLength])
        ))
    }
}

typealias LocalControlHandler = @MainActor (LocalControlCommand) async -> LocalControlResponse

/// Network callbacks run on one private queue; commands run on the main
/// actor through `handler`.
nonisolated final class LocalControlServer: @unchecked Sendable {
    private let port: UInt16
    private let handler: LocalControlHandler
    private let queue = DispatchQueue(label: "com.heymate.app.local-control")
    private var listener: NWListener?

    init(port: UInt16 = LocalControlPort.current, handler: @escaping LocalControlHandler) {
        self.port = port
        self.handler = handler
    }

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if let endpointPort = NWEndpoint.Port(rawValue: port) {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
        }
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [port = self.port] state in
                switch state {
                case .ready: HeyMateLog.log("HeyMate local control listening on http://127.0.0.1:\(port)")
                case .failed(let error): HeyMateLog.log("HeyMate local control failed: \(error)")
                default: break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            HeyMateLog.log("HeyMate local control could not start: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        guard Self.isLoopback(connection.endpoint) else {
            return reply(.error(403, "Loopback clients only"), on: connection)
        }
        read(from: connection, buffered: Data())
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else {
            // The listener only binds 127.0.0.1, so other shapes are local.
            return true
        }
        switch host {
        case .ipv4(let address): return address == .loopback || LocalControlLoopback.isAllowed(host: address.debugDescription)
        case .ipv6(let address): return address == .loopback || LocalControlLoopback.isAllowed(host: address.debugDescription)
        case .name(let name, _): return LocalControlLoopback.isAllowed(host: name)
        @unknown default: return false
        }
    }

    private func read(from connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { return self.reply(.error(400, error.localizedDescription), on: connection) }

            var buffer = buffered
            if let data { buffer.append(data) }
            switch LocalControlHTTPRequest.parse(buffer) {
            case .request(let request):
                self.respond(to: request, on: connection)
            case .malformed(let reason):
                self.reply(.error(400, reason), on: connection)
            case .incomplete:
                let limit = LocalControlHTTPRequest.maximumHeaderBytes + LocalControlHTTPRequest.maximumBodyBytes
                if isComplete || buffer.count > limit {
                    self.reply(.error(400, "Malformed HTTP request"), on: connection)
                } else {
                    self.read(from: connection, buffered: buffer)
                }
            }
        }
    }

    private func respond(to request: LocalControlHTTPRequest, on connection: NWConnection) {
        let unauthorized = LocalControlResponse.error(401, "Unauthorized")
        guard LocalControlAuth.isAuthorized(headers: request.headers) else { return reply(unauthorized, on: connection) }

        switch LocalControlRouter.route(method: request.method, path: request.path, json: request.jsonBody) {
        case .rejected(let status, let message):
            reply(.error(status, message), on: connection)
        case .accepted(.health):
            reply(LocalControlResponse(statusCode: 200, body: ["ok": true, "service": "heymate"]), on: connection)
        case .accepted(let command):
            if command.touchesConnectedAccounts,
               !LocalControlAuth.isAuthorizedForConnectedAccounts(
                   headers: request.headers,
                   expectedToken: LocalControlAuth.resolvedToken()
               ) {
                return reply(unauthorized, on: connection)
            }
            Task { @MainActor in
                let response = await self.handler(command)
                self.queue.async { self.reply(response, on: connection) }
            }
        }
    }

    private func reply(_ response: LocalControlResponse, on connection: NWConnection) {
        let json = (try? JSONSerialization.data(withJSONObject: response.body, options: [.sortedKeys])) ?? Data("{}".utf8)
        let head = [
            "HTTP/1.1 \(response.statusCode) \(Self.reason(for: response.statusCode))",
            "Content-Type: application/json",
            "Content-Length: \(json.count)",
            "Connection: close",
            "Access-Control-Allow-Origin: http://127.0.0.1",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type, Authorization, X-HeyMate-Token",
            "", "",
        ].joined(separator: "\r\n")
        connection.send(content: Data(head.utf8) + json, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func reason(for status: Int) -> String {
        [
            200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
            404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large",
            500: "Internal Server Error", 503: "Service Unavailable",
        ][status] ?? "OK"
    }
}
