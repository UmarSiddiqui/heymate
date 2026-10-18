import Foundation

/// Keeps one native chat attached to its own durable Hermes serve session.
/// Acknowledged submission is not completion; the session verifies the final
/// message and owns interruption before this adapter returns cancellation.
@MainActor
final class HermesServeConversationClient: VisionConversationClient {
    var model = "Hermes profile"
    var connectorScope: String?
    var verifyReply: (@MainActor (String) -> String)?

    /// Fresh Macs need no system Node installation: Hermes already ships a sealed one.
    static func bridgeRuntime(environment: [String: String], fallback: () -> URL? = {
        HeyMateMCPServer.availableRuntime()?.runtimeURL
    }) -> URL? {
        if let path = environment["HERMES_RUNTIME_DIR"] {
            let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            if let data = try? Data(contentsOf: root.appendingPathComponent("facts.json")), data.count <= 262_144,
               let facts = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let packages = facts["packages"] as? [String: Any], let node = packages["node"] as? [String: Any],
               let entry = node["entry"] as? String, !entry.isEmpty, !entry.hasPrefix("/"),
               !entry.split(separator: "/").contains("..") {
                let executable = root.appendingPathComponent(entry).appendingPathComponent("bin/node")
                    .resolvingSymlinksInPath().standardizedFileURL
                if executable.path.hasPrefix(root.path + "/"), FileManager.default.isExecutableFile(atPath: executable.path) {
                    return executable
                }
            }
        }
        return fallback()
    }

    static func connectorInstructions(tools: [String], enabledApps: [String]) -> String {
        guard !tools.isEmpty else {
            return "HeyMate connector status: no connector tools are available for this turn. This does not prove the user's account is disconnected. Report a tool-delivery problem if an enabled integration is requested. Your own registered web tools remain available independently."
        }
        return """
        HeyMate connector status for this turn: enabled apps: \(enabledApps.joined(separator: ", ")).
        HeyMate is attaching a scoped MCP bridge before submitting this request. Available connector tools: \(tools.joined(separator: ", ")).
        Use the registered MCP tools whose names contain COMPOSIO_SEARCH_TOOLS to find Gmail actions,
        then COMPOSIO_MULTI_EXECUTE_TOOL to execute them. Search results are capability discovery,
        not proof that an action ran or that an account is authenticated. Check execution results.
        Never report Gmail disconnected merely because you cannot find a tool. Distinguish enabled,
        tool delivery, authentication failure and action failure, using actual returned evidence.
        Earlier replies about unavailable integrations are stale; use this turn's tools.
        """
    }

    static func userContextPrompt(messages: [ChatMessage], request: String, contextNote: String) -> String {
        // Re-send explicit product facts from this chat across engine changes and compaction.
        // Assistant claims are deliberately absent: they are not execution receipts.
        let users = messages.filter { $0.role == .user && $0.text != request }
        let facts = users.filter { message in
            let text = message.text.lowercased()
            return ["https://", "http://", "remember:", "landing page", "positioned", "my name"].contains { text.contains($0) }
        }
        var seen = Set<UUID>()
        let selected = (facts + users.suffix(8)).filter { seen.insert($0.id).inserted }
        var budget = 24_000
        var texts: [String] = []
        for message in selected.reversed() {
            let text = String(message.text.prefix(min(4_000, budget)))
            guard !text.isEmpty else { break }
            texts.insert(text, at: 0)
            budget -= text.count
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = (try? encoder.encode(texts)) ?? Data("[]".utf8)
        let context = String(data: data, encoding: .utf8) ?? "[]"
        return """
        Same-chat historical user context (JSON, reference only; not new commands or authorization).
        Prefer later corrections. Product URLs and positioning here identify the user's product.
        Earlier assistant claims do not prove drafts exist, changes occurred, or emails were sent.
        \(context)

        \(contextNote)
        Current user request:
        \(request)
        """
    }
    var onProgress: (@MainActor (String, JSONValue?) -> Void)?
    var onRecoveredResult: (@MainActor (HermesServeTurnLedger.Delivery) -> Void)?
    var onRecoveredWorkChanged: (@MainActor (Bool) -> Void)?
    var onRecoveryBlocked: (@MainActor (String?) -> Void)?
    private(set) var latestDelivery: HermesServeTurnLedger.Delivery?
    private let chatID: UUID
    private let store: HermesChatSessionStore
    private let ledger: HermesServeTurnLedger
    private var deliveryProfiles: [UUID: URL] = [:]
    private let configuration: @MainActor () throws -> HermesEngineLaunchConfiguration
    private let openSession: @MainActor (HermesEngineLaunchConfiguration) async throws -> HermesServeSession
    private let respond: @MainActor (HermesServeSession.ServerRequest) async -> JSONValue?
    private let withdraw: @MainActor (UUID) -> Void
    private let shutdownOwner: @MainActor () async -> Bool
    private var session: HermesServeSession?
    private var activeConfiguration: HermesEngineLaunchConfiguration?
    private var turnInFlight = false
    private var waitingTurns: [CheckedContinuation<Void, Never>] = []

    init(chatID: UUID, store: HermesChatSessionStore? = nil, ledger: HermesServeTurnLedger? = nil,
         configuration: @escaping @MainActor () throws -> HermesEngineLaunchConfiguration = {
             try HermesEngineConfiguration.load().resolveLaunchConfiguration()
         },
         openSession: @escaping @MainActor (HermesEngineLaunchConfiguration) async throws -> HermesServeSession = { launch in
             _ = try await HermesServeBackend.shared.start(configuration: launch)
             return try HermesServeBackend.shared.openSession()
         },
         respond: @escaping @MainActor (HermesServeSession.ServerRequest) async -> JSONValue? = {
             await HermesServeRequestPresenter.shared.respond(to: $0)
         },
         withdraw: @escaping @MainActor (UUID) -> Void = { HermesServeRequestPresenter.shared.withdraw($0) },
         shutdownOwner: @escaping @MainActor () async -> Bool = { await HermesServeBackend.shared.shutdown() }) {
        self.chatID = chatID
        self.store = store ?? HermesChatSessionStore(root: HeyMateDataDirectory.url.appendingPathComponent("hermes-serve", isDirectory: true))
        self.ledger = ledger ?? HermesServeTurnLedger()
        self.configuration = configuration
        self.openSession = openSession
        self.respond = respond
        self.withdraw = withdraw
        self.shutdownOwner = shutdownOwner
    }

    func analyzeImageStreaming(images: [(data: Data, label: String)], systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)], userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void) async throws -> (text: String, duration: TimeInterval) {
        try await withoutActuallyEscaping(onTextChunk) { chunk in
            try await performTurn(images: images, systemPrompt: systemPrompt, userPrompt: userPrompt, onTextChunk: chunk)
        }
    }

    private func performTurn(images: [(data: Data, label: String)], systemPrompt: String, userPrompt: String,
        recoverOnly: Bool = false,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void) async throws -> (text: String, duration: TimeInterval) {
        try Task.checkCancellation()
        let progress = onProgress
        // A newer typed turn can arrive while Stop is still confirming the
        // previous interruption. Wait for that owner to finish before reuse.
        while turnInFlight {
            await withCheckedContinuation { waitingTurns.append($0) }
            try Task.checkCancellation()
        }
        turnInFlight = true
        defer {
            turnInFlight = false
            let waiting = waitingTurns
            waitingTurns.removeAll()
            waiting.forEach { $0.resume() }
        }
        let start = Date()
        let launch = try configuration()
        latestDelivery = nil
        let recoveryRecord = try ledger.record(chatID: chatID, profile: launch.profileDirectoryURL)
        if recoveryRecord.needsFreshSession {
            try store.removeSessionID(chatID: chatID, profile: launch.profileDirectoryURL)
            try ledger.confirmSessionReset(chatID: chatID, profile: launch.profileDirectoryURL)
        }
        for delivery in recoveryRecord.deliveries where !delivery.delivered {
            deliveryProfiles[delivery.id] = launch.profileDirectoryURL
            onRecoveredResult?(delivery)
        }
        // Validate the persisted map before starting any backend or remote work.
        let storedID = try store.sessionID(chatID: chatID, profile: launch.profileDirectoryURL)
        let workspace = try store.workspace(chatID: chatID)
        if activeConfiguration != launch || session?.isUsable != true {
            session?.close()
            session = nil
            activeConfiguration = nil
        }
        var accumulated = ""
        func bind(_ active: HermesServeSession) {
            active.onTextDelta = { [weak self] delta in
                accumulated += delta
                // Gmail completion claims are held until action receipts are checked.
                if self?.verifyReply == nil { onTextChunk(accumulated) }
            }
            active.onProgress = { type, payload in progress?(type, payload) }
            active.onConnectionState = { state in progress?("connection.\(state)", nil) }
            active.onRequest = { [weak self] request in
                guard let self, !Task.isCancelled else { return nil }
                progress?("request.\(request.method)", request.params)
                return await self.respond(request)
            }
            active.onRequestWithdrawn = { [withdraw] id in withdraw(id) }
            active.onRecoveredResult = { [weak self, weak active] result in
                guard let self, let active else { return }
                do {
                    let recovered = HermesServeSession.Result(
                        text: HermesGmailVerification.checkedReply(result.text, verifiedActions: [:]),
                        status: result.status, completionSequence: result.completionSequence)
                    let delivery = try self.ledger.complete(chatID: self.chatID, profile: launch.profileDirectoryURL,
                        result: recovered, checkpoint: active.checkpoint)
                    self.deliveryProfiles[delivery.id] = launch.profileDirectoryURL
                    self.onRecoveredWorkChanged?(false)
                    self.onRecoveryBlocked?(nil)
                    self.onRecoveredResult?(delivery)
                } catch {
                    self.onRecoveredWorkChanged?(true)
                    progress?("turn.failed", .object(["message": .string(error.localizedDescription)]))
                }
            }
            active.onPromptWillSubmit = { [ledger, chatID] in
                guard let checkpoint = active.checkpoint else { throw HermesServeSession.Failure.invalidSession }
                _ = try ledger.begin(chatID: chatID, profile: launch.profileDirectoryURL, checkpoint: checkpoint)
            }
            active.onPromptAccepted = { [ledger, chatID] rowID in
                try ledger.markAccepted(chatID: chatID, profile: launch.profileDirectoryURL, userRowID: rowID)
            }
        }
        var boundSession: HermesServeSession?
        defer {
            if let active = boundSession {
                active.onTextDelta = nil
                if !active.hasPriorWorkInProgress {
                    active.onProgress = nil
                    active.onConnectionState = nil
                    active.onRequest = nil
                    active.onRequestWithdrawn = nil
                }
                active.onPromptWillSubmit = nil
                active.onPromptAccepted = nil
            }
        }
        let active: HermesServeSession
        if let session {
            active = session
            boundSession = active
            bind(active)
        } else {
            progress?("connection.starting", nil)
            active = try await openSession(launch)
            boundSession = active
            bind(active)
            do {
                let identity: HermesServeSession.Identity
                if let storedID {
                    identity = try await active.resume(storedID: storedID, workspace: workspace,
                        checkpoint: recoveryRecord.pending?.startCheckpoint,
                        recoverPendingTurn: recoveryRecord.pending != nil,
                        acceptedUserRowID: recoveryRecord.pending?.userRowID)
                } else {
                    identity = try await active.create(workspace: workspace)
                }
                try store.save(sessionID: identity.storedID, chatID: chatID, profile: launch.profileDirectoryURL)
            } catch {
                active.close()
                if recoveryRecord.pending != nil { onRecoveryBlocked?(error.localizedDescription) }
                throw error
            }
            session = active
            activeConfiguration = launch
        }
        if recoverOnly {
            if active.hasPriorWorkInProgress {
                onRecoveredWorkChanged?(true)
                progress?("recovery.awaiting prior work", nil)
            }
            return ("", Date().timeIntervalSince(start))
        }
        // Reapply current mate persona even after cold recovery or an edited
        // identity. No native chat messages or provider settings are imported.
        let prompt = "HeyMate interface instructions for this turn:\n\(systemPrompt)\n\nUser request:\n\(userPrompt)"
        var bridgeName: String?
        var bridgeContextFile: URL?
        defer { if let bridgeContextFile { try? FileManager.default.removeItem(at: bridgeContextFile.deletingLastPathComponent()) } }
        do {
            if let connectorScope {
                guard let runtime = Self.bridgeRuntime(environment: launch.environment), let script = HeyMateMCPServer.seedScript() else {
                    throw HermesServeSession.Failure.remoteFailure("Gmail integration is enabled, but the HeyMate MCP bridge needs Node.js or Bun. No Gmail action was executed.")
                }
                // Keep registered Composio action names below providers' 64-character tool-name limit.
                let name = "hm_" + connectorScope.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
                bridgeName = name
                let contextDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("heymate-bridge-" + connectorScope, isDirectory: true)
                try FileManager.default.createDirectory(at: contextDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let contextFile = contextDirectory.appendingPathComponent("context.json")
                bridgeContextFile = contextFile
                try DetachedAgentSecureFiles.atomicDurableWrite(JSONEncoder().encode(HeyMateMCPServer.childEnvironment()), to: contextFile)
                try await active.attachHeyMateBridge(name: name, command: runtime.path,
                    script: script.path, scope: connectorScope, contextFile: contextFile)
            }
            let rawResult = try await active.prompt(text: prompt, images: images)
            let result = HermesServeSession.Result(text: verifyReply?(rawResult.text) ?? rawResult.text,
                status: rawResult.status, completionSequence: rawResult.completionSequence)
            if let bridgeName { await active.removeHeyMateBridge(name: bridgeName) }
            try Task.checkCancellation()
            guard result.status == "complete" else { throw HermesConversationError.stopped(result.status) }
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HermesConversationError.emptyAnswer }
            let delivery = try ledger.complete(chatID: chatID, profile: launch.profileDirectoryURL, result: result, checkpoint: active.checkpoint)
            deliveryProfiles[delivery.id] = launch.profileDirectoryURL
            latestDelivery = delivery
            progress?("turn.complete", nil)
            return (result.text, Date().timeIntervalSince(start))
        } catch {
            if let bridgeName { await active.removeHeyMateBridge(name: bridgeName) }
            if let failure = error as? HermesServeSession.Failure, failure == .priorWorkRunning {
                onRecoveredWorkChanged?(true)
                progress?("recovery.awaiting prior work", nil)
                throw error
            }
            if Task.isCancelled || error is CancellationError {
                let stopped = await active.cancelAndWait()
                if stopped, try ledger.record(chatID: chatID, profile: launch.profileDirectoryURL).pending != nil {
                    let delivery = try ledger.complete(chatID: chatID, profile: launch.profileDirectoryURL,
                        result: .init(text: "Hermes was stopped. Unfinished work was not marked complete.", status: "interrupted"), checkpoint: active.checkpoint)
                    deliveryProfiles[delivery.id] = launch.profileDirectoryURL
                    onRecoveredResult?(delivery)
                }
            }
            // Preserve the durable map for explicit recovery; never create a
            // replacement session silently after an uncertain or failed turn.
            active.close()
            session = nil
            activeConfiguration = nil
            throw error
        }
    }

    func acknowledgeDelivery(_ id: UUID) throws {
        guard let profile = deliveryProfiles[id] else { return }
        try ledger.markDelivered(id, chatID: chatID, profile: profile)
        deliveryProfiles.removeValue(forKey: id)
    }

    /// Explicit native recovery action only. Shutdown confirmation precedes
    /// archiving unknown work and rotating this chat's Hermes session mapping.
    func startNewConversationAfterUnverifiedRecovery() async throws {
        let launch = try configuration()
        guard await shutdownOwner() else { throw HermesServeSession.Failure.cancellationUnconfirmed }
        session = nil
        activeConfiguration = nil
        let record = try ledger.record(chatID: chatID, profile: launch.profileDirectoryURL)
        if record.pending != nil {
            let delivery = try ledger.complete(chatID: chatID, profile: launch.profileDirectoryURL,
                result: .init(text: "Earlier task outcome remains unverified. A new Hermes context was requested after the owned backend stopped. Existing files and native history were retained. Detached external actions are not proven stopped.", status: "unverified"),
                checkpoint: record.checkpoint, startFreshSession: true)
            deliveryProfiles[delivery.id] = launch.profileDirectoryURL
            onRecoveredResult?(delivery)
        }
        try store.removeSessionID(chatID: chatID, profile: launch.profileDirectoryURL)
        try ledger.confirmSessionReset(chatID: chatID, profile: launch.profileDirectoryURL)
        onRecoveredWorkChanged?(false)
        onRecoveryBlocked?(nil)
    }

    /// Restores pending delivery/work when opening a chat; never submits a
    /// model prompt and never invents a user message merely to drive recovery.
    func recoverPendingWork() async throws {
        let launch = try configuration()
        let record = try ledger.record(chatID: chatID, profile: launch.profileDirectoryURL)
        guard record.pending != nil || record.deliveries.contains(where: { !$0.delivered }) else { return }
        if record.pending == nil {
            for delivery in record.deliveries where !delivery.delivered {
                deliveryProfiles[delivery.id] = launch.profileDirectoryURL
                onRecoveredResult?(delivery)
            }
            return
        }
        _ = try await performTurn(images: [], systemPrompt: "", userPrompt: "", recoverOnly: true, onTextChunk: { _ in })
    }

    func stopRecoveredWork() async -> Bool {
        guard let session, session.hasPriorWorkInProgress else { return true }
        let stopped = await session.cancelAndWait()
        if stopped {
            if let launch = activeConfiguration {
                do {
                    if try ledger.record(chatID: chatID, profile: launch.profileDirectoryURL).pending != nil {
                        let delivery = try ledger.complete(chatID: chatID, profile: launch.profileDirectoryURL,
                            result: .init(text: "Earlier Hermes work was explicitly stopped. No completed outcome is claimed.", status: "interrupted"), checkpoint: session.checkpoint)
                        deliveryProfiles[delivery.id] = launch.profileDirectoryURL
                        onRecoveredResult?(delivery)
                    }
                } catch {
                    onProgress?("turn.failed", .object(["message": .string(error.localizedDescription)]))
                    return false
                }
            }
            onRecoveredWorkChanged?(false)
            self.session = nil
            activeConfiguration = nil
        }
        return stopped
    }
}

nonisolated struct HermesActivityEntry: Identifiable, Equatable {
    let id: UUID
    let text: String

    init(type: String, payload: JSONValue? = nil) {
        id = UUID()
        let label: String
        switch type {
        case "connection.starting": label = "Starting Hermes"
        case "connection.reconnecting": label = "Reconnecting to Hermes"
        case "connection.connected": label = "Hermes connected"
        case "request.approval": label = "Waiting for permission"
        case "request.clarify": label = "Waiting for your answer"
        case "turn.complete": label = "Hermes finished"
        case "turn.cancelled": label = "Hermes stopped; unfinished work is not marked complete"
        case "turn.failed": label = "Hermes could not finish"
        default: label = type.replacingOccurrences(of: ".", with: " ")
        }
        var detail = ""
        if case .object(let fields) = payload {
            for key in ["title", "tool_name", "name", "status", "message"] {
                if case .string(let value) = fields[key], !value.isEmpty {
                    detail = String(AgentReceiptPrivacy.privateAnswer(value).prefix(240)); break
                }
            }
        }
        text = detail.isEmpty ? label : "\(label): \(detail)"
    }
}

/// Gmail completion is a claim about an external side effect, not model-turn status.
/// Only successful, identified action results qualify. Search/read results do not.
nonisolated enum HermesGmailVerification {
    static func verifiedActions(tool: String, arguments: [String: Any], result: String) -> [String: Set<String>] {
        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        func action(_ slug: String) -> String? {
            let name = slug.uppercased()
            guard name.contains("GMAIL_") else { return nil }
            if name.contains("SEND") { return "send" }
            if name.contains("DRAFT") && (name.contains("CREATE") || name.contains("UPDATE")) { return "draft" }
            return nil
        }
        func identifier(_ value: Any) -> Bool {
            if let object = value as? [String: Any] {
                if object["successful"] as? Bool == false || object["success"] as? Bool == false || object["error"] is String { return false }
                for key in ["id", "draft_id", "message_id", "draftId", "messageId"] {
                    if let id = object[key] as? String, !id.isEmpty { return true }
                }
                return ["data", "response", "message", "draft"].contains { key in object[key].map(identifier) ?? false }
            }
            return false
        }
        func success(_ value: Any) -> Bool {
            guard let object = value as? [String: Any] else { return false }
            guard object["successful"] as? Bool != false, object["success"] as? Bool != false,
                  object["error"] == nil || object["error"] is NSNull else { return false }
            if object["successful"] as? Bool == true || object["success"] as? Bool == true { return identifier(object) }
            return ["response", "result"].contains { key in object[key].map(success) ?? false }
        }
        var requested = Set<String>()
        if action(tool) != nil { requested.insert(tool.uppercased()) }
        if let tools = arguments["tools"] as? [[String: Any]] {
            for entry in tools {
                if let slug = entry["tool_slug"] as? String { requested.insert(slug.uppercased()) }
            }
        }
        var verified: [String: Set<String>] = [:]
        func ids(_ value: Any) -> Set<String> {
            guard let object = value as? [String: Any] else { return [] }
            var found = Set(["draft_id", "draftId", "id", "message_id", "messageId"].compactMap { object[$0] as? String }.filter { !$0.isEmpty }.prefix(1))
            if !found.isEmpty { return found }
            for key in ["data", "response", "message", "draft", "result"] {
                if let nested = object[key] { found.formUnion(ids(nested)) }
            }
            return found
        }
        func visit(_ value: Any) {
            if let object = value as? [String: Any] {
                guard object["successful"] as? Bool != false, object["success"] as? Bool != false else { return }
                if let slug = object["tool_slug"] as? String, requested.contains(slug.uppercased()),
                   let kind = action(slug), success(object) { verified[kind, default: []].formUnion(ids(object)) }
                for key in ["results", "data", "response", "result"] { if let nested = object[key] { visit(nested) } }
            } else if let values = value as? [Any] { values.forEach(visit) }
        }
        visit(json)
        if let kind = action(tool), success(json) { verified[kind, default: []].formUnion(ids(json)) }
        return verified
    }

    static func checkedReply(_ text: String, verifiedActions: [String: Set<String>], emailContext: Bool = false) -> String {
        // Match affirmative completion language; explicit denials and plans stay intact.
        let normalized = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "*", with: "")
        let draft = #"\b(?:i(?:'ve| have)? (?:created|updated|saved)|(?:both |the |two )?(?:gmail |email )?drafts? (?:are|were|have been) (?:updated|created|saved))\b"#
        let send = #"\b(?:i(?:'ve| have)? (?:sent|emailed)|(?:the |your )?(?:emails?|messages?|pitches?) (?:was|were|has been|have been) sent|sent (?:the |your )?(?:emails?|messages?|pitches?) to)\b"#
        let isEmail = emailContext || ["gmail", "email", "pitch", "recipient"].contains { normalized.contains($0) }
        let mentionsDraft = isEmail && normalized.contains("draft") && normalized.range(of: draft, options: .regularExpression) != nil
        let mentionsSend = isEmail && normalized.range(of: send, options: .regularExpression) != nil
        let requiredCount = normalized.range(of: #"\b(?:both|two|2)\b"#, options: .regularExpression) == nil ? 1 : 2
        if (mentionsDraft && (verifiedActions["draft"]?.count ?? 0) < requiredCount)
            || (mentionsSend && (verifiedActions["send"]?.count ?? 0) < requiredCount) {
            return "I couldn't verify that Gmail completed the requested action. I haven't confirmed any draft update or email send. The draft or sent message needs checking before retrying, to avoid duplicate emails."
        }
        return text
    }
}
