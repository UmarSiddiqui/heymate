import Foundation

/// A chat retains one gateway connection. Reconnect replays acknowledged work;
/// it never resends a prompt whose acceptance was lost with its connection.
@MainActor
final class MateAgentServeSession {
    nonisolated enum Failure: Error, LocalizedError, Equatable {
        case invalidInput, invalidSession, busy, invalidAcceptance, incompleteTurn, overflow
        case replayGap, submissionUncertain, cancellationUnconfirmed, priorWorkRunning
        case remoteFailure(String)
        var errorDescription: String? {
            switch self {
            case .invalidInput: return "HeyMate Agent needs text, supported images, and an absolute workspace."
            case .invalidSession: return "HeyMate Agent returned a mismatched session or workspace."
            case .busy: return "This HeyMate Agent session already has work in progress."
            case .invalidAcceptance: return "HeyMate Agent did not accept the turn for streaming."
            case .incompleteTurn: return "HeyMate Agent ended without a verified complete response."
            case .overflow: return "HeyMate Agent exceeded a bounded event, request, or response limit."
            case .replayGap: return "HeyMate Agent recovery could not prove a complete event history. The prompt was not resent."
            case .priorWorkRunning: return "This restored HeyMate Agent session still has earlier work running. Review its progress or explicitly stop it before sending another task."
            case .submissionUncertain: return "The connection closed before prompt acceptance was confirmed. The prompt was not resent."
            case .cancellationUnconfirmed: return "HeyMate Agent interruption and owned-process shutdown could not be confirmed."
            case .remoteFailure(let text): return "HeyMate Agent stopped the turn: " + String(text.prefix(1_000))
            }
        }
    }
    nonisolated struct Identity: Equatable, Codable, Sendable { let runtimeID: String; let storedID: String }
    nonisolated struct Result: Equatable, Sendable {
        let text: String
        let status: String
        var completionSequence: Int? = nil
    }
    nonisolated struct Checkpoint: Equatable, Codable, Sendable {
        let identity: Identity
        let epoch: String
        let lastSequence: Int
    }
    nonisolated struct ServerRequest: Sendable {
        let localID: UUID
        let id: JSONValue
        let method: String
        let sessionID: String
        let params: JSONValue
    }
    private struct Turn {
        let id: UUID
        let continuation: CheckedContinuation<Result, Error>
        let timer: Task<Void, Never>
        var accepted = false
        var terminal: Swift.Result<Result, Error>?
    }
    private struct PendingRequest {
        let request: ServerRequest
        let task: Task<Void, Never>
        let timer: Task<Void, Never>
    }
    private var connection: MateAgentServeWebSocket
    private let reconnect: (@MainActor () throws -> MateAgentServeWebSocket)?
    private let stopOwner: (@MainActor () async -> Bool)?
    private let runtimeGuard: (@MainActor () async throws -> Void)?
    private let recoverDurable: (@MainActor (String, Int) async throws -> Result?)?
    private let cancellationConfirmationTimeout: Duration
    private var generation = UUID()
    private var turn: Turn?
    private var submission: Task<Void, Never>?
    private var recovery: Task<Void, Never>?
    private var cancellation: Task<Bool, Never>?
    private var preparing = false
    private var invalidated = false
    private var closing = false
    private var cancelling = false
    private var needsInterruption = false
    private var interruptedTerminal = false
    private var workspace: URL?
    private var epoch: String?
    private var lastSequence = 0
    private var buffered: [JSONValue] = []
    private var bufferedBytes = 0
    private var earlyRequests: [(JSONValue, String, JSONValue?)] = []
    private var requests: [String: PendingRequest] = [:]
    private var text = ""
    private(set) var identity: Identity?
    private(set) var hasPriorWorkInProgress = false
    var onRecoveredResult: ((Result) -> Void)?
    var isUsable: Bool { !invalidated && !closing && !cancelling }
    var checkpoint: Checkpoint? {
        guard let identity, let epoch else { return nil }
        return Checkpoint(identity: identity, epoch: epoch, lastSequence: lastSequence)
    }
    var onTextDelta: ((String) -> Void)?
    var onToolEvent: ((String, JSONValue?) -> Void)?
    var onProgress: ((String, JSONValue?) -> Void)?
    var onRequest: (@MainActor (ServerRequest) async -> JSONValue?)?
    var onRequestWithdrawn: ((UUID) -> Void)?
    var onCheckpointChanged: ((Checkpoint) -> Void)?
    var onPromptWillSubmit: (@MainActor () throws -> Void)?
    var onPromptAccepted: (@MainActor (Int?) throws -> Void)?
    var onConnectionState: ((String) -> Void)?
    var onUncertainCancellation: (() -> Void)?

    init(connection: MateAgentServeWebSocket,
         reconnect: (@MainActor () throws -> MateAgentServeWebSocket)? = nil,
         stopOwner: (@MainActor () async -> Bool)? = nil,
         runtimeGuard: (@MainActor () async throws -> Void)? = nil,
         recoverDurable: (@MainActor (String, Int) async throws -> Result?)? = nil,
         cancellationConfirmationTimeout: Duration = .seconds(5)) {
        self.connection = connection
        self.reconnect = reconnect
        self.stopOwner = stopOwner
        self.recoverDurable = recoverDurable
        self.runtimeGuard = runtimeGuard
        self.cancellationConfirmationTimeout = cancellationConfirmationTimeout > .zero && cancellationConfirmationTimeout <= .seconds(10)
            ? cancellationConfirmationTimeout : .seconds(5)
        bind(connection)
    }
    isolated deinit {
        submission?.cancel(); recovery?.cancel(); cancellation?.cancel()
        for item in requests.values { item.task.cancel(); item.timer.cancel() }
        turn?.timer.cancel()
        turn?.continuation.resume(throwing: MateAgentServeWebSocket.Failure.closed)
        connection.close()
    }
    private func bind(_ socket: MateAgentServeWebSocket) {
        generation = UUID()
        let owned = generation
        socket.onNotification = { [weak self] method, params in
            guard let self, self.generation == owned else { return }
            self.receive(method, params)
        }
        socket.onServerRequest = { [weak self] id, method, params in
            guard let self, self.generation == owned else { return false }
            return self.receiveRequest(id, method, params)
        }
        socket.onFailure = { [weak self] error in
            guard let self, self.generation == owned, !self.closing else { return }
            self.clearRequests()
            if self.cancelling { return }
            self.beginRecovery(error)
        }
    }

    func create(workspace: URL, idempotencyKey: UUID = UUID()) async throws -> Identity {
        try await prepare(workspace: workspace, storedID: nil, idempotencyKey: idempotencyKey,
                          checkpoint: nil, recoverPendingTurn: false, acceptedUserRowID: nil)
    }
    func resume(storedID: String, workspace: URL, checkpoint: Checkpoint? = nil,
                recoverPendingTurn: Bool = false, acceptedUserRowID: Int? = nil) async throws -> Identity {
        guard !storedID.isEmpty, storedID.utf8.count <= 1_024 else { throw Failure.invalidInput }
        return try await prepare(workspace: workspace, storedID: storedID, idempotencyKey: nil,
                                 checkpoint: checkpoint, recoverPendingTurn: recoverPendingTurn, acceptedUserRowID: acceptedUserRowID)
    }
    private func prepare(workspace: URL, storedID: String?, idempotencyKey: UUID?,
                         checkpoint saved: Checkpoint?, recoverPendingTurn pendingRecovery: Bool, acceptedUserRowID: Int?) async throws -> Identity {
        guard workspace.isFileURL, workspace.path.hasPrefix("/"), isUsable else { throw Failure.invalidInput }
        guard identity == nil, !preparing else { throw Failure.busy }
        preparing = true
        self.workspace = workspace
        defer { preparing = false }
        try await runtimeGuard?()
        try Task.checkCancellation()
        epoch = try await connection.waitUntilReady()
        var recoverPendingTurn = pendingRecovery
        var durableResult: Result?
        if recoverPendingTurn {
            guard let saved, saved.identity.storedID == storedID else { throw Failure.replayGap }
            if saved.epoch != epoch {
                guard let storedID, let acceptedUserRowID, acceptedUserRowID > 0, let recoverDurable,
                      let recovered = try await recoverDurable(storedID, acceptedUserRowID) else { throw Failure.replayGap }
                durableResult = recovered
                recoverPendingTurn = false
            }
        }
        _ = try await connection.request(method: "client.capabilities", params: .object(["server_requests": .bool(true)]))
        var params: [String: JSONValue] = storedID == nil ? ["cwd": .string(workspace.path)] : [
            "session_id": .string(storedID!), "omit_messages": .bool(true), "inline_images": .bool(false)
        ]
        if let idempotencyKey { params["idempotency_key"] = .string(idempotencyKey.uuidString) }
        let response = try await connection.request(method: storedID == nil ? "session.create" : "session.resume",
                                                    params: .object(params), timeout: .seconds(60))
        try Task.checkCancellation()
        let (result, fields) = try validateSession(response, workspace: workspace, creating: storedID == nil)
        identity = result
        hasPriorWorkInProgress = storedID != nil && (fields["running"] == .bool(true) || recoverPendingTurn)
        if storedID != nil {
            if recoverPendingTurn, saved?.identity.runtimeID != result.runtimeID { throw Failure.replayGap }
            let since = recoverPendingTurn ? (saved?.lastSequence ?? 0) : 0
            let replay = try await connection.request(method: "session.events.since", params: .object([
                "session_id": .string(result.runtimeID), "last_seen": .number(Double(since))
            ]))
            guard case .object(let data) = replay, data["epoch"] == epoch.map(JSONValue.string),
                  case .array(let events) = data["events"], events.count <= 512 else { throw Failure.replayGap }
            if recoverPendingTurn {
                guard data["truncated"] == .bool(false) else { throw Failure.replayGap }
                lastSequence = since
                for event in events { apply(event, replaying: true) }
                guard !invalidated else { throw Failure.replayGap }
                if hasPriorWorkInProgress, fields["running"] == .bool(false) { throw Failure.submissionUncertain }
            } else if let latest = Self.sequence(data["latest_seq"]) { lastSequence = latest }
            restoreRequests(data["open_requests"])
        }
        preparing = false
        drainBuffers()
        restoreRequests(fields["open_requests"])
        onConnectionState?("connected")
        publishCheckpoint()
        if let durableResult { onRecoveredResult?(durableResult) }
        return result
    }
    private func validateSession(_ value: JSONValue, workspace: URL, creating: Bool = false) throws -> (Identity, [String: JSONValue]) {
        guard case .object(let fields) = value else { throw Failure.invalidSession }
        let storedValue = creating ? fields["stored_session_id"] : (fields["session_key"] ?? fields["stored_session_id"])
        guard case .string(let runtime) = fields["session_id"], !runtime.isEmpty, runtime.utf8.count <= 1_024,
              case .string(let stored) = storedValue, !stored.isEmpty, stored.utf8.count <= 1_024,
              case .object(let info) = fields["info"], info["desktop_contract"] == .number(8),
              case .string(let cwd) = info["cwd"], Self.samePath(cwd, workspace.path) else { throw Failure.invalidSession }
        return (Identity(runtimeID: runtime, storedID: stored), fields)
    }

    /// Per-turn registration prevents old sessions retaining authority after navigation or Stop.
    /// Authentication is inherited from the owned backend, never written into profile config.
    func attachHeyMateBridge(name: String, command: String, script: String, scope: String, contextFile: URL) async throws {
        guard !hasPriorWorkInProgress else { throw Failure.priorWorkRunning }
        guard let identity, isUsable, turn == nil else { throw Failure.busy }
        let added = try await connection.request(method: "mcp.servers.add", params: .object([
            "name": .string(name), "config": .object([
                "command": .string(command), "args": .array([.string(script)]),
                "env": .object(["HEYMATE_TALK_SCOPE": .string(scope), "HEYMATE_SCOPED_ONLY": .string("1"),
                    "HEYMATE_BRIDGE_CONTEXT_FILE": .string(contextFile.path)])
            ])
        ]), timeout: .seconds(30))
        guard case .object(let fields) = added, fields["ok"] == .bool(true) else {
            throw Failure.remoteFailure("HeyMate could not attach Gmail connector tools to HeyMate Agent. Account connection was not changed.")
        }
        let reloaded = try await connection.request(method: "reload.mcp", params: .object([
            "session_id": .string(identity.runtimeID), "confirm": .bool(true)
        ]), timeout: .seconds(60))
        guard case .object(let refreshed) = reloaded, refreshed["status"] == .string("reloaded") else {
            throw Failure.remoteFailure("HeyMate Agent did not refresh HeyMate connector tools. No Gmail action was executed.")
        }
        let probe = try await connection.request(method: "mcp.servers.test", params: .object(["name": .string(name)]), timeout: .seconds(30))
        guard case .object(let tested) = probe, tested["ok"] == .bool(true),
              case .array(let tools) = tested["tools"], !tools.isEmpty else {
            throw Failure.remoteFailure("HeyMate integrations are enabled, but HeyMate Agent could not discover the scoped tools. No Gmail action was executed.")
        }
    }

    func removeHeyMateBridge(name: String) async {
        _ = try? await connection.request(method: "mcp.servers.remove", params: .object(["name": .string(name)]), timeout: .seconds(5))
    }

    func prompt(text request: String, images: [(data: Data, label: String)] = [],
                timeout: Duration = .seconds(300)) async throws -> Result {
        if let recovery { await recovery.value }
        guard !hasPriorWorkInProgress else { throw Failure.priorWorkRunning }
        guard let identity, isUsable, !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.utf8.count <= 262_144 else { throw Failure.invalidInput }
        guard !preparing, turn == nil else { throw Failure.busy }
        guard timeout > .zero, timeout <= .seconds(900) else { throw MateAgentServeWebSocket.Failure.invalidTimeout }
        guard images.count <= 8, images.reduce(0, { $0 + $1.data.count }) <= 4 * 1_024 * 1_024,
              images.allSatisfy({ Self.imageExtension($0.data) != nil }) else { throw Failure.invalidInput }
        preparing = true
        do {
            try await runtimeGuard?()
            try Task.checkCancellation()
        } catch {
            preparing = false
            throw error
        }
        do {
            for image in images {
                try Task.checkCancellation()
                let attached = try await connection.request(method: "image.attach_bytes", params: .object([
                    "session_id": .string(identity.runtimeID), "content_base64": .string(image.data.base64EncodedString()),
                    "filename": .string("image." + Self.imageExtension(image.data)!)
                ]), timeout: .seconds(30))
                guard case .object(let fields) = attached, fields["attached"] == .bool(true) else { throw Failure.invalidInput }
            }
        } catch {
            preparing = false
            // A partial attachment list must never leak into a later turn.
            close()
            throw error
        }
        preparing = false
        drainBuffers()
        let id = UUID()
        text = ""
        needsInterruption = false
        interruptedTerminal = false
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    let timer = Task { [weak self] in
                        do { try await ContinuousClock().sleep(for: timeout) } catch { return }
                        guard let self, self.turn?.id == id else { return }
                        self.finish(.failure(MateAgentServeWebSocket.Failure.timedOut))
                    }
                    turn = Turn(id: id, continuation: continuation, timer: timer)
                    submission = Task { [weak self] in
                        guard let self, self.turn?.id == id else { return }
                        do {
                            try Task.checkCancellation()
                            try self.onPromptWillSubmit?()
                            self.needsInterruption = true
                            let accepted = try await self.connection.request(method: "prompt.submit", params: .object([
                                "session_id": .string(identity.runtimeID), "text": .string(request)
                            ]), timeout: .seconds(60))
                            guard self.turn?.id == id else { return }
                            guard case .object(let fields) = accepted, fields["status"] == .string("streaming") else {
                                throw Failure.invalidAcceptance
                            }
                            try self.onPromptAccepted?(Self.sequence(fields["user_row_id"]))
                            self.turn?.accepted = true
                            if let terminal = self.turn?.terminal { self.finish(terminal) }
                        } catch {
                            guard self.turn?.id == id, self.recovery == nil else { return }
                            self.finish(.failure(error))
                        }
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, self.turn?.id == id else { return }
                    self.finish(.failure(CancellationError()))
                }
            }
        } catch {
            if needsInterruption, !(await cancelAndWait()) { throw Failure.cancellationUnconfirmed }
            throw error
        }
    }

    func cancel() { Task { _ = await cancelAndWait() } }
    @discardableResult
    func cancelAndWait() async -> Bool {
        if let cancellation { return await cancellation.value }
        guard needsInterruption || turn != nil || hasPriorWorkInProgress else { return true }
        cancelling = true
        clearRequests()
        recovery?.cancel(); recovery = nil
        finish(.failure(CancellationError()))
        let task = Task { [self] in
            var confirmed = false
            do {
                guard let identity, let workspace else { throw Failure.invalidSession }
                if !connection.isOpen {
                    guard let reconnect else { throw MateAgentServeWebSocket.Failure.closed }
                    connection = try reconnect(); bind(connection)
                    _ = try await connection.waitUntilReady(timeout: .seconds(5))
                }
                let reply = try await connection.request(method: "session.interrupt", params: .object([
                    "session_id": .string(identity.runtimeID)
                ]), timeout: .seconds(5))
                guard case .object(let ack) = reply, ack["status"] == .string("interrupted") else { throw Failure.cancellationUnconfirmed }
                let deadline = ContinuousClock.now.advanced(by: cancellationConfirmationTimeout)
                while !interruptedTerminal, ContinuousClock.now < deadline {
                    let snapshot = try await connection.request(method: "session.resume", params: .object([
                        "session_id": .string(identity.storedID), "omit_messages": .bool(true), "inline_images": .bool(false)
                    ]), timeout: min(.seconds(3), cancellationConfirmationTimeout))
                    let (_, fields) = try validateSession(snapshot, workspace: workspace)
                    if fields["running"] == .bool(false) { confirmed = true; break }
                    try await ContinuousClock().sleep(for: .milliseconds(100))
                }
                confirmed = confirmed || interruptedTerminal
            } catch { confirmed = false }
            if !confirmed {
                onUncertainCancellation?()
                if let stopOwner { confirmed = await stopOwner() }
            }
            needsInterruption = !confirmed
            invalidated = true
            closing = true
            clearRequests()
            connection.close()
            onConnectionState?(confirmed ? "cancelled" : "cancellation unconfirmed")
            return confirmed
        }
        cancellation = task
        let result = await task.value
        cancellation = nil
        return result
    }
    func close() {
        guard !closing else { return }
        // A generic cache cleanup is not consent to stop restored work.
        if hasPriorWorkInProgress { return }
        if needsInterruption || turn != nil {
            Task { _ = await cancelAndWait() }
            return
        }
        closing = true; invalidated = true
        recovery?.cancel(); recovery = nil
        clearRequests()
        connection.close()
        onConnectionState?("closed")
    }

    private func beginRecovery(_ original: Error) {
        guard recovery == nil, !closing, !cancelling else { return }
        guard let reconnect, let old = identity, let workspace, let expectedEpoch = epoch else {
            invalidated = true; finish(.failure(original)); return
        }
        onConnectionState?("reconnecting")
        recovery = Task { [self] in
            do {
                let replacement = try reconnect()
                try Task.checkCancellation()
                let previous = connection
                connection = replacement; bind(replacement)
                previous.close()
                let newEpoch = try await replacement.waitUntilReady(timeout: .seconds(5))
                guard newEpoch == expectedEpoch else { throw Failure.replayGap }
                _ = try await replacement.request(method: "client.capabilities", params: .object(["server_requests": .bool(true)]), timeout: .seconds(5))
                let snapshot = try await replacement.request(method: "session.resume", params: .object([
                    "session_id": .string(old.storedID), "omit_messages": .bool(true), "inline_images": .bool(false)
                ]), timeout: .seconds(10))
                let (restored, fields) = try validateSession(snapshot, workspace: workspace)
                guard restored.runtimeID == old.runtimeID else { throw Failure.replayGap }
                identity = restored
                let replay = try await replacement.request(method: "session.events.since", params: .object([
                    "session_id": .string(restored.runtimeID), "last_seen": .number(Double(lastSequence))
                ]), timeout: .seconds(10))
                guard case .object(let data) = replay, data["epoch"] == .string(expectedEpoch),
                      data["truncated"] == .bool(false), case .array(let events) = data["events"], events.count <= 512 else { throw Failure.replayGap }
                if turn != nil, turn?.accepted != true { throw Failure.submissionUncertain }
                try Task.checkCancellation()
                for event in events { apply(event, replaying: true) }
                guard !invalidated else { throw Failure.replayGap }
                recovery = nil
                drainBuffers()
                restoreRequests(data["open_requests"] ?? fields["open_requests"])
                if turn != nil, fields["running"] == .bool(false), turn?.terminal == nil { throw Failure.incompleteTurn }
                onConnectionState?("connected")
            } catch {
                recovery = nil
                guard !cancelling, !closing else { return }
                invalidated = true
                clearRequests()
                finish(.failure(error))
                // No replayed command or automatic prompt resubmission. The
                // prompt's error path awaits interruption or owned shutdown.
                if !needsInterruption { connection.close() }
                onConnectionState?("recovery failed")
            }
        }
    }

    private func receive(_ method: String, _ params: JSONValue?) {
        guard method == "event", !closing, case .object(let fields) = params else { return }
        if preparing || recovery != nil {
            let bytes = (try? JSONEncoder().encode(params)).map(\.count) ?? 0
            guard buffered.count < 512, bufferedBytes + bytes <= 4 * 1_024 * 1_024 else {
                finish(.failure(Failure.overflow)); invalidated = true; return
            }
            buffered.append(.object(fields)); bufferedBytes += bytes
            return
        }
        apply(.object(fields))
    }
    private func apply(_ params: JSONValue, replaying: Bool = false) {
        guard case .object(let fields) = params, fields["session_id"] == identity.map({ .string($0.runtimeID) }),
              case .string(let type) = fields["type"] else { return }
        if let seq = Self.sequence(fields["seq"]) {
            guard seq > lastSequence else { return }
            if lastSequence > 0, seq != lastSequence + 1 {
                if replaying { finish(.failure(Failure.replayGap)); invalidated = true }
                else { buffered.append(params); beginRecovery(Failure.replayGap) }
                return
            }
            lastSequence = seq
            publishCheckpoint()
        }
        let payload = fields["payload"]
        if type == "request.cancel", case .object(let body) = payload, let id = body["id"] {
            withdraw(id); return
        }
        if type == "message.complete", case .object(let body) = payload,
           case .string(let status) = body["status"], ["complete", "error", "interrupted"].contains(status) {
            if hasPriorWorkInProgress {
                hasPriorWorkInProgress = false
                let answer: String
                if case .string(let value) = body["text"], !value.isEmpty { answer = value }
                else if case .string(let value) = body["error"] { answer = value }
                else { answer = "Restored work ended without a final answer." }
                onRecoveredResult?(Result(text: answer, status: status, completionSequence: Self.sequence(fields["seq"])))
            }
            if status == "interrupted" { interruptedTerminal = true }
            needsInterruption = false
        }
        guard turn != nil else {
            if type.hasPrefix("tool.") || type.hasPrefix("subagent.") || type == "status.update" { progress(type, payload) }
            return
        }
        switch type {
        case "message.delta":
            guard case .object(let body) = payload, case .string(let delta) = body["text"] else { return }
            guard text.utf8.count + delta.utf8.count <= 1_024 * 1_024 else { finish(.failure(Failure.overflow)); return }
            text += delta; onTextDelta?(delta)
        case "message.complete":
            guard case .object(let body) = payload, body["status"] == .string("complete"),
                  case .string(let answer) = body["text"], !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  answer.utf8.count <= 1_024 * 1_024 else {
                let error: String
                if case .object(let body) = payload, case .string(let value) = body["error"] { error = value }
                else { error = "The turn was interrupted, incomplete, or returned no final text." }
                terminal(.failure(Failure.remoteFailure(error))); return
            }
            terminal(.success(Result(text: answer, status: "complete", completionSequence: Self.sequence(fields["seq"]))))
        case "error":
            let error: String
            if case .object(let body) = payload, case .string(let value) = body["message"] { error = value }
            else { error = "Unknown session error" }
            terminal(.failure(Failure.remoteFailure(error)))
        default:
            if type.hasPrefix("tool.") || type.hasPrefix("subagent.") || type == "status.update" || type == "message.interim" {
                progress(type, payload)
            }
        }
    }
    private func terminal(_ result: Swift.Result<Result, Error>) {
        guard turn != nil else { return }
        if turn?.accepted == true { finish(result) }
        else { turn?.terminal = result }
    }
    private func finish(_ result: Swift.Result<Result, Error>) {
        guard let waiting = turn else { return }
        turn = nil; waiting.timer.cancel(); submission?.cancel(); submission = nil
        waiting.continuation.resume(with: result)
    }
    private func progress(_ type: String, _ payload: JSONValue?) { onToolEvent?(type, payload); onProgress?(type, payload) }
    private func publishCheckpoint() { if let checkpoint { onCheckpointChanged?(checkpoint) } }
    private func drainBuffers() {
        let waiting = buffered.sorted { value, other in
            guard case .object(let a) = value, case .object(let b) = other else { return false }
            return (Self.sequence(a["seq"]) ?? 0) < (Self.sequence(b["seq"]) ?? 0)
        }
        buffered.removeAll(); bufferedBytes = 0
        for event in waiting { apply(event) }
        let early = earlyRequests; earlyRequests.removeAll()
        for (id, method, params) in early { _ = receiveRequest(id, method, params) }
    }

    private func receiveRequest(_ id: JSONValue, _ method: String, _ params: JSONValue?) -> Bool {
        guard ["approval", "clarify"].contains(method) else { return false }
        if preparing || recovery != nil {
            guard earlyRequests.count < 32 else { return false }
            earlyRequests.append((id, method, params)); return true
        }
        guard isUsable, !cancelling, let identity, case .object(let fields) = params,
              fields["session_id"] == .string(identity.runtimeID), requests.count < 32,
              let data = try? JSONEncoder().encode(fields), data.count <= 65_536 else { return false }
        let key = Self.key(id)
        if requests[key] != nil { return true }
        let request = ServerRequest(localID: UUID(), id: id, method: method, sessionID: identity.runtimeID, params: .object(fields))
        let owned = generation
        let callback = onRequest
        let timer = Task { [weak self] in
            do { try await ContinuousClock().sleep(for: .seconds(120)) } catch { return }
            await self?.answer(request, response: nil, generation: owned)
        }
        let task = Task { [weak self] in
            let response = await callback?(request)
            guard !Task.isCancelled else { return }
            await self?.answer(request, response: response, generation: owned)
        }
        requests[key] = PendingRequest(request: request, task: task, timer: timer)
        return true
    }
    private func answer(_ request: ServerRequest, response: JSONValue?, generation owned: UUID) async {
        guard owned == generation, isUsable, !cancelling, request.sessionID == identity?.runtimeID,
              let pending = requests.removeValue(forKey: Self.key(request.id)) else { return }
        let result = Self.safeResponse(request, response)
        do { try await connection.respond(to: request.id, result: result) }
        catch { if connection.isOpen { beginRecovery(error) } }
        pending.timer.cancel(); pending.task.cancel()
        onRequestWithdrawn?(request.localID)
    }
    private nonisolated static func safeResponse(_ request: ServerRequest, _ response: JSONValue?) -> JSONValue {
        guard case .object(let params) = request.params else { return .emptyObject }
        if request.method == "approval" {
            var once = false
            if case .object(let result) = response, result["choice"] == .string("once"),
               case .array(let choices) = params["choices"], choices.contains(.string("once")) { once = true }
            return .object(["choice": .string(once ? "once" : "deny"), "all": .bool(false)])
        }
        guard case .array(let questions) = params["questions"], questions.count <= 5,
              case .object(let result) = response, case .object(let answers) = result["answers"] else { return .emptyObject }
        var qids = Set<String>()
        for question in questions {
            guard case .object(let value) = question, case .string(let qid) = value["qid"], !qid.isEmpty,
                  qid.count <= 128, qids.insert(qid).inserted else { return .emptyObject }
        }
        guard answers.keys.allSatisfy(qids.contains), answers.values.allSatisfy({
            if case .string(let value) = $0 { return value.utf8.count <= 8_192 }; return $0 == .null
        }) else { return .emptyObject }
        var final = answers
        if case .object(let locked) = params["answers"] {
            for (key, value) in locked where qids.contains(key) { final[key] = value }
        }
        return .object(["answers": .object(final)])
    }
    private func restoreRequests(_ value: JSONValue?) {
        guard case .array(let items) = value else { return }
        guard items.count <= 32 else { connection.close(reason: Failure.overflow); return }
        for item in items {
            guard case .object(var fields) = item, let id = fields["id"], !connection.hasServerRequest(id) else { continue }
            fields["jsonrpc"] = .string("2.0")
            connection.receive(.object(fields))
        }
    }
    private func withdraw(_ id: JSONValue) {
        earlyRequests.removeAll { $0.0 == id }
        connection.withdrawServerRequest(id)
        guard let pending = requests.removeValue(forKey: Self.key(id)) else { return }
        pending.task.cancel(); pending.timer.cancel(); onRequestWithdrawn?(pending.request.localID)
    }
    private func clearRequests() {
        let waiting = requests; requests.removeAll()
        earlyRequests.removeAll()
        for item in waiting.values {
            item.task.cancel(); item.timer.cancel(); connection.withdrawServerRequest(item.request.id)
            onRequestWithdrawn?(item.request.localID)
        }
    }
    private nonisolated static func key(_ value: JSONValue) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self)
    }
    private nonisolated static func sequence(_ value: JSONValue?) -> Int? {
        guard case .number(let value) = value, value.isFinite, value >= 0, value.rounded() == value,
              value <= 9_007_199_254_740_991 else { return nil }
        return Int(value)
    }
    private nonisolated static func samePath(_ first: String, _ second: String) -> Bool {
        first.hasPrefix("/") && URL(fileURLWithPath: first).resolvingSymlinksInPath().standardizedFileURL.path
            == URL(fileURLWithPath: second).resolvingSymlinksInPath().standardizedFileURL.path
    }
    private nonisolated static func imageExtension(_ data: Data) -> String? {
        let value = [UInt8](data.prefix(12))
        if value.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        if value.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if value.starts(with: Array("GIF8".utf8)) { return "gif" }
        if value.count >= 12, value.prefix(4).elementsEqual("RIFF".utf8), value.suffix(4).elementsEqual("WEBP".utf8) { return "webp" }
        return nil
    }
}
