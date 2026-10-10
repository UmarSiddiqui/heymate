//
//  SubscriptionCLIVisionClient.swift
//  HeyMate
//
//  Talk, through the same CLI the user is already signed in to.
//
//  A measured `claude -p` turn with a screenshot took thirteen seconds, so
//  this is slower than an HTTP vision endpoint — but it is also the only
//  path that actually answers when Claude or Codex is the brain and no
//  Custom API key is set. Posting to api.anthropic.com without a key is
//  what previously produced silence.
//

import Foundation

final class SubscriptionCLIVisionClient: VisionConversationClient {

    /// Default for text-only Codex Talk. Verified through local ChatGPT Pro
    /// Codex CLI login; screen turns still use selected model.
    static let codexFastTalkModelIdentifier = "gpt-5.3-codex-spark"

    enum Backend: Equatable {
        case claude
        case codex
    }

    var model: String
    private let backend: Backend
    private let reasoningEffort: String
    private let textOnlyModel: String?

    /// Whether this turn's child will be able to reach Composio's apps. Read once at init and published so the prompt builder can tell
    /// the model the truth about what it can reach — a CLI-backed turn keeps
    /// its tools inside the child, where `availableTalkTools` cannot see them.
    ///
    /// Both halves are required: the connector has to be attached, and the
    /// bridge server the child borrows it through has to be runnable.
    let carriesComposioTools: Bool

    /// Whether the child gets HeyMate's loopback server at all. Composio is
    /// one reason; a plain MCP connector with a live session is another, and
    /// without it a subscription brain never sees that connector's tools.
    let carriesConnectedAppTools: Bool

    /// The chat this turn belongs to. Turns that share it continue one CLI
    /// session; nil gives every turn a fresh child, as before.
    private(set) var conversationKey: String?
    /// How many messages the chat holds as this turn starts, its question
    /// included. Continuing needs exactly the two the last turn implied
    /// (its answer, then this question); anything else means the chat was
    /// edited or something else spoke, and the child is not continued.
    private(set) var conversationPosition = 0

    /// This client, bound to one chat at `position`.
    func boundToConversation(key: String, position: Int) -> SubscriptionCLIVisionClient {
        let bound = SubscriptionCLIVisionClient(
            backend: backend,
            model: model,
            reasoningEffort: reasoningEffort,
            textOnlyModel: textOnlyModel,
            carriesComposioTools: carriesComposioTools,
            carriesConnectedAppTools: carriesConnectedAppTools
        )
        bound.conversationKey = key
        bound.conversationPosition = position
        return bound
    }

    private init(
        backend: Backend,
        model: String,
        reasoningEffort: String,
        textOnlyModel: String?,
        carriesComposioTools: Bool,
        carriesConnectedAppTools: Bool
    ) {
        self.backend = backend
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.textOnlyModel = textOnlyModel
        self.carriesComposioTools = carriesComposioTools
        self.carriesConnectedAppTools = carriesConnectedAppTools
    }

    init(
        backend: Backend,
        model: String,
        reasoningEffort: String = "",
        textOnlyModel: String? = nil,
        connectedAppsReachable: Bool = ComposioAgentAttachment.isAttachable()
    ) {
        self.backend = backend
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.textOnlyModel = textOnlyModel
        let serverIsRunnable = HeyMateMCPServer.availableRuntime() != nil
        self.carriesComposioTools = serverIsRunnable && ComposioAgentAttachment.isAttachable()
        self.carriesConnectedAppTools = serverIsRunnable && connectedAppsReachable
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        if let launch = warmLaunch() {
            do {
                let text = try await runWarmTurn(
                    launch: launch,
                    images: images,
                    systemPrompt: systemPrompt,
                    conversationHistory: conversationHistory,
                    userPrompt: userPrompt,
                    onTextChunk: onTextChunk
                )
                await onTextChunk(text)
                return (text, Date().timeIntervalSince(startTime))
            } catch {
                // Signed out is the user's to fix and the one-shot path would
                // only say it again, slower. Anything else — a protocol change
                // in a newer CLI, a child that died — gets the proven path.
                if error is CancellationError || SpokenFailure.classify(error) == .signedOut { throw error }
                HeyMateLog.log("⚠️ Talk: warm turn failed (\(error.localizedDescription)); retrying one-shot")
            }
        }
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-talk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(at: workDirectory) }

        var imagePaths: [String] = []
        for (index, image) in images.enumerated() {
            let fileURL = workDirectory.appendingPathComponent("screen-\(index).jpg")
            try image.data.write(to: fileURL)
            imagePaths.append(fileURL.path)
        }

        var prompt = userPrompt
        if !conversationHistory.isEmpty {
            let replayed = conversationHistory.map {
                "User: \($0.userPlaceholder)\nAssistant: \($0.assistantResponse)"
            }.joined(separator: "\n\n")
            prompt = replayed + "\n\n" + prompt
        }
        if !imagePaths.isEmpty {
            let listed = imagePaths.enumerated().map { index, path in
                let label = images[index].label
                return "Screenshot \(index + 1) (\(label)): \(path)"
            }.joined(separator: "\n")
            prompt = listed + "\n\n" + prompt
        }

        let text = try await runTurn(
            prompt: prompt,
            systemPrompt: systemPrompt,
            imagePaths: imagePaths,
            workingDirectory: workDirectory
        )
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "HeyMateTalk",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The signed-in CLI returned an empty answer."]
            )
        }
        await onTextChunk(trimmed)
        return (trimmed, Date().timeIntervalSince(startTime))
    }

    private func runTurn(
        prompt: String,
        systemPrompt: String,
        imagePaths: [String],
        workingDirectory: URL
    ) async throws -> String {
        let executableName = backend == .claude ? "claude" : "codex"
        guard let executableURL = LoginShellExecutableResolver.resolveExecutable(named: executableName) else {
            throw NSError(
                domain: "HeyMateTalk",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: SubscriptionSignInCopy.notInstalledRemedy(
                    for: backend == .claude ? .claudeCode : .codex
                )]
            )
        }

        let arguments: [String]
        let keysToStrip: [String]
        switch backend {
        case .claude:
            keysToStrip = HeadlessExecutor.claudeCode.environmentKeysToRemove
            arguments = Self.claudeTalkArguments(
                prompt: prompt,
                systemPrompt: systemPrompt,
                model: model,
                effort: reasoningEffort,
                connectedAppServers: carriesConnectedAppTools ? Self.talkMCPServerConfiguration() : nil,
                connectedAppToolNames: HeyMateMCPServer.claudeCodeToolNames()
            )
        case .codex:
            keysToStrip = HeadlessExecutor.codex.environmentKeysToRemove
            let resolvedModel = Self.resolvedModelIdentifier(
                selectedModel: model,
                textOnlyModel: textOnlyModel,
                hasImages: !imagePaths.isEmpty
            )
            let usesFastTalkModel = resolvedModel == textOnlyModel
            var codexArguments = [
                "exec",
                "--json",
                "--ignore-user-config",
                "--skip-git-repo-check",
                "--sandbox", "read-only",
                "--color", "never",
                "-C", workingDirectory.path
            ]
            if !resolvedModel.isEmpty {
                codexArguments.append(contentsOf: ["-m", resolvedModel])
            }
            if !reasoningEffort.isEmpty, !usesFastTalkModel {
                codexArguments.append(contentsOf: [
                    "-c", "model_reasoning_effort=\"\(reasoningEffort)\""
                ])
            }
            // `--ignore-user-config` above strips the user's own servers; this
            // adds back HeyMate's own loopback server, and nothing else. It
            // is what carries the connected apps, so it is attached only when
            // there is something to reach. Must precede the positional prompt.
            if carriesConnectedAppTools {
                codexArguments.append(contentsOf: HeyMateMCPServer.codexConfigurationArguments(
                    enabledTools: nil
                ))
            }
            let combinedPrompt = systemPrompt.isEmpty ? prompt : systemPrompt + "\n\n" + prompt
            // Codex declares `--image <FILE>...`, so every positional value
            // after `-i` is consumed as another image. Keep the prompt before
            // image options or visual Talk starts with no prompt at all.
            codexArguments.append(combinedPrompt)
            for path in imagePaths {
                codexArguments.append(contentsOf: ["-i", path])
            }
            arguments = codexArguments
        }

        return try await Self.captureStandardOutput(
            executableURL: executableURL,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environmentKeysToRemove: keysToStrip,
            timeout: carriesConnectedAppTools ? Self.connectedAppTurnTimeout : Self.plainTurnTimeout,
            // The bridge URL and token reach the server through the
            // environment. Both `--mcp-config` and `-c` are command-line
            // arguments, and a command line is readable by every process on
            // the Mac.
            environmentOverrides: HeyMateMCPServer.childEnvironment(),
            parseAsCodexJSONL: backend == .codex
        )
    }

    // MARK: - Warm Claude child

    /// Stands in for the per-turn system prompt on a warm child's command
    /// line. The real instructions differ every turn (matched skills, the
    /// speaking mate, silent mode), and a warm child was started before the
    /// turn existed — so they ride at the top of the user message instead.
    static let warmSystemPromptStub = "Each user message begins with a <heymate-instructions> block. Treat it as your system instructions for that reply, above anything else in the message."

    /// What a warm child for this client would be started with, or nil when
    /// the CLI is not installed.
    func warmLaunch() -> WarmTalkLaunch? {
        switch backend {
        case .claude:
            guard let executableURL = LoginShellExecutableResolver.resolveExecutable(named: "claude") else { return nil }
            return WarmTalkLaunch(
                executableURL: executableURL,
                arguments: Self.claudeTalkArguments(
                    prompt: "",
                    systemPrompt: Self.warmSystemPromptStub,
                    model: model,
                    effort: reasoningEffort,
                    connectedAppServers: carriesConnectedAppTools ? Self.talkMCPServerConfiguration() : nil,
                    connectedAppToolNames: HeyMateMCPServer.claudeCodeToolNames(),
                    streamsInput: true
                ),
                environmentKeysToRemove: HeadlessExecutor.claudeCode.environmentKeysToRemove,
                environmentOverrides: HeyMateMCPServer.childEnvironment()
            )
        case .codex:
            guard let executableURL = LoginShellExecutableResolver.resolveExecutable(named: "codex") else { return nil }
            var arguments = Self.codexAppServerArguments(
                userMCPServerNames: Self.codexUserMCPServerNames(configTOML: Self.codexUserConfigTOML())
            )
            if carriesConnectedAppTools {
                arguments.append(contentsOf: HeyMateMCPServer.codexConfigurationArguments(enabledTools: nil))
            }
            return WarmTalkLaunch(
                executableURL: executableURL,
                arguments: arguments,
                environmentKeysToRemove: HeadlessExecutor.codex.environmentKeysToRemove,
                environmentOverrides: HeyMateMCPServer.childEnvironment(),
                codexThreadStartParamsJSON: Self.codexThreadStartParamsJSON(model: model, effort: reasoningEffort)
            )
        }
    }

    /// Starts the next Talk child now, while the user is still speaking.
    func prewarm() {
        guard let launch = warmLaunch() else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            WarmTalkPool.shared.prewarm(launch)
        }
    }

    // MARK: Codex app-server isolation

    /// `codex exec --ignore-user-config` kept the user's own setup away from
    /// Talk's screenshots. `app-server` has no such flag, so the same
    /// isolation is spelled out: hooks, plugins, apps, and memories off, the
    /// turn-finished `notify` program cleared, and every MCP server from the
    /// user's config.toml disabled by name. Verified against a live child:
    /// `thread/start` then reports no MCP startup and no hooks run.
    nonisolated static func codexAppServerArguments(userMCPServerNames: [String]) -> [String] {
        var arguments = ["app-server"]
        for feature in ["hooks", "plugins", "apps", "memories"] {
            arguments.append(contentsOf: ["--disable", feature])
        }
        arguments.append(contentsOf: ["-c", "notify=[]"])
        for name in userMCPServerNames where name != HeyMateMCPServer.serverName {
            arguments.append(contentsOf: ["-c", "mcp_servers.\(name).enabled=false"])
        }
        return arguments
    }

    /// Table names under `[mcp_servers.…]`, quoted ones kept quoted so they
    /// can go straight back into a `-c` dotted path. Sub-tables such as
    /// `[mcp_servers.x.env]` are not servers and are skipped.
    nonisolated static func codexUserMCPServerNames(configTOML: String) -> [String] {
        var names: [String] = []
        for rawLine in configTOML.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("[mcp_servers."), line.hasSuffix("]"), !line.hasPrefix("[[") else { continue }
            let path = String(line.dropFirst("[mcp_servers.".count).dropLast())
            let name: String
            if path.hasPrefix("\""), let closing = path.dropFirst().firstIndex(of: "\"") {
                name = String(path[path.startIndex...closing])
                guard path.index(after: closing) == path.endIndex else { continue }
            } else {
                guard !path.contains(".") else { continue }
                name = path
            }
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    private static func codexUserConfigTOML() -> String {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return (try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
    }

    /// `thread/start` params. Read-only sandbox and no approvals, like the
    /// `exec` path; ephemeral so a Talk question never lands in the user's
    /// Codex session history. The fast Talk default model is left out:
    /// app-server rejects it on ChatGPT plans, and Codex's own default is
    /// the better guess.
    nonisolated static func codexThreadStartParamsJSON(model: String, effort: String) -> String {
        var params: [String: Any] = [
            "sandbox": "read-only",
            "approvalPolicy": "never",
            "ephemeral": true
        ]
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty, trimmedModel != codexFastTalkModelIdentifier {
            params["model"] = trimmedModel
        }
        if !effort.isEmpty {
            params["config"] = ["model_reasoning_effort": effort]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    // MARK: Warm turn

    private func runWarmTurn(
        launch: WarmTalkLaunch,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let timeout = carriesConnectedAppTools ? Self.connectedAppTurnTimeout : Self.plainTurnTimeout
        let backend = self.backend
        let engineName = backend == .claude ? "Claude" : "Codex"
        let conversationKey = self.conversationKey
        let conversationPosition = self.conversationPosition

        guard let (child, isContinuing) = WarmTalkPool.shared.takeChild(
            for: launch,
            conversationKey: conversationKey,
            position: conversationPosition
        ) else {
            throw NSError(
                domain: "SubscriptionCLIVisionClient",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "\(engineName) could not be started."]
            )
        }

        // A continuing child already holds the earlier exchanges; replaying
        // them would make it read the whole chat twice.
        let prompt = isContinuing
            ? userPrompt
            : Self.replayedPrompt(history: conversationHistory, userPrompt: userPrompt)
        let instructions = Self.instructionsToSend(systemPrompt, previous: child.lastInstructions)

        let (events, continuation) = AsyncThrowingStream<WarmTurnEvent, Error>.makeStream()
        DispatchQueue.global(qos: .userInitiated).async {
                    func fail(_ message: String, code: Int) {
                        child.discard()
                        continuation.finish(throwing: NSError(
                            domain: "SubscriptionCLIVisionClient",
                            code: code,
                            userInfo: [NSLocalizedDescriptionKey: String(message.prefix(500))]
                        ))
                    }

                    let watchdog = DispatchWorkItem { child.discard() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                    defer { watchdog.cancel() }

                    let request: Data?
                    var codexRequestID = 0
                    switch backend {
                    case .claude:
                        request = Self.warmUserMessageJSON(systemPrompt: instructions, prompt: prompt, images: images)
                    case .codex:
                        // app-server reads images from disk; the child's own
                        // scratch folder goes away with the child.
                        var imagePaths: [(path: String, label: String)] = []
                        for (index, image) in images.enumerated() {
                            let fileExtension = Self.imageMediaType(for: image.data) == "image/png" ? "png" : "jpg"
                            let fileURL = child.workingDirectory
                                .appendingPathComponent("screen-\(child.completedTurns)-\(index).\(fileExtension)")
                            guard (try? image.data.write(to: fileURL)) != nil else { continue }
                            imagePaths.append((path: fileURL.path, label: image.label))
                        }
                        codexRequestID = child.takeCodexRequestID()
                        request = child.codexThreadID.flatMap {
                            CodexAppServerProtocol.turnStartJSON(
                                threadID: $0,
                                systemPrompt: instructions,
                                prompt: prompt,
                                imagePaths: imagePaths,
                                requestID: codexRequestID
                            )
                        }
                    }
                    guard let request else {
                        fail("HeyMate could not package this question.", code: 3)
                        return
                    }
                    do {
                        try child.write(request)
                    } catch {
                        child.discard()
                        continuation.finish(throwing: error)
                        return
                    }

                    var streamed = ""
                    func publish(_ delta: String) {
                        streamed += delta
                        continuation.yield(.partial(streamed))
                    }

                    while let line = child.readLine() {
                        let outcome: WarmTurnOutcome?
                        switch backend {
                        case .claude:
                            if let delta = Self.warmTextDelta(fromStdoutLine: line) {
                                publish(delta)
                                continue
                            }
                            outcome = Self.warmTurnOutcome(fromStdoutLine: line)
                        case .codex:
                            if let delta = CodexAppServerProtocol.textDelta(fromLine: line) {
                                publish(delta)
                                continue
                            }
                            switch CodexAppServerProtocol.turnEvent(fromLine: line, requestID: codexRequestID) {
                            case .answered(let answer): outcome = .answered(answer)
                            case .failed(let message): outcome = .failed(message)
                            case nil: outcome = nil
                            }
                        }
                        switch outcome {
                        case .answered(let answer):
                            if backend == .codex {
                                // `item/completed` arrives before
                                // `turn/completed`; the child is only ready
                                // for the next question after the latter.
                                guard Self.drainCodexTurn(child) else {
                                    child.discard()
                                    continuation.yield(.answered(answer))
                                    continuation.finish()
                                    return
                                }
                            }
                            child.conversationKey = conversationKey
                            // Next: this answer, then the follow-up question.
                            child.nextConversationPosition = conversationPosition + 2
                            child.completedTurns += 1
                            if !images.isEmpty { child.imageTurns += 1 }
                            child.lastInstructions = systemPrompt
                            if conversationKey == nil {
                                // Nothing to continue: the next question is
                                // a different chat, so it gets a fresh child.
                                child.discard()
                                WarmTalkPool.shared.prewarm(launch)
                            } else {
                                WarmTalkPool.shared.checkIn(child)
                            }
                            continuation.yield(.answered(answer))
                            continuation.finish()
                            return
                        case .failed(let message):
                            fail(message, code: 1)
                            return
                        case nil:
                            continue
                        }
                    }
                    fail("\(engineName) stopped before it answered.", code: 2)
        }

        var text = ""
        try await withTaskCancellationHandler {
            for try await event in events {
                switch event {
                case .partial(let soFar):
                    await onTextChunk(soFar)
                case .answered(let answer):
                    text = answer
                }
            }
        } onCancel: {
            // An interrupted answer must not live on in the session the next
            // question continues.
            child.discard()
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(
                domain: "HeyMateTalk",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The signed-in CLI returned an empty answer."]
            )
        }
        return trimmed
    }

    /// Reads a Codex child up to its `turn/completed`. False when the child
    /// closed first, which means it cannot be continued.
    nonisolated private static func drainCodexTurn(_ child: WarmTalkChild) -> Bool {
        while let line = child.readLine() {
            if line.contains("\"turn/completed\"") { return true }
        }
        return false
    }

    /// The earlier exchanges as plain text ahead of the question, for a
    /// child that has not seen them.
    nonisolated static func replayedPrompt(
        history: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) -> String {
        guard !history.isEmpty else { return userPrompt }
        let replayed = history.map {
            "User: \($0.userPlaceholder)\nAssistant: \($0.assistantResponse)"
        }.joined(separator: "\n\n")
        return replayed + "\n\n" + userPrompt
    }

    /// The instruction block for this turn. Unchanged instructions are
    /// pointed back to rather than pasted again, so a long chat does not
    /// fill the session with copies of the same block.
    nonisolated static func instructionsToSend(_ systemPrompt: String, previous: String?) -> String {
        guard !systemPrompt.isEmpty, systemPrompt == previous else { return systemPrompt }
        return "Same instructions as your previous reply."
    }

    /// One streamed piece of Claude's answer, from a `stream_event` line
    /// that `--include-partial-messages` emits. Nil for every other line.
    nonisolated static func warmTextDelta(fromStdoutLine line: String) -> String? {
        guard line.contains("text_delta"),
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "stream_event",
              // Only the top-level answer; a subagent's text is not Talk.
              json["parent_tool_use_id"] is NSNull || json["parent_tool_use_id"] == nil,
              let event = json["event"] as? [String: Any],
              event["type"] as? String == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta",
              let text = delta["text"] as? String else { return nil }
        return text
    }

    enum WarmTurnEvent: Sendable {
        case partial(String)
        case answered(String)
    }

    enum WarmTurnOutcome: Equatable, Sendable {
        case answered(String)
        case failed(String)
    }

    /// The turn's end, read from one `stream-json` line, or nil for every
    /// line before it. A signed-out CLI reports its error as a `result` with
    /// `"subtype": "success"` and `"is_error": true`, so `is_error` is the
    /// field that decides.
    nonisolated static func warmTurnOutcome(fromStdoutLine line: String) -> WarmTurnOutcome? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "result" else { return nil }
        let resultText = json["result"] as? String ?? ""
        let isError = json["is_error"] as? Bool ?? false
        let subtype = json["subtype"] as? String ?? "success"
        if isError || subtype != "success" {
            return .failed(resultText.isEmpty ? "Claude reported \(subtype)." : resultText)
        }
        return .answered(resultText)
    }

    /// One stream-json user message: the turn's instructions and question as
    /// text, and each image inline as base64 — so Claude sees the screen in
    /// the same request instead of spending a tool call to read a file.
    nonisolated static func warmUserMessageJSON(
        systemPrompt: String,
        prompt: String,
        images: [(data: Data, label: String)]
    ) -> Data? {
        var content: [[String: Any]] = []
        if !systemPrompt.isEmpty {
            content.append([
                "type": "text",
                "text": "<heymate-instructions>\n\(systemPrompt)\n</heymate-instructions>"
            ])
        }
        for (index, image) in images.enumerated() {
            content.append(["type": "text", "text": "Screenshot \(index + 1) (\(image.label)):"])
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": imageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
        }
        content.append(["type": "text", "text": prompt.isEmpty ? "(no words, only the screen)" : prompt])
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content]
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        data.append(0x0A)
        return data
    }

    nonisolated static func imageMediaType(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if bytes.count >= 12, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        return "image/jpeg"
    }

    nonisolated static func resolvedModelIdentifier(
        selectedModel: String,
        textOnlyModel: String?,
        hasImages: Bool
    ) -> String {
        if !hasImages,
           let textOnlyModel,
           !textOnlyModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return textOnlyModel
        }
        return selectedModel
    }

    /// `connectedAppServers` is HeyMate's own loopback MCP server — nil
    /// whenever the user has not connected Composio or no JavaScript runtime
    /// is on PATH, which is what keeps the isolated shape below the default.
    ///
    /// When it is present the turn trades two of those isolations away, and
    /// only those two: `--safe-mode` goes, because current safe mode drops
    /// explicitly supplied MCP servers along with ambient ones, and plan mode
    /// gives way to `acceptEdits`, because plan mode refuses the tool call
    /// itself. `--strict-mcp-config` and the empty `--setting-sources` stay,
    /// so the child still sees exactly one reviewed server and none of the
    /// user's hooks, skills, or CLAUDE.md.
    nonisolated static func claudeTalkArguments(
        prompt: String,
        systemPrompt: String,
        model: String,
        effort: String = "",
        connectedAppServers: [String: Any]? = nil,
        connectedAppToolNames: [String] = [],
        streamsInput: Bool = false
    ) -> [String] {
        let mcpConfigurationJSON = Self.mcpConfigurationJSON(servers: connectedAppServers)
        let carriesComposio = mcpConfigurationJSON != Self.emptyMCPConfigurationJSON

        // A warm child takes its question on stdin, after it has booted, so
        // the prompt is not on the command line at all.
        var arguments = streamsInput
            ? ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
            : ["-p", prompt, "--output-format", "text"]
        arguments.append(contentsOf: [
            "--permission-mode", carriesComposio ? "acceptEdits" : "plan"
        ])
        if !carriesComposio {
            // Talk passes screenshot paths and conversation replay. Prevent
            // user/project hooks, plugins, skills, agents, CLAUDE.md, or MCP
            // servers from observing them before Claude answers.
            arguments.append("--safe-mode")
        }
        arguments.append(contentsOf: [
            "--setting-sources", "",
            "--mcp-config", mcpConfigurationJSON,
            "--strict-mcp-config"
        ])
        if carriesComposio, !connectedAppToolNames.isEmpty {
            // Without the allow-list `acceptEdits` auto-approves file edits
            // only, and every MCP call comes back as an ungranted permission
            // request instead of reaching the server.
            arguments.append(contentsOf: ["--allowedTools", connectedAppToolNames.joined(separator: ",")])
        }
        if !model.isEmpty {
            arguments.append(contentsOf: ["--model", model])
        }
        if !effort.isEmpty {
            arguments.append(contentsOf: ["--effort", effort])
        }
        if !systemPrompt.isEmpty {
            arguments.append(contentsOf: ["--append-system-prompt", systemPrompt])
        }
        return arguments
    }

    /// A turn that only thinks and answers. Long enough for a measured
    /// thirteen-second vision turn with room to spare.
    static let plainTurnTimeout: TimeInterval = 90

    /// A turn that can reach the user's connected apps has to survive a
    /// human: a connector call that stops for approval waits on a click, and
    /// killing the child underneath it produced exactly the truncated
    /// half-answer — "i'm checking whether your account is connected" and
    /// then nothing — that this budget exists to prevent.
    static let connectedAppTurnTimeout: TimeInterval = 300

    static let emptyMCPConfigurationJSON = #"{"mcpServers":{}}"#

    /// HeyMate's own loopback server as an `mcpServers` entry, or nil when
    /// it cannot run. Whether there is anything to reach through it is the
    /// caller's call (`carriesConnectedAppTools`). The child borrows the sessions
    /// `ConnectorRuntime` already holds instead of opening its own, so a
    /// question costs one local process rather than a cold `npx` fetch and a
    /// second sign-in to the vendor.
    nonisolated static func talkMCPServerConfiguration() -> [String: Any]? {
        guard let runtime = HeyMateMCPServer.availableRuntime(),
              let scriptURL = HeyMateMCPServer.seedScript() else { return nil }
        return [
            HeyMateMCPServer.serverName: [
                "command": runtime.runtimeURL.path,
                "args": [scriptURL.path]
            ]
        ]
    }

    /// Falls back to the empty configuration on an unserializable payload, so
    /// a malformed session degrades to a toolless answer rather than to a
    /// child that refuses to start.
    nonisolated static func mcpConfigurationJSON(servers: [String: Any]?) -> String {
        guard let servers, !servers.isEmpty else { return emptyMCPConfigurationJSON }
        guard let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": servers]),
              let json = String(data: data, encoding: .utf8) else { return emptyMCPConfigurationJSON }
        return json
    }

    /// The CLI's own words when it gave any (Codex reports them as JSONL
    /// `error` events), otherwise the exit status.
    nonisolated static func cliFailure(
        output: String,
        exitStatus: Int32,
        parseAsCodexJSONL: Bool
    ) -> NSError {
        var message = ""
        if parseAsCodexJSONL {
            for line in output.split(whereSeparator: \.isNewline) {
                for event in CodexJSONLParser.events(fromStdoutLine: String(line)) {
                    if case .failed(let reported) = event { message = reported }
                }
            }
        } else {
            message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if message.isEmpty {
            message = "The engine exited with status \(exitStatus)."
        }
        return NSError(
            domain: "SubscriptionCLIVisionClient",
            code: Int(exitStatus),
            userInfo: [NSLocalizedDescriptionKey: String(message.prefix(500))]
        )
    }

    private static func captureStandardOutput(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        environmentKeysToRemove: [String],
        timeout: TimeInterval = plainTurnTimeout,
        environmentOverrides: [String: String] = [:],
        parseAsCodexJSONL: Bool
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdout = Pipe()
                process.executableURL = executableURL
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                process.environment = HeadlessChildEnvironment.build(
                    stripping: environmentKeysToRemove,
                    overrides: environmentOverrides
                )
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let watchdog = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()

                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                let raw = String(data: data, encoding: .utf8) ?? ""
                // A CLI that exits non-zero on its own prints its error to
                // stdout ("Failed to authenticate: OAuth session expired…").
                // Returned as-is it became the mate's answer. The watchdog's
                // SIGTERM is a signal, not an exit, so a timed-out turn still
                // keeps whatever it managed to say.
                if process.terminationReason == .exit, process.terminationStatus != 0 {
                    continuation.resume(throwing: Self.cliFailure(
                        output: raw,
                        exitStatus: process.terminationStatus,
                        parseAsCodexJSONL: parseAsCodexJSONL
                    ))
                    return
                }
                if parseAsCodexJSONL {
                    var lastMessage = ""
                    for line in raw.split(whereSeparator: \.isNewline) {
                        if let text = CodexJSONLParser.agentMessageText(fromStdoutLine: String(line)) {
                            lastMessage = text
                        }
                    }
                    continuation.resume(returning: lastMessage.isEmpty ? raw : lastMessage)
                    return
                }
                continuation.resume(returning: raw)
            }
        }
    }
}
