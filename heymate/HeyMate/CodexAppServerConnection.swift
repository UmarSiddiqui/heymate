import Foundation

/// One owned, single-use JSONL connection. This is transport only: callers still
/// own thread/turn identity, sandbox policy, and approval presentation.
@MainActor
final class CodexAppServerConnection {
    enum Failure: Error, Equatable {
        case notReady, alreadyStarted, closed, malformedMessage, writeFailed, timedOut
        case remote(code: Int, message: String)
    }

    private enum State { case fresh, initializing, ready, closed }
    private nonisolated enum ServerID: Codable {
        case string(String), integer(Int64)

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let string = try? value.decode(String.self) { self = .string(string) }
            else { self = .integer(try value.decode(Int64.self)) }
        }

        func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .string(let string): try value.encode(string)
            case .integer(let integer): try value.encode(integer)
            }
        }
    }
    private nonisolated struct ServerEnvelopeID: Decodable { let id: ServerID }
    private nonisolated struct Rejection: Encodable {
        let id: ServerID
        let error: JSONValue
    }
    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeout: Task<Void, Never>
    }

    private var state: State = .fresh
    private var pending: [String: Pending] = [:]
    private var write: ((Data) -> Bool)?
    private var stop: (() -> Void)?
    private var process: HeadlessCLIProcess?
    var onNotification: ((String, JSONValue?) -> Void)?
    var onClose: ((Error) -> Void)?
    var onProcessStarted: (() -> Void)?

    isolated deinit {
        // Child's wait task retains its process wrapper until exit. Dropping the
        // connection must therefore stop it explicitly, not rely on ARC alone.
        stop?()
    }

    /// Existing CLI credentials and environment filtering stay owned by the
    /// standard process wrapper. No listener port or shared exec session.
    func launch(executableURL: URL, workspaceURL: URL,
                process ownedProcess: HeadlessCLIProcess? = nil,
                arguments: [String] = ["app-server", "--listen", "stdio://"],
                environmentKeysToRemove: [String] = []) async throws {
        guard state == .fresh else { throw Failure.alreadyStarted }
        try Task.checkCancellation()
        let child = ownedProcess ?? HeadlessCLIProcess()
        process = child
        do {
            try child.start(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectoryURL: workspaceURL,
                environmentKeysToRemove: environmentKeysToRemove,
                usesDuplexStandardInput: true,
                onLine: { [weak self] in self?.receive($0) },
                onExit: { [weak self] _ in self?.close() }
            )
            onProcessStarted?()
            try await connect(write: { child.writeToStandardInput($0) },
                              stop: { child.terminateThenKill() })
        } catch {
            child.terminateThenKill()
            close()
            throw error
        }
    }

    /// Writer receives one JSON object without a newline; process wrapper frames
    /// it exactly once. Injectable boundary also permits deterministic peer tests.
    func connect(write: @escaping (Data) -> Bool, stop: @escaping () -> Void,
                 timeout: Duration = .seconds(15)) async throws {
        guard state == .fresh else { throw Failure.alreadyStarted }
        self.write = write
        self.stop = stop
        state = .initializing
        do {
            _ = try await sendRequest(method: "initialize", params: .object([
                "clientInfo": .object(["name": .string("heymate"),
                                       "version": .string("1.0")])
            ]), timeout: timeout)
            try Task.checkCancellation()
            guard state == .initializing else { throw Failure.closed }
            try send(.object(["method": .string("initialized")]))
            guard state == .initializing else { throw Failure.closed }
            state = .ready
        } catch {
            close()
            throw error
        }
    }

    func request(method: String, params: JSONValue = .emptyObject,
                 timeout: Duration = .seconds(30)) async throws -> JSONValue {
        guard state == .ready else { throw Failure.notReady }
        guard method != "initialize", method != "initialized" else { throw Failure.alreadyStarted }
        return try await sendRequest(method: method, params: params, timeout: timeout)
    }

    private func sendRequest(method: String, params: JSONValue, timeout: Duration) async throws -> JSONValue {
        let id = UUID().uuidString
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await ContinuousClock().sleep(for: timeout) } catch { return }
                    self?.finish(id, result: .failure(Failure.timedOut))
                }
                pending[id] = Pending(continuation: continuation, timeout: timer)
                do {
                    try send(.object(["id": .string(id), "method": .string(method), "params": params]))
                } catch {
                    finish(id, result: .failure(error))
                    close()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id, result: .failure(CancellationError()))
            }
        }
    }

    private func send(_ value: JSONValue) throws {
        try writeEncoded(value)
    }

    private func writeEncoded(_ value: some Encodable) throws {
        guard state != .closed, let write else { throw Failure.closed }
        let data = try JSONEncoder().encode(value)
        guard write(data) else { throw Failure.writeFailed }
    }

    /// Reject ambiguous envelopes instead of accidentally accepting a request as
    /// a response. Unknown/late response IDs cannot complete a different request.
    func receive(_ line: String) {
        guard state != .fresh, state != .closed else { return }
        guard let value = JSONValue(jsonText: line), case .object(let fields) = value else {
            close(reason: Failure.malformedMessage); return
        }
        if let methodValue = fields["method"] {
            guard case .string(let method) = methodValue,
                  fields["result"] == nil, fields["error"] == nil else {
                close(reason: Failure.malformedMessage); return
            }
            if fields["id"] != nil {
                guard let id = try? JSONDecoder().decode(ServerEnvelopeID.self, from: Data(line.utf8)).id else {
                    close(reason: Failure.malformedMessage); return
                }
                // Until approval UI is integrated, fail closed. Never manufacture
                // an approval result or silently leave the server waiting.
                do {
                    try writeEncoded(Rejection(id: id, error: .object([
                        "code": .number(-32601),
                        "message": .string("Unsupported server request: \(method)")
                    ])))
                } catch { close(reason: error) }
            } else {
                onNotification?(method, fields["params"])
            }
            return
        }
        guard let exactID = try? JSONDecoder().decode(ServerEnvelopeID.self, from: Data(line.utf8)).id,
              (fields["result"] != nil) != (fields["error"] != nil) else {
            close(reason: Failure.malformedMessage); return
        }
        // Client-generated IDs are UUID strings. Numeric server IDs belong only
        // to server requests and cannot collide with our pending IDs.
        guard case .string(let id) = exactID, pending[id] != nil else { return }
        if let result = fields["result"] {
            finish(id, result: .success(result))
        } else if case .object(let error) = fields["error"],
                  case .number(let code) = error["code"], code.isFinite,
                  code.rounded() == code, code >= Double(Int32.min), code <= Double(Int32.max),
                  case .string(let message) = error["message"] {
            finish(id, result: .failure(Failure.remote(code: Int(code), message: message)))
        } else {
            close(reason: Failure.malformedMessage)
        }
    }

    private func finish(_ id: String, result: Result<JSONValue, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(with: result)
    }

    func close(reason: Error = Failure.closed) {
        guard state != .closed else { return }
        state = .closed
        let stop = self.stop
        self.stop = nil
        write = nil
        for id in Array(pending.keys) { finish(id, result: .failure(reason)) }
        stop?()
        onClose?(reason)
    }

    /// Runtime owners must await this before transferring a persisted session
    /// to another client; sending SIGTERM alone does not establish exclusivity.
    func shutdown() async -> Bool {
        close()
        return await process?.terminateAndWait() ?? true
    }
}
