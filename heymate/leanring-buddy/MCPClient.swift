//
//  MCPClient.swift
//  leanring-buddy
//
//  A minimal Model Context Protocol client over stdio.
//
//  This is the highest-leverage file in the connector layer: MCP is a
//  JSON-RPC 2.0 dialect with three calls that matter — `initialize`,
//  `tools/list`, `tools/call` — and implementing them once turns every
//  published MCP server into a HeyMate connector without a line of
//  per-service code.
//
//  Framing note: MCP stdio servers use newline-delimited JSON, one message
//  per line, on stdout. Anything a server writes to stderr is diagnostics
//  and must never be parsed as protocol — several popular servers print
//  npm noise there on first run, and treating that as a message is the
//  classic reason a client appears to hang on startup.
//

import Foundation

// MARK: - Wire types

struct MCPToolDefinition: Equatable, Sendable {
    let name: String
    let description: String
    /// Raw JSON Schema for the tool's arguments, passed through to the
    /// model untouched — we do not attempt to re-model arbitrary schemas.
    let inputSchemaJSON: String
}

struct MCPToolResult: Sendable {
    let textContent: String
    let isError: Bool
}

enum MCPClientError: LocalizedError {
    case launchFailed(String)
    case handshakeFailed(String)
    case timedOut(String)
    case serverError(String)
    case notRunning

    var errorDescription: String? {
        switch self {
        case .launchFailed(let detail): return "Could not start the server: \(detail)"
        case .handshakeFailed(let detail): return "Handshake failed: \(detail)"
        case .timedOut(let detail): return "Timed out \(detail)"
        case .serverError(let detail): return detail
        case .notRunning: return "The server is not running."
        }
    }
}

// MARK: - Client

/// One client per server process. An actor rather than a class because the
/// request/response correlation table and the stdin writer are shared
/// mutable state touched from both the reader task and callers.
actor MCPClient {

    /// Protocol revision we implement. Servers negotiate down if they must.
    private static let protocolVersion = "2025-06-18"

    /// Generous enough for `npx` to cold-download a server package the
    /// first time, short enough that a wedged server surfaces as an error
    /// rather than a spinner that never resolves.
    private static let handshakeTimeout: TimeInterval = 60

    /// Per-tool-call ceiling. Tool calls are user-visible work; if one
    /// takes longer than this something is wrong.
    private static let toolCallTimeout: TimeInterval = 120

    private let launchCommand: String
    private let environmentOverrides: [String: String]

    private var process: Process?
    private var standardInputPipe: Pipe?

    private var nextRequestID = 1
    private var pendingResponses: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    private(set) var discoveredTools: [MCPToolDefinition] = []
    private(set) var serverDisplayName: String?

    init(launchCommand: String, environmentOverrides: [String: String] = [:]) {
        self.launchCommand = launchCommand
        self.environmentOverrides = environmentOverrides
    }

    var isRunning: Bool { process?.isRunning == true }

    // MARK: Lifecycle

    /// Start the server, complete the MCP handshake, and cache its tool
    /// list. Returns the tools so the caller can show them immediately.
    @discardableResult
    func startAndDiscoverTools() async throws -> [MCPToolDefinition] {
        guard process == nil else { return discoveredTools }

        try launchProcess()
        startReadingResponses()

        let initializeResult = try await sendRequest(
            method: "initialize",
            parameters: [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": [:] as [String: Any]],
                "clientInfo": ["name": "HeyMate", "version": Self.clientVersion]
            ],
            timeout: Self.handshakeTimeout
        )

        if let serverInfo = initializeResult["serverInfo"] as? [String: Any],
           let name = serverInfo["name"] as? String {
            serverDisplayName = name
        }

        // MCP requires this notification before any other request.
        try sendNotification(method: "notifications/initialized")

        let toolsResult = try await sendRequest(
            method: "tools/list",
            parameters: [:],
            timeout: Self.handshakeTimeout
        )
        discoveredTools = Self.parseToolDefinitions(from: toolsResult)
        return discoveredTools
    }

    func stop() {
        standardOutputPipe?.fileHandleForReading.readabilityHandler = nil
        standardOutputPipe = nil
        // Fail every in-flight caller rather than leaving them suspended
        // forever when the process goes away.
        for (_, continuation) in pendingResponses {
            continuation.resume(throwing: MCPClientError.notRunning)
        }
        pendingResponses.removeAll()

        standardInputPipe?.fileHandleForWriting.closeFile()
        standardInputPipe = nil
        process?.terminate()
        process = nil
        discoveredTools = []
    }

    private static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private func launchProcess() throws {
        let trimmedCommand = launchCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            throw MCPClientError.launchFailed("no launch command configured")
        }

        let newProcess = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        // Run through a login shell so the command resolves against the
        // user's real PATH — `npx` and `uvx` live in nvm/homebrew paths
        // that a bare Process environment does not know about.
        newProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        newProcess.arguments = ["-lc", trimmedCommand]
        newProcess.standardInput = inputPipe
        newProcess.standardOutput = outputPipe
        newProcess.standardError = errorPipe

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        newProcess.environment = environment

        do {
            try newProcess.run()
        } catch {
            throw MCPClientError.launchFailed(error.localizedDescription)
        }

        process = newProcess
        standardInputPipe = inputPipe
        self.standardOutputPipe = outputPipe

        // Drain stderr so a chatty server cannot fill the pipe buffer and
        // deadlock. The content is diagnostics only; we never parse it.
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
    }

    private var standardOutputPipe: Pipe?

    // MARK: Reading

    /// Newline-delimited JSON reader.
    ///
    /// Uses `readabilityHandler` rather than a Task that calls
    /// `availableData` in a loop: `availableData` blocks the calling
    /// thread, and blocking a Swift concurrency cooperative thread starves
    /// the whole pool. The handler fires on a Dispatch-owned queue, and we
    /// hop back onto the actor to touch state.
    private func startReadingResponses() {
        guard let outputHandle = standardOutputPipe?.fileHandleForReading else { return }
        outputHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                Task { await self.handleServerExit() }
                return
            }
            Task { await self.appendToReadBuffer(chunk) }
        }
    }

    /// Accumulated bytes that have not yet formed a complete line. A server
    /// is free to flush mid-message, so partial lines must survive between
    /// reads.
    private var readBuffer = Data()

    private func appendToReadBuffer(_ chunk: Data) {
        readBuffer.append(chunk)
        while let newlineIndex = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = readBuffer[readBuffer.startIndex..<newlineIndex]
            readBuffer = Data(readBuffer[readBuffer.index(after: newlineIndex)...])
            guard !lineData.isEmpty else { continue }
            handleIncomingLine(Data(lineData))
        }
    }

    private func handleIncomingLine(_ lineData: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return   // Not protocol JSON — server noise; ignore by design.
        }
        // Server-initiated requests and notifications carry no `id` we are
        // waiting on. We do not implement sampling or roots, so they are
        // safely ignored.
        guard let requestID = message["id"] as? Int,
              let continuation = pendingResponses.removeValue(forKey: requestID) else { return }

        if let errorObject = message["error"] as? [String: Any] {
            let detail = (errorObject["message"] as? String) ?? "unknown server error"
            continuation.resume(throwing: MCPClientError.serverError(detail))
            return
        }
        continuation.resume(returning: (message["result"] as? [String: Any]) ?? [:])
    }

    private func handleServerExit() {
        for (_, continuation) in pendingResponses {
            continuation.resume(throwing: MCPClientError.notRunning)
        }
        pendingResponses.removeAll()
    }

    // MARK: Writing

    private func sendRequest(
        method: String,
        parameters: [String: Any],
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        guard isRunning else { throw MCPClientError.notRunning }

        let requestID = nextRequestID
        nextRequestID += 1

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": parameters
        ]

        // Arm the timeout before writing so a server that never answers
        // cannot strand the caller.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.failPendingRequest(requestID, method: method)
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[requestID] = continuation
            do {
                try write(payload)
            } catch {
                pendingResponses.removeValue(forKey: requestID)
                timeoutTask.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    private func failPendingRequest(_ requestID: Int, method: String) {
        guard let continuation = pendingResponses.removeValue(forKey: requestID) else { return }
        continuation.resume(throwing: MCPClientError.timedOut("waiting for \(method)"))
    }

    private func sendNotification(method: String, parameters: [String: Any] = [:]) throws {
        try write([
            "jsonrpc": "2.0",
            "method": method,
            "params": parameters
        ])
    }

    private func write(_ payload: [String: Any]) throws {
        guard let inputHandle = standardInputPipe?.fileHandleForWriting else {
            throw MCPClientError.notRunning
        }
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(UInt8(ascii: "\n"))
        do {
            try inputHandle.write(contentsOf: data)
        } catch {
            throw MCPClientError.notRunning
        }
    }

    // MARK: Tools

    func callTool(named toolName: String, arguments: [String: Any]) async throws -> MCPToolResult {
        let result = try await sendRequest(
            method: "tools/call",
            parameters: ["name": toolName, "arguments": arguments],
            timeout: Self.toolCallTimeout
        )
        return Self.parseToolResult(from: result)
    }

    // MARK: Parsing

    nonisolated static func parseToolDefinitions(from result: [String: Any]) -> [MCPToolDefinition] {
        guard let rawTools = result["tools"] as? [[String: Any]] else { return [] }
        return rawTools.compactMap { rawTool in
            guard let name = rawTool["name"] as? String else { return nil }
            let schemaJSON: String
            if let schema = rawTool["inputSchema"],
               let schemaData = try? JSONSerialization.data(withJSONObject: schema),
               let encoded = String(data: schemaData, encoding: .utf8) {
                schemaJSON = encoded
            } else {
                schemaJSON = "{\"type\":\"object\"}"
            }
            return MCPToolDefinition(
                name: name,
                description: (rawTool["description"] as? String) ?? "",
                inputSchemaJSON: schemaJSON
            )
        }
    }

    /// MCP results are a content array of typed blocks. We flatten the text
    /// blocks, which is what a language model consumes anyway; image and
    /// resource blocks are summarized rather than dropped silently.
    nonisolated static func parseToolResult(from result: [String: Any]) -> MCPToolResult {
        let isError = (result["isError"] as? Bool) ?? false
        guard let contentBlocks = result["content"] as? [[String: Any]] else {
            return MCPToolResult(textContent: "", isError: isError)
        }
        let renderedBlocks: [String] = contentBlocks.map { block in
            switch block["type"] as? String {
            case "text":
                return (block["text"] as? String) ?? ""
            case "image":
                return "[image returned by tool]"
            case "resource":
                let uri = ((block["resource"] as? [String: Any])?["uri"] as? String) ?? "resource"
                return "[resource: \(uri)]"
            default:
                return ""
            }
        }
        return MCPToolResult(
            textContent: renderedBlocks.filter { !$0.isEmpty }.joined(separator: "\n"),
            isError: isError
        )
    }
}
