//
//  CuaDriverClient.swift
//  HeyMate
//
//  Talks to Cua's driver over MCP stdio, in-process for one drive.
//
//  The driver runs as HeyMate's child in embedded mode, so macOS attributes
//  its Accessibility and Screen Recording use to HeyMate's own grants rather
//  than to CuaDriver.app's separate identity. Telemetry is off.
//

import Foundation
import HeyMateComputerUse

enum CuaDriverClientError: LocalizedError {
    case notInstalled
    case exited
    case toolFailed(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Cua's driver isn't installed"
        case .exited: return "Cua's driver stopped"
        case .toolFailed(let message): return message
        case .malformed(let what): return "Cua's driver sent \(what)"
        }
    }
}

/// One JSON-RPC line protocol session with a `cua-driver mcp` child.
@MainActor
final class CuaDriverClient {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var started = false
    private var stopping = false
    private let cleanupOnStop: Bool
    private let requestTimeout: Duration
    private var windowReadContract = CuaDriverWindowReadContract(inputSchema: [:])

    static let embeddedArguments = ["mcp", "--direct", "--embedded", "--no-overlay"]
    static let environment = [
        "CUA_DRIVER_EMBEDDED": "1",
        "CUA_DRIVER_TELEMETRY_ENABLED": "false",
        "CUA_TELEMETRY_ENABLED": "false",
    ]
    /// Per call. A drag or a slow AX walk stays well inside this.
    static let callTimeout: Duration = .seconds(20)

    /// The installed, current driver, or nil.
    static var installedExecutable: URL? {
        CuaDriverSetup.shared.installation.readyExecutable
            ?? CuaDriverInstallation.candidateExecutables(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    init(executable: URL, timeout: Duration? = nil, cleanupOnStop: Bool = false) {
        self.cleanupOnStop = cleanupOnStop
        requestTimeout = timeout ?? Self.callTimeout
        process.executableURL = executable
        process.arguments = Self.embeddedArguments
        var environment = ProcessInfo.processInfo.environment
        Self.environment.forEach { environment[$0.key] = $0.value }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    func start() async throws {
        guard !stopping else { throw CancellationError() }
        guard !started else { return }
        started = true
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.failAll(CuaDriverClientError.exited) }
        }
        try process.run()
        _ = try await request("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [:],
            "clientInfo": ["name": "heymate-drive", "version": "1"],
        ])
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        // Negotiate the actual installed surface: older drivers return both
        // tree forms by default and reject the new tree_format argument.
        var cursor: String?
        repeat {
            let listing = try await request("tools/list", cursor.map { ["cursor": $0] } ?? [:])
            if let tools = listing["tools"] as? [[String: Any]],
               let windowTool = tools.first(where: { $0["name"] as? String == "get_window_state" }),
               let schema = windowTool["inputSchema"] as? [String: Any] {
                windowReadContract = CuaDriverWindowReadContract(inputSchema: schema)
                break
            }
            cursor = listing["nextCursor"] as? String
        } while cursor != nil
    }

    func stop() {
        guard !stopping else { return }
        stopping = true
        output.fileHandleForReading.readabilityHandler = nil
        if cleanupOnStop {
            // Cua tears down owned Chromium profiles on transport EOF. SIGTERM
            // skips that lifecycle cleanup and leaves the browser behind.
            try? input.fileHandleForWriting.close()
        } else if process.isRunning { process.terminate() }
        failAll(CancellationError())
    }

    /// Calls a tool and returns its `structuredContent` (or an empty object).
    /// A tool-level error becomes `toolFailed` with the driver's own words.
    @discardableResult
    func call(_ tool: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        let arguments = tool == "get_window_state" ? windowReadContract.arguments(arguments) : arguments
        let result = try await request("tools/call", ["name": tool, "arguments": arguments])
        let structured = result["structuredContent"] as? [String: Any] ?? [:]
        if result["isError"] as? Bool == true || structured["effect"] as? String == "refused"
            || ["error", "refused"].contains(structured["status"] as? String ?? "") {
            let text = (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ")
            let summary = structured["summary"] as? String
            throw CuaDriverClientError.toolFailed(summary ?? (text?.isEmpty == false ? text! : "\(tool) failed"))
        }
        return structured
    }

    // MARK: Wire

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        guard !stopping else { throw CancellationError() }
        guard process.isRunning || !started else { throw CuaDriverClientError.exited }
        nextID += 1
        let id = nextID
        let timeout = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.requestTimeout)
            guard !Task.isCancelled, self.pending[id] != nil else { return }
            self.resolve(id, with: .failure(CuaDriverClientError.toolFailed("\(method) timed out")))
            // This direct, embedded runtime belongs to one drive. Stopping
            // only the waiter would leave a timed-out action running unseen.
            self.stop()
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = continuation
                send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.pending[id] != nil else { return }
                self.stop()
            }
        }
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        input.fileHandleForWriting.write(data + Data([0x0A]))
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let id = message["id"] as? Int else { continue }
            if let error = message["error"] as? [String: Any] {
                resolve(id, with: .failure(CuaDriverClientError.toolFailed(error["message"] as? String ?? "error")))
            } else {
                resolve(id, with: .success(message["result"] as? [String: Any] ?? [:]))
            }
        }
    }

    private func resolve(_ id: Int, with result: Result<[String: Any], Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func failAll(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: error) }
    }
}
