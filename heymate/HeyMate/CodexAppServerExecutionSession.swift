import Foundation

/// One already-approved execution turn. Planning remains a separate read-only
/// type. Every request/event is bound to this runner's resumed thread and turn.
@MainActor
final class CodexAppServerExecutionSession {
    struct Identity: Equatable { let threadID: String; let turnID: String }
    enum Outcome: Equatable { case completed(String), failed(String), interrupted }
    enum Failure: Error { case invalidInput, invalidResponse, policyMismatch, overflow }
    struct Approval {
        let localID: String
        let requestID: CodexAppServerConnection.ServerID
        let details: String
        let itemID: String
    }
    private enum Phase { case fresh, resuming, starting, running, terminal }
    private enum Buffered {
        case notification(String, JSONValue)
        case request(CodexAppServerConnection.ServerID, String, JSONValue)
    }
    private struct Submission {
        let text: String
        let turnID: String
        var receipt: DetachedLiveInputReceipt.Status
    }
    private let connection: CodexAppServerConnection
    private var phase: Phase = .fresh
    private var threadID: String?
    private var buffered: [Buffered] = []
    private var bufferedBytes = 0
    private var approvals: [Approval] = []
    private var presentedApprovalID: String?
    private var submissions: [UUID: Submission] = [:]
    private var itemDetails: [String: String] = [:]
    private var answer = ""
    private var finalAnswer = ""
    private(set) var identity: Identity?
    private(set) var outcome: Outcome?
    var onApproval: ((Approval) -> Void)?
    var onApprovalCleared: ((String) -> Void)?
    var onProgress: ((String) -> Void)?
    var onOutcome: ((Outcome) -> Void)?

    init(connection: CodexAppServerConnection) {
        self.connection = connection
        connection.onNotification = { [weak self] in self?.receive($0, $1) }
        connection.onServerRequest = { [weak self] in self?.receiveRequest($0, $1, $2) ?? false }
        connection.onClose = { [weak self] _ in self?.finish(.failed("Execution connection closed before turn completion.")) }
    }

    func start(launch: CodexExecutionLaunch, workspace: URL) async throws -> Identity {
        guard phase == .fresh, !launch.threadID.isEmpty, workspace.isFileURL else { throw Failure.invalidInput }
        phase = .resuming
        threadID = launch.threadID
        let policy = launch.approvalPolicy
        guard ["on-request", "untrusted"].contains(policy) else { throw Failure.invalidInput }
        var params: [String: JSONValue] = [
            "threadId": .string(launch.threadID), "cwd": .string(workspace.path),
            "approvalPolicy": .string(policy), "sandbox": .string("workspace-write"),
            "config": .object(["sandbox_workspace_write": .object([
                "writable_roots": .array([.string(workspace.path)]), "network_access": .bool(false),
                "exclude_tmpdir_env_var": .bool(true), "exclude_slash_tmp": .bool(true)
            ])])
        ]
        if let model = launch.model, !model.isEmpty { params["model"] = .string(model) }
        let response = try await connection.request(method: "thread/resume", params: .object(params))
        try Task.checkCancellation()
        guard phase == .resuming, case .object(let result) = response,
              case .object(let thread) = result["thread"], thread["id"] == .string(launch.threadID),
              case .string(let cwd) = result["cwd"], Self.samePath(cwd, workspace.path),
              result["approvalPolicy"] == .string(policy), case .object(let sandbox) = result["sandbox"],
              sandbox["type"] == .string("workspaceWrite"), sandbox["networkAccess"] == .bool(false),
              sandbox["excludeTmpdirEnvVar"] == .bool(true), sandbox["excludeSlashTmp"] == .bool(true),
              case .array(let roots) = sandbox["writableRoots"], roots.allSatisfy({
                  if case .string(let path) = $0 { return Self.samePath(path, workspace.path) }; return false
              }) else { throw Failure.policyMismatch }
        phase = .starting
        var turn: [String: JSONValue] = [
            "threadId": .string(launch.threadID), "cwd": .string(workspace.path),
            "approvalPolicy": .string(policy), "input": Self.input(headlessAgentExecuteInstruction),
            "sandboxPolicy": .object(["type": .string("workspaceWrite"),
                "writableRoots": .array([.string(workspace.path)]), "networkAccess": .bool(false),
                "excludeTmpdirEnvVar": .bool(true), "excludeSlashTmp": .bool(true)])
        ]
        if let model = launch.model, !model.isEmpty { turn["model"] = .string(model) }
        if let effort = launch.effort, !effort.isEmpty { turn["effort"] = .string(effort) }
        let started = try await connection.request(method: "turn/start", params: .object(turn))
        try Task.checkCancellation()
        guard phase == .starting, case .object(let result) = started,
              case .object(let turn) = result["turn"], case .string(let id) = turn["id"], !id.isEmpty,
              case .string(let status) = turn["status"], ["inProgress", "completed", "failed", "interrupted"].contains(status) else {
            throw Failure.invalidResponse
        }
        let identity = Identity(threadID: launch.threadID, turnID: id)
        self.identity = identity
        phase = .running
        let waiting = buffered
        buffered.removeAll(); bufferedBytes = 0
        for event in waiting {
            switch event {
            case .notification(let method, let value): receive(method, value)
            case .request(let id, let method, let value):
                if !receiveRequest(id, method, value) { try? connection.respond(to: id, result: .object(["decision": .string("cancel")])) }
            }
        }
        if phase == .running && status != "inProgress" { consumeTerminal(turn) }
        return identity
    }

    func steer(text: String, expectedTurnID: String, messageID: UUID) async -> DetachedLiveInputReceipt.Status {
        if let old = submissions[messageID] {
            return old.text == text && old.turnID == expectedTurnID ? old.receipt : .rejected
        }
        guard phase == .running, let identity, identity.turnID == expectedTurnID else { return .unavailable }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 65_536,
              submissions.count < 256 else { return .rejected }
        submissions[messageID] = Submission(text: text, turnID: expectedTurnID, receipt: .sending)
        let receipt: DetachedLiveInputReceipt.Status
        do {
            let response = try await connection.request(method: "turn/steer", params: .object([
                "threadId": .string(identity.threadID), "expectedTurnId": .string(expectedTurnID),
                "clientUserMessageId": .string(messageID.uuidString), "input": Self.input("User update to the approved execution turn. Preserve existing permissions. This does not approve any pending action. If new work exceeds the approved plan, report that a revised plan is needed before new-scope writes.\n\n" + text)
            ]))
            if case .object(let result) = response, result["turnId"] == .string(expectedTurnID) { receipt = .accepted }
            else { receipt = .unknown }
        } catch CodexAppServerConnection.Failure.remote(_, let message) {
            receipt = message == "No active turn was available to steer." ? .unavailable : .rejected
        } catch { receipt = .unknown }
        submissions[messageID]?.receipt = receipt
        return receipt
    }

    /// Request interruption only for this owned turn. RPC acknowledgement is
    /// not terminal proof; runner still awaits owned process-tree shutdown.
    func interrupt() async {
        guard phase == .running, let identity else { return }
        _ = try? await connection.request(method: "turn/interrupt", params: .object([
            "threadId": .string(identity.threadID), "turnId": .string(identity.turnID)
        ]), timeout: .seconds(2))
    }

    func resolveApproval(localID: String, approve: Bool) -> Bool {
        guard phase == .running, approvals.first?.localID == localID, let approval = approvals.first else { return false }
        do { try connection.respond(to: approval.requestID, result: .object(["decision": .string(approve ? "accept" : "decline")])) }
        catch { return false }
        if let index = approvals.firstIndex(where: { $0.localID == localID }) { approvals.remove(at: index) }
        if presentedApprovalID == localID { presentedApprovalID = nil }
        return true
    }

    func presentNextApproval() {
        guard phase == .running, presentedApprovalID == nil, let approval = approvals.first else { return }
        presentedApprovalID = approval.localID
        onApproval?(approval)
    }

    private func receiveRequest(_ id: CodexAppServerConnection.ServerID, _ method: String, _ value: JSONValue?) -> Bool {
        guard phase != .terminal, let value, case .object(let fields) = value,
              fields["threadId"] == threadID.map(JSONValue.string),
              ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method) else { return false }
        if phase == .starting { return buffer(.request(id, method, value), value: value) }
        guard phase == .running, let identity, fields["turnId"] == .string(identity.turnID),
              case .string(let itemID) = fields["itemId"], !itemID.isEmpty, approvals.count < 64 else { return false }
        if case .array(let decisions) = fields["availableDecisions"], !decisions.contains(.string("accept")) { return false }
        if case .string(let command) = fields["command"], command.utf8.count > 16_384 { return false }
        var details = method.contains("commandExecution") ? "Approve this command once?" : "Approve this file change once?"
        if let proposal = itemDetails[itemID] { details += "\n\n" + proposal }
        if case .string(let command) = fields["command"] { details += "\n\n" + command }
        if case .object(let network) = fields["networkApprovalContext"] {
            if case .string(let host) = network["host"] { details += "\n\nNetwork destination: " + host }
            if case .string(let value) = network["protocol"] { details += " (" + value + ")" }
        }
        if case .string(let cwd) = fields["cwd"] { details += "\n\nWorking folder: " + cwd }
        if case .string(let reason) = fields["reason"] { details += "\n\n" + reason }
        if case .string(let root) = fields["grantRoot"] { details += "\n\nRequested file scope: " + root }
        approvals.append(Approval(localID: UUID().uuidString, requestID: id, details: details, itemID: itemID))
        presentNextApproval()
        return true
    }

    private func receive(_ method: String, _ value: JSONValue?) {
        guard phase != .terminal, let value, case .object(let fields) = value,
              fields["threadId"] == threadID.map(JSONValue.string) else { return }
        if phase == .starting { _ = buffer(.notification(method, value), value: value); return }
        guard phase == .running, let identity else { return }
        if method == "serverRequest/resolved", let requestValue = fields["requestId"],
           let data = try? JSONEncoder().encode(requestValue),
           let id = try? JSONDecoder().decode(CodexAppServerConnection.ServerID.self, from: data),
           let index = approvals.firstIndex(where: { $0.requestID == id }) {
            let removed = approvals.remove(at: index)
            if removed.localID == presentedApprovalID {
                presentedApprovalID = nil
                onApprovalCleared?(removed.localID)
                presentNextApproval()
            }
            return
        }
        if method == "turn/completed", case .object(let turn) = fields["turn"], turn["id"] == .string(identity.turnID) {
            consumeTerminal(turn); return
        }
        guard fields["turnId"] == .string(identity.turnID) else { return }
        if ["item/started", "item/completed"].contains(method), case .object(let item) = fields["item"],
           case .string(let type) = item["type"] {
            if method == "item/started", ["commandExecution", "fileChange"].contains(type),
               case .string(let id) = item["id"], itemDetails.count < 64 {
                var detail = type == "fileChange" ? "File-change preview (may be truncated; inspect files before approving):" : ""
                if case .string(let command) = item["command"] { detail = command }
                if case .array(let changes) = item["changes"] {
                    for change in changes.prefix(20) {
                        guard case .object(let change) = change else { continue }
                        if case .string(let path) = change["path"] { detail += "\n\nFile: " + path }
                        if case .string(let diff) = change["diff"] { detail += "\n" + String(diff.prefix(16_000)) }
                        if detail.utf8.count > 32_000 { break }
                    }
                }
                itemDetails[id] = AgentReceiptPrivacy.privateToolDetails(detail)
            }
            if method == "item/completed", type == "agentMessage" { consumeMessage(item) }
            else if ["commandExecution", "fileChange", "mcpToolCall", "webSearch", "imageView"].contains(type) {
                if method == "item/started" { answer = ""; finalAnswer = "" }
                onProgress?(type == "fileChange" ? "Editing files" : (type == "commandExecution" ? "Running command" : "Using tool"))
            }
        }
    }

    private func buffer(_ event: Buffered, value: JSONValue) -> Bool {
        let size = (try? JSONEncoder().encode(value).count) ?? 1_048_577
        guard buffered.count < 256, bufferedBytes + size <= 1_048_576 else {
            finish(.failed("Execution event buffer overflow.")); connection.close(reason: Failure.overflow); return false
        }
        buffered.append(event); bufferedBytes += size
        return true
    }
    private func consumeMessage(_ item: [String: JSONValue]) {
        guard case .string(let text) = item["text"], text.utf8.count <= 1_048_576 else { return }
        let bounded = AgentReceiptPrivacy.privateAnswer(text)
        if item["phase"] == .string("final_answer") { finalAnswer = bounded }
        else if item["phase"] == nil || item["phase"] == .null { answer = bounded }
    }
    private func consumeTerminal(_ turn: [String: JSONValue]) {
        if case .array(let items) = turn["items"] {
            for item in items { if case .object(let item) = item, item["type"] == .string("agentMessage") { consumeMessage(item) } }
        }
        switch turn["status"] {
        case .string("completed"): finish(.completed(finalAnswer.isEmpty ? answer : finalAnswer))
        case .string("interrupted"): finish(.interrupted)
        case .string("failed"):
            if case .object(let error) = turn["error"], case .string(let message) = error["message"] { finish(.failed(message)) }
            else { finish(.failed("Codex execution failed.")) }
        default: finish(.failed("Codex returned an invalid terminal status."))
        }
    }
    private func finish(_ outcome: Outcome) {
        guard phase != .terminal else { return }
        phase = .terminal; self.outcome = outcome
        buffered.removeAll(); approvals.removeAll()
        onOutcome?(outcome)
    }
    private static func input(_ text: String) -> JSONValue { .array([.object(["type": .string("text"), "text": .string(text)])]) }
    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.resolvingSymlinksInPath() == URL(fileURLWithPath: rhs).standardizedFileURL.resolvingSymlinksInPath()
    }
}
