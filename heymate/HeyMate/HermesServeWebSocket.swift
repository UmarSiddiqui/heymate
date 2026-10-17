import Foundation

/// Native JSON-RPC WebSocket transport to an authenticated, owned loopback
/// serve backend. Tokens exist only inside requests, never public URLs/logs.
@MainActor
final class HermesServeWebSocket {
    nonisolated enum Failure: Error, Equatable, LocalizedError {
        case notConnected, closed, malformedMessage, timedOut, invalidTimeout, overflow
        case remote(code: Int, message: String)
        var errorDescription: String? {
            switch self {
            case .notConnected: return "The Hermes gateway WebSocket is not connected."
            case .closed: return "The Hermes gateway WebSocket closed before completing the request."
            case .malformedMessage: return "The Hermes gateway returned invalid JSON-RPC. The socket was closed."
            case .timedOut: return "The Hermes gateway request exceeded its time limit."
            case .invalidTimeout: return "Hermes request time limit must be greater than zero and at most 15 minutes."
            case .overflow: return "The Hermes gateway exceeded its bounded message or request limit."
            case .remote(let code, let message): return "Hermes rejected the request (\(code)): " + String(message.prefix(1_000))
            }
        }
    }
    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timer: Task<Void, Never>
        let send: Task<Void, Never>
    }
    private let socket: URLSessionWebSocketTask?
    private let redactionToken: String?
    private var testWrite: ((JSONValue) throws -> Void)?
    private var receiver: Task<Void, Never>?
    private var pending: [String: Pending] = [:]
    private var connected = false
    private var closed = false
    private var serverRequests: [String: JSONValue] = [:]
    private(set) var replayEpoch: String?
    var isOpen: Bool { connected && !closed }
    var onNotification: ((String, JSONValue?) -> Void)?
    var onServerRequest: ((JSONValue, String, JSONValue?) -> Bool)?
    var onClosed: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    init(baseURL: URL, token: String, session: URLSession) {
        redactionToken = token
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        socket = session.webSocketTask(with: request)
        socket?.maximumMessageSize = 2 * 1_024 * 1_024
    }
    /// In-memory peer seam; no network/token required for protocol regression tests.
    init(write: @escaping (JSONValue) throws -> Void) {
        redactionToken = nil
        replayEpoch = "test-epoch"
        socket = nil
        testWrite = write
    }
    isolated deinit {
        receiver?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        for request in pending.values {
            request.timer.cancel(); request.send.cancel()
            request.continuation.resume(throwing: Failure.closed)
        }
    }

    func connect() {
        guard !connected, !closed else { return }
        connected = true
        guard let socket else { return }
        socket.resume()
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, !self.closed else { return }
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: throw Failure.malformedMessage
                    }
                    guard data.count <= 2 * 1_024 * 1_024 else { throw Failure.overflow }
                    self.receive(try JSONDecoder().decode(JSONValue.self, from: data))
                }
            } catch {
                guard let self, !self.closed else { return }
                self.close(reason: error)
            }
        }
    }

    func request(method: String, params: JSONValue = .emptyObject,
                 timeout: Duration = .seconds(30)) async throws -> JSONValue {
        guard connected, !closed else { throw Failure.notConnected }
        guard timeout > .zero, timeout <= .seconds(900) else { throw Failure.invalidTimeout }
        guard pending.count < 128 else { throw Failure.overflow }
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(for: timeout) } catch { return }
                    self?.finish(id, .failure(Failure.timedOut))
                }
                let send = Task { [weak self] in
                    guard let self, self.pending[id] != nil else { return }
                    do {
                        try Task.checkCancellation()
                        try await self.send(.object(["jsonrpc": .string("2.0"), "id": .string(id),
                                                    "method": .string(method), "params": params]))
                    } catch {
                        guard self.pending[id] != nil else { return }
                        self.close(reason: error)
                    }
                }
                pending[id] = Pending(continuation: continuation, timer: timer, send: send)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) }
        }
    }

    func notify(method: String, params: JSONValue = .emptyObject) async throws {
        try await send(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
    }
    private func send(_ value: JSONValue) async throws {
        guard connected, !closed else { throw Failure.notConnected }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 8 * 1_024 * 1_024 else { throw Failure.overflow }
        if let testWrite { try testWrite(value); return }
        guard let socket else { throw Failure.notConnected }
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func receive(_ value: JSONValue) {
        guard connected, !closed else { return }
        guard case .object(let fields) = value, fields["jsonrpc"] == .string("2.0") else {
            close(reason: Failure.malformedMessage); return
        }
        if let methodValue = fields["method"] {
            guard case .string(let method) = methodValue, fields["result"] == nil, fields["error"] == nil else {
                close(reason: Failure.malformedMessage); return
            }
            if let id = fields["id"] {
                guard Self.validID(id) else { close(reason: Failure.malformedMessage); return }
                let key = Self.idKey(id)
                if let existing = serverRequests[key] {
                    guard existing == value else { close(reason: Failure.malformedMessage); return }
                    return
                }
                guard serverRequests.count < 64 else { close(reason: Failure.overflow); return }
                serverRequests[key] = value
                if onServerRequest?(id, method, fields["params"]) != true {
                    Task { [weak self] in
                        do { try await self?.reject(to: id) }
                        catch { self?.close(reason: error) }
                    }
                }
            } else {
                if method == "event", case .object(let params) = fields["params"],
                   params["type"] == .string("gateway.ready"), case .object(let payload) = params["payload"],
                   case .string(let epoch) = payload["replay_epoch"], !epoch.isEmpty, epoch.count <= 128 {
                    replayEpoch = epoch
                }
                onNotification?(method, fields["params"])
            }
            return
        }
        guard let exactID = fields["id"], Self.validID(exactID),
              (fields["result"] != nil) != (fields["error"] != nil) else {
            close(reason: Failure.malformedMessage); return
        }
        guard case .string(let id) = exactID, pending[id] != nil else { return }
        if let result = fields["result"] { finish(id, .success(result)) }
        else if case .object(let error) = fields["error"], case .number(let code) = error["code"],
                code.isFinite, code.rounded() == code, code >= Double(Int32.min), code <= Double(Int32.max),
                case .string(let message) = error["message"] {
            let safeMessage = redactionToken.map { message.replacingOccurrences(of: $0, with: "[redacted]") } ?? message
            finish(id, .failure(Failure.remote(code: Int(code), message: safeMessage)))
        } else { close(reason: Failure.malformedMessage) }
    }
    func waitUntilReady(timeout: Duration = .seconds(10)) async throws -> String {
        guard timeout > .zero, timeout <= .seconds(30) else { throw Failure.invalidTimeout }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while replayEpoch == nil {
            try Task.checkCancellation()
            guard isOpen else { throw Failure.closed }
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
            try await ContinuousClock().sleep(for: .milliseconds(20))
        }
        return replayEpoch!
    }

    func respond(to id: JSONValue, result: JSONValue) async throws {
        let key = Self.idKey(id)
        guard serverRequests.removeValue(forKey: key) != nil else { throw Failure.notConnected }
        try await send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }
    func hasServerRequest(_ id: JSONValue) -> Bool { serverRequests[Self.idKey(id)] != nil }
    func withdrawServerRequest(_ id: JSONValue) { serverRequests.removeValue(forKey: Self.idKey(id)) }
    private func reject(to id: JSONValue) async throws {
        guard serverRequests.removeValue(forKey: Self.idKey(id)) != nil else { return }
        try await send(.object(["jsonrpc": .string("2.0"), "id": id,
                               "error": .object(["code": .number(-32601), "message": .string("Unsupported client request")])]))
    }
    private nonisolated static func idKey(_ value: JSONValue) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self)
    }

    private nonisolated static func validID(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let value): return !value.isEmpty && value.utf8.count <= 1_024
        case .number(let value): return value.isFinite && value.rounded() == value && abs(value) <= 9_007_199_254_740_991
        default: return false
        }
    }
    private func finish(_ id: String, _ result: Result<JSONValue, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timer.cancel(); request.send.cancel()
        request.continuation.resume(with: result)
    }
    func close(reason: Error = Failure.closed) {
        guard !closed else { return }
        // URLSession errors may include the authenticated query URL in userInfo.
        // Never propagate that NSError into logs, tests, or the native UI.
        let safeReason: Error
        if reason is CancellationError { safeReason = CancellationError() }
        else if let failure = reason as? Failure { safeReason = failure }
        else { safeReason = Failure.closed }
        closed = true
        connected = false
        receiver?.cancel()
        receiver = nil
        socket?.cancel(with: .goingAway, reason: nil)
        testWrite = nil
        serverRequests.removeAll()
        for id in Array(pending.keys) { finish(id, .failure(safeReason)) }
        onFailure?(safeReason)
        onClosed?()
    }
}
