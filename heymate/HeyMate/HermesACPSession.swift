import Foundation

/// One ACP session, with at most one prompt in flight. The wrapper does not
/// grant filesystem, terminal, MCP, or permanent permission capabilities.
@MainActor
final class HermesACPSession {
    nonisolated enum Failure: Error, Equatable, LocalizedError {
        case invalidInput, invalidResponse, notReady, busy, unsafeMode, overflow, invalidPermission

        var errorDescription: String? {
            switch self {
            case .invalidInput: return "Hermes could not accept this request. Use text or PNG, JPEG, GIF, or WebP images totalling at most 4 MB."
            case .invalidResponse: return "Hermes returned an invalid session or prompt response. The connection was stopped."
            case .notReady: return "Create or load a Hermes session before sending a request."
            case .busy: return "This Hermes session already has a request in progress. Wait or cancel it before sending another."
            case .unsafeMode: return "Hermes did not preserve ask-before-edits mode. The connection was stopped before continuing."
            case .overflow: return "Hermes exceeded the response size limit. The connection was stopped."
            case .invalidPermission: return "This Hermes permission request expired or the selected scope is unavailable. No approval was sent."
            }
        }
    }
    struct PromptResult: Equatable { let text: String; let stopReason: String }
    struct PermissionOption: Equatable {
        let id: String
        let name: String
        let kind: String
    }
    struct Permission {
        let localID: UUID
        let requestID: HermesACPConnection.ServerID
        let sessionID: String
        let toolCall: JSONValue
        /// Only single-action options are offered; session/permanent grants are excluded.
        let options: [PermissionOption]
    }
    private struct PendingPermission {
        let permission: Permission
        let turnID: UUID
        let timeout: Task<Void, Never>
    }
    private let connection: HermesACPConnection
    private var preparing = false
    private var turnID: UUID?
    private var answer = ""
    private var messageID: String?
    private var permissions: [UUID: PendingPermission] = [:]
    private(set) var sessionID: String?
    var onMessageChunk: ((String) -> Void)?
    var onToolUpdate: ((JSONValue) -> Void)?
    var onPermission: ((Permission) -> Void)?
    var onPermissionCleared: ((UUID) -> Void)?

    init(connection: HermesACPConnection) {
        self.connection = connection
        connection.onNotification = { [weak self] method, params in self?.receive(method, params) }
        connection.onServerRequest = { [weak self] id, method, params in
            self?.receiveRequest(id, method, params) ?? false
        }
        connection.onClose = { [weak self] _ in self?.clearPermissions(respond: false) }
    }

    func new(workspace: URL) async throws -> String {
        try await prepare(workspace: workspace, loading: nil)
    }

    func load(sessionID: String, workspace: URL) async throws -> String {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 1_024 else { throw Failure.invalidInput }
        return try await prepare(workspace: workspace, loading: sessionID)
    }

    private func prepare(workspace: URL, loading: String?) async throws -> String {
        guard workspace.isFileURL, workspace.path.hasPrefix("/") else { throw Failure.invalidInput }
        guard !preparing, sessionID == nil, turnID == nil else { throw Failure.busy }
        preparing = true
        defer { preparing = false }
        do {
            var params: [String: JSONValue] = ["cwd": .string(workspace.path), "mcpServers": .array([])]
            if let loading { params["sessionId"] = .string(loading) }
            let response = try await connection.request(method: loading == nil ? "session/new" : "session/load",
                                                        params: .object(params), timeout: .seconds(60))
            try Task.checkCancellation()
            guard case .object(let fields) = response,
                  case .object(let modes) = fields["modes"],
                  case .array(let available) = modes["availableModes"],
                  available.contains(where: { value in
                      if case .object(let mode) = value { return mode["id"] == .string("default") }
                      return false
                  }) else { throw Failure.unsafeMode }
            let id: String
            if let loading { id = loading }
            else {
                guard case .string(let created) = fields["sessionId"], !created.isEmpty,
                      created.utf8.count <= 1_024 else { throw Failure.invalidResponse }
                id = created
            }
            let mode = try await connection.request(method: "session/set_mode", params: .object([
                "sessionId": .string(id), "modeId": .string("default")
            ]))
            guard mode.isObject else { throw Failure.unsafeMode }
            try Task.checkCancellation()
            sessionID = id
            return id
        } catch {
            connection.close(reason: error)
            throw error
        }
    }

    func prompt(text: String, images: [(data: Data, label: String)] = [],
                timeout: Duration = .seconds(300)) async throws -> PromptResult {
        var blocks: [JSONValue] = text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(text)])]
        var bytes = 0
        for image in images {
            bytes += image.data.count
            guard bytes <= 4 * 1_024 * 1_024,
                  let mime = Self.imageMIME(image.data) else { throw Failure.invalidInput }
            if !image.label.isEmpty {
                blocks.append(.object(["type": .string("text"), "text": .string("Attached image: " + String(image.label.prefix(200)))]))
            }
            blocks.append(.object(["type": .string("image"), "mimeType": .string(mime),
                                   "data": .string(image.data.base64EncodedString())]))
        }
        return try await prompt(blocks: blocks, timeout: timeout)
    }

    func prompt(blocks: [JSONValue], timeout: Duration = .seconds(300)) async throws -> PromptResult {
        guard let sessionID else { throw Failure.notReady }
        guard !preparing, turnID == nil else { throw Failure.busy }
        guard !blocks.isEmpty, blocks.count <= 32,
              let encoded = try? JSONEncoder().encode(blocks), encoded.count <= 6 * 1_024 * 1_024,
              blocks.allSatisfy(Self.validPromptBlock) else { throw Failure.invalidInput }
        guard timeout > .zero, timeout <= .seconds(900) else { throw HermesACPConnection.Failure.invalidTimeout }
        let current = UUID()
        turnID = current
        answer = ""
        messageID = nil
        defer {
            clearPermissions(respond: true)
            if turnID == current { turnID = nil }
        }
        do {
            let result = try await connection.request(method: "session/prompt", params: .object([
                "sessionId": .string(sessionID), "prompt": .array(blocks)
            ]), timeout: timeout)
            try Task.checkCancellation()
            guard turnID == current, case .object(let fields) = result,
                  case .string(let reason) = fields["stopReason"],
                  ["end_turn", "max_tokens", "max_turn_requests", "refusal", "cancelled"].contains(reason) else {
                throw Failure.invalidResponse
            }
            return PromptResult(text: answer, stopReason: reason)
        } catch {
            // A timed-out/cancelled RPC is not proof that the remote turn stopped.
            // Close its owned process before this session can be reused.
            try? connection.notify(method: "session/cancel", params: .object(["sessionId": .string(sessionID)]))
            connection.close(reason: error)
            throw error
        }
    }

    func cancel() {
        guard let sessionID, turnID != nil else { return }
        clearPermissions(respond: true)
        try? connection.notify(method: "session/cancel", params: .object(["sessionId": .string(sessionID)]))
        connection.close(reason: CancellationError())
    }

    func respondToPermission(localID: UUID, optionID: String?) throws {
        guard let pending = permissions[localID], pending.turnID == turnID,
              pending.permission.sessionID == sessionID else { throw Failure.invalidPermission }
        if let optionID, !pending.permission.options.contains(where: { $0.id == optionID }) {
            throw Failure.invalidPermission
        }
        let outcome: JSONValue = optionID.map {
            .object(["outcome": .string("selected"), "optionId": .string($0)])
        } ?? .object(["outcome": .string("cancelled")])
        try connection.respond(to: pending.permission.requestID, result: .object(["outcome": outcome]))
        permissions.removeValue(forKey: localID)?.timeout.cancel()
        onPermissionCleared?(localID)
    }

    private func receive(_ method: String, _ params: JSONValue?) {
        guard method == "session/update", turnID != nil,
              case .object(let fields) = params, fields["sessionId"] == sessionID.map(JSONValue.string),
              case .object(let update) = fields["update"], case .string(let kind) = update["sessionUpdate"] else { return }
        switch kind {
        case "agent_message_chunk":
            guard case .object(let content) = update["content"], content["type"] == .string("text"),
                  case .string(let text) = content["text"] else { return }
            let incomingID: String?
            if case .string(let id) = update["messageId"] { incomingID = id }
            else { incomingID = nil }
            let separator = incomingID != nil && messageID != nil && incomingID != messageID && !answer.isEmpty ? "\n\n" : ""
            if let incomingID { messageID = incomingID }
            let delta = separator + text
            guard answer.utf8.count + delta.utf8.count <= 1_024 * 1_024 else {
                connection.close(reason: Failure.overflow); return
            }
            answer += delta
            onMessageChunk?(delta)
        case "tool_call", "tool_call_update":
            onToolUpdate?(.object(update))
        case "current_mode_update":
            if update["currentModeId"] != .string("default") { connection.close(reason: Failure.unsafeMode) }
        default: break
        }
    }

    private func receiveRequest(_ id: HermesACPConnection.ServerID, _ method: String, _ params: JSONValue?) -> Bool {
        guard method == "session/request_permission" else { return false }
        guard let turnID, let sessionID, case .object(let fields) = params,
              fields["sessionId"] == .string(sessionID), let tool = fields["toolCall"], tool.isObject,
              case .array(let rawOptions) = fields["options"], permissions.count < 32 else {
            deny(id); return true
        }
        let options = rawOptions.compactMap { value -> PermissionOption? in
            guard case .object(let option) = value, case .string(let id) = option["optionId"],
                  case .string(let name) = option["name"], case .string(let kind) = option["kind"],
                  ["allow_once", "reject_once"].contains(kind), !id.isEmpty else { return nil }
            return PermissionOption(id: id, name: name, kind: kind)
        }
        guard let onPermission, !options.isEmpty, Set(options.map(\.id)).count == options.count else {
            deny(id); return true
        }
        let localID = UUID()
        let permission = Permission(localID: localID, requestID: id, sessionID: sessionID, toolCall: tool, options: options)
        let timer = Task { [weak self] in
            do { try await ContinuousClock().sleep(for: .seconds(120)) } catch { return }
            try? self?.respondToPermission(localID: localID, optionID: nil)
        }
        permissions[localID] = PendingPermission(permission: permission, turnID: turnID, timeout: timer)
        onPermission(permission)
        return true
    }

    private func deny(_ id: HermesACPConnection.ServerID) {
        do { try connection.respond(to: id, result: .object(["outcome": .object(["outcome": .string("cancelled")])])) }
        catch { connection.close(reason: error) }
    }

    private func clearPermissions(respond: Bool) {
        let waiting = permissions
        permissions.removeAll()
        for (id, pending) in waiting {
            pending.timeout.cancel()
            if respond { deny(pending.permission.requestID) }
            onPermissionCleared?(id)
        }
    }

    private nonisolated static func validPromptBlock(_ block: JSONValue) -> Bool {
        guard case .object(let fields) = block, case .string(let type) = fields["type"] else { return false }
        if type == "text", case .string(let text) = fields["text"] { return !text.isEmpty && text.utf8.count <= 262_144 }
        if type == "image", case .string(let data) = fields["data"], case .string(let mime) = fields["mimeType"] {
            return ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime)
                && !data.isEmpty && Data(base64Encoded: data) != nil
        }
        return false
    }

    private nonisolated static func imageMIME(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if bytes.count >= 12, bytes.prefix(4).elementsEqual("RIFF".utf8), bytes.suffix(4).elementsEqual("WEBP".utf8) { return "image/webp" }
        return nil
    }
}
