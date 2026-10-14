import Foundation

/// A single read-only planning turn and its in-flight input. The connection
/// must be exclusively owned and launched with the runtime's config isolation.
/// This type deliberately cannot grant write access or start execution.
@MainActor
final class CodexAppServerPlanningSession {
    struct Owner: Equatable, Sendable {
        let runID: UUID
        let attemptID: UUID
    }
    struct Identity: Equatable, Sendable {
        let owner: Owner
        let threadID: String
        let turnID: String
    }
    enum Failure: Error, Equatable {
        case alreadyStarted, invalidInput, invalidResponse, policyMismatch, bufferOverflow
    }
    enum Outcome: Equatable {
        case completed(plan: String), interrupted, failed(String)
    }
    enum SteerReceipt: Equatable {
        case pending, acknowledged(turnID: String), rejected(String), unknown, unavailable
    }
    enum InterruptReceipt: Equatable { case pending, requested, rejected(String), unknown, unavailable }
    private enum Phase { case fresh, openingThread, startingTurn, running, terminal }
    private struct Submission {
        let text: String
        let turnID: String
        var receipt: SteerReceipt
    }
    private struct Message {
        let id: String
        var text: String
        var phase: String?
    }

    let owner: Owner
    private let connection: CodexAppServerConnection
    private var phase: Phase = .fresh
    private(set) var identity: Identity?
    private(set) var outcome: Outcome?
    private var threadID: String?
    private var buffered: [(String, JSONValue)] = []
    private var bufferedBytes = 0
    private var messages: [Message] = []
    private var messageBytes = 0
    private var submissions: [UUID: Submission] = [:]
    private var interruptReceipt: InterruptReceipt?
    var onThreadIdentified: ((String) -> Void)?
    var onTextDelta: ((String) -> Void)?
    var onOutcome: ((Outcome) -> Void)?

    init(owner: Owner, connection: CodexAppServerConnection) {
        self.owner = owner
        self.connection = connection
        connection.onNotification = { [weak self] in self?.receive(method: $0, params: $1) }
        connection.onClose = { [weak self] _ in
            self?.finish(.failed("Planning connection closed before turn completion."))
        }
    }

    isolated deinit { connection.close() }

    /// Thread resume never silently becomes a fresh thread. Every new turn
    /// explicitly reapplies read-only policy instead of inheriting old writes.
    func start(text: String, workspaceURL: URL, resumeThreadID: String? = nil,
               model: String? = nil, effort: String? = nil,
               configurationOverrides: [String: JSONValue] = [:]) async throws -> Identity {
        guard phase == .fresh else { throw Failure.alreadyStarted }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              workspaceURL.isFileURL, workspaceURL.path.hasPrefix("/"),
              resumeThreadID == nil || resumeThreadID?.isEmpty == false else { throw Failure.invalidInput }
        phase = .openingThread
        var threadParams: [String: JSONValue] = [
            "cwd": .string(workspaceURL.path), "sandbox": .string("read-only"),
            "approvalPolicy": .string("on-request")
        ]
        if let model, !model.isEmpty { threadParams["model"] = .string(model) }
        if !configurationOverrides.isEmpty { threadParams["config"] = .object(configurationOverrides) }
        if let resumeThreadID { threadParams["threadId"] = .string(resumeThreadID) }
        do {
            let response = try await connection.request(method: resumeThreadID == nil ? "thread/start" : "thread/resume",
                                                        params: .object(threadParams))
            try Task.checkCancellation()
            guard phase == .openingThread,
                  case .object(let fields) = response,
                  case .object(let thread) = fields["thread"],
                  case .string(let id) = thread["id"], !id.isEmpty,
                  resumeThreadID == nil || resumeThreadID == id else { throw Failure.invalidResponse }
            guard case .object(let sandbox) = fields["sandbox"], sandbox["type"] == .string("readOnly"),
                  sandbox["networkAccess"] == nil || sandbox["networkAccess"] == .bool(false),
                  fields["approvalPolicy"] == .string("on-request") || fields["approvalPolicy"] == .string("untrusted") else {
                throw Failure.policyMismatch
            }
            threadID = id
            phase = .startingTurn
            onThreadIdentified?(id)
            var turnParams: [String: JSONValue] = [
                "threadId": .string(id), "input": Self.input(text),
                "cwd": .string(workspaceURL.path), "approvalPolicy": .string("on-request"),
                "sandboxPolicy": .object(["type": .string("readOnly"), "networkAccess": .bool(false)])
            ]
            if let model, !model.isEmpty { turnParams["model"] = .string(model) }
            if let effort, !effort.isEmpty { turnParams["effort"] = .string(effort) }
            let started = try await connection.request(method: "turn/start", params: .object(turnParams))
            try Task.checkCancellation()
            guard phase == .startingTurn,
                  case .object(let result) = started,
                  case .object(let turn) = result["turn"],
                  case .string(let turnID) = turn["id"], !turnID.isEmpty,
                  case .string(let status) = turn["status"],
                  ["inProgress", "completed", "failed", "interrupted"].contains(status) else { throw Failure.invalidResponse }
            let identity = Identity(owner: owner, threadID: id, turnID: turnID)
            self.identity = identity
            phase = .running
            let waiting = buffered
            buffered.removeAll()
            bufferedBytes = 0
            for (method, params) in waiting { receive(method: method, params: params) }
            // A terminal response is possible even without a separate event.
            if phase == .running, status != "inProgress" {
                consumeTerminal(turn)
            }
            return identity
        } catch {
            finish(error is CancellationError ? .interrupted : .failed("Could not start the planning turn."))
            connection.close()
            throw error
        }
    }

    /// Receipts describe delivery, not execution success. An unknown receipt is
    /// never replayed or converted into turn/start: remote acceptance may already
    /// have occurred. IDs bind exact text and the expected owned turn.
    func steer(text: String, expectedTurnID: String, messageID: UUID,
               timeout: Duration = .seconds(30)) async -> SteerReceipt {
        if let previous = submissions[messageID] {
            guard previous.text == text, previous.turnID == expectedTurnID else {
                return .rejected("Message ID already belongs to different input.")
            }
            return previous.receipt
        }
        guard phase == .running, let identity, identity.turnID == expectedTurnID else { return .unavailable }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected("Empty steering input.")
        }
        guard submissions.count < 256 else { return .rejected("Too many steering messages for this turn.") }
        submissions[messageID] = Submission(text: text, turnID: expectedTurnID, receipt: .pending)
        let receipt: SteerReceipt
        do {
            let response = try await connection.request(method: "turn/steer", params: .object([
                "threadId": .string(identity.threadID), "expectedTurnId": .string(expectedTurnID),
                "clientUserMessageId": .string(messageID.uuidString), "input": Self.input(text)
            ]), timeout: timeout)
            if case .object(let fields) = response, fields["turnId"] == .string(expectedTurnID) {
                receipt = .acknowledged(turnID: expectedTurnID)
            } else { receipt = .unknown }
        } catch CodexAppServerConnection.Failure.remote(_, let message) {
            receipt = .rejected(message)
        } catch {
            receipt = .unknown
        }
        submissions[messageID]?.receipt = receipt
        return receipt
    }

    /// RPC acknowledgement means cancellation was requested. Only the owned
    /// turn/completed notification establishes an interrupted terminal outcome.
    func interrupt(expectedTurnID: String, timeout: Duration = .seconds(15)) async -> InterruptReceipt {
        guard let identity, identity.turnID == expectedTurnID else { return .unavailable }
        if let interruptReceipt { return interruptReceipt }
        guard phase == .running else { return .unavailable }
        interruptReceipt = .pending
        let receipt: InterruptReceipt
        do {
            let response = try await connection.request(method: "turn/interrupt", params: .object([
                "threadId": .string(identity.threadID), "turnId": .string(identity.turnID)
            ]), timeout: timeout)
            if case .object = response { receipt = .requested }
            else { receipt = .unknown }
        } catch CodexAppServerConnection.Failure.remote(_, let message) {
            receipt = .rejected(message)
        } catch { receipt = .unknown }
        interruptReceipt = receipt
        return receipt
    }

    private static func input(_ text: String) -> JSONValue {
        .array([.object(["type": .string("text"), "text": .string(text)])])
    }

    private func receive(method: String, params: JSONValue?) {
        guard phase != .terminal, let params, case .object(let fields) = params,
              let threadID, fields["threadId"] == .string(threadID) else { return }
        if phase == .startingTurn {
            // Notifications may beat the turn/start response. Bind them only
            // after that response establishes the actual owned turn ID.
            let size = (try? JSONEncoder().encode(params).count) ?? 1_048_577
            guard buffered.count < 256, bufferedBytes + size <= 1_048_576 else {
                finish(.failed("Planning event buffer overflow."))
                connection.close(reason: Failure.bufferOverflow)
                return
            }
            buffered.append((method, params))
            bufferedBytes += size
            return
        }
        guard phase == .running, let identity else { return }
        if method == "turn/completed" {
            guard case .object(let turn) = fields["turn"], turn["id"] == .string(identity.turnID) else { return }
            consumeTerminal(turn)
            return
        }
        guard fields["turnId"] == .string(identity.turnID) else { return }
        if method == "item/agentMessage/delta", case .string(let itemID) = fields["itemId"],
           case .string(let delta) = fields["delta"] {
            let index = messages.firstIndex(where: { $0.id == itemID })
            guard reserveMessageBytes(delta.utf8.count, addsMessage: index == nil) else { return }
            if let index { messages[index].text += delta }
            else { messages.append(Message(id: itemID, text: delta)) }
            onTextDelta?(delta)
        } else if method == "item/completed", case .object(let item) = fields["item"] {
            consumeMessage(item)
        }
    }

    private func consumeMessage(_ item: [String: JSONValue]) {
        guard item["type"] == .string("agentMessage"), case .string(let id) = item["id"],
              case .string(let text) = item["text"] else { return }
        let phase: String?
        if case .string(let value) = item["phase"] { phase = value } else { phase = nil }
        let message = Message(id: id, text: text, phase: phase)
        let index = messages.firstIndex(where: { $0.id == id })
        let oldBytes = index.map { messages[$0].text.utf8.count } ?? 0
        guard reserveMessageBytes(text.utf8.count - oldBytes, addsMessage: index == nil) else { return }
        if let index { messages[index] = message }
        else { messages.append(message) }
    }

    private func reserveMessageBytes(_ change: Int, addsMessage: Bool) -> Bool {
        guard messageBytes + change <= 4_194_304, !addsMessage || messages.count < 512 else {
            finish(.failed("Planning text exceeded the supported limit."))
            connection.close(reason: Failure.bufferOverflow)
            return false
        }
        messageBytes += change
        return true
    }

    private func consumeTerminal(_ turn: [String: JSONValue]) {
        if case .array(let items) = turn["items"] {
            for case .object(let item) in items {
                guard phase == .running else { return }
                consumeMessage(item)
            }
        }
        switch turn["status"] {
        case .string("completed"):
            let finals = messages.filter { $0.phase == "final_answer" }
            let compatible = messages.filter { $0.phase == nil || $0.phase == "partial_answer" }
            let text = (finals.isEmpty ? compatible : finals).map(\.text).joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            finish(text.isEmpty ? .failed("The agent finished without producing a plan.") : .completed(plan: text))
        case .string("interrupted"): finish(.interrupted)
        case .string("failed"):
            if case .object(let error) = turn["error"], case .string(let message) = error["message"] {
                finish(.failed(message))
            } else { finish(.failed("Planning turn failed.")) }
        default:
            finish(.failed("Invalid terminal turn status."))
        }
    }

    private func finish(_ outcome: Outcome) {
        guard phase != .terminal else { return }
        phase = .terminal
        self.outcome = outcome
        buffered.removeAll()
        bufferedBytes = 0
        onOutcome?(outcome)
    }

    @discardableResult
    func shutdown() async -> Bool {
        if phase != .terminal { finish(.interrupted) }
        return await connection.shutdown()
    }
}
