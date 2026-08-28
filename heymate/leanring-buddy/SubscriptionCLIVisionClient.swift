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

    init(
        backend: Backend,
        model: String,
        reasoningEffort: String = "",
        textOnlyModel: String? = nil
    ) {
        self.backend = backend
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.textOnlyModel = textOnlyModel
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
            var claudeArguments = ["-p", prompt, "--output-format", "text", "--permission-mode", "plan"]
            if !model.isEmpty {
                claudeArguments.append(contentsOf: ["--model", model])
            }
            if !systemPrompt.isEmpty {
                claudeArguments.append(contentsOf: ["--append-system-prompt", systemPrompt])
            }
            arguments = claudeArguments
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

    private static func captureStandardOutput(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        environmentKeysToRemove: [String],
        parseAsCodexJSONL: Bool
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdout = Pipe()
                process.executableURL = executableURL
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                process.environment = HeadlessChildEnvironment.build(stripping: environmentKeysToRemove)
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
                DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: watchdog)

                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()

                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                let raw = String(data: data, encoding: .utf8) ?? ""
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
