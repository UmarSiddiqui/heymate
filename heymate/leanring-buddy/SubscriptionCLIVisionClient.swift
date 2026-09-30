//
//  SubscriptionCLIVisionClient.swift
//  leanring-buddy
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
                userInfo: [NSLocalizedDescriptionKey: "\(executableName) is not on PATH. Sign in from Settings → Brain."]
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
        connectedAppToolNames: [String] = []
    ) -> [String] {
        let mcpConfigurationJSON = Self.mcpConfigurationJSON(servers: connectedAppServers)
        let carriesComposio = mcpConfigurationJSON != Self.emptyMCPConfigurationJSON

        var arguments = [
            "-p", prompt,
            "--output-format", "text",
            "--permission-mode", carriesComposio ? "acceptEdits" : "plan"
        ]
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
