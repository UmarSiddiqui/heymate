//
//  CodexModelCatalog.swift
//  leanring-buddy
//
//  Reads the signed-in Codex CLI's own model catalog. Model names and
//  reasoning efforts belong to Codex, so HeyMate must not duplicate them.
//

import Foundation

nonisolated struct CodexReasoningEffortOption: Codable, Hashable, Identifiable {
    let reasoningEffort: String
    let description: String

    var id: String { reasoningEffort }
    var displayName: String { reasoningEffort.capitalized }
}

nonisolated struct CodexModelOption: Codable, Hashable, Identifiable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let hidden: Bool
    let supportedReasoningEfforts: [CodexReasoningEffortOption]
    let defaultReasoningEffort: String
    let isDefault: Bool
}

nonisolated enum CodexModelCatalogError: LocalizedError {
    case cliNotInstalled
    case launchFailed(String)
    case timedOut
    case serverError(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .cliNotInstalled:
            return "Codex CLI is not installed."
        case .launchFailed(let message):
            return "Could not start Codex CLI: \(message)"
        case .timedOut:
            return "Codex CLI model catalog timed out."
        case .serverError(let message):
            return "Codex CLI model catalog failed: \(message)"
        case .invalidResponse:
            return "Codex CLI returned an invalid model catalog."
        }
    }
}

nonisolated enum CodexModelCatalogLoader {
    private struct ModelListResult: Decodable {
        let data: [CodexModelOption]
        let nextCursor: String?
    }

    private struct RPCError: Decodable {
        let message: String
    }

    private struct ResponseEnvelope: Decodable {
        let id: Int?
        let result: ModelListResult?
        let error: RPCError?
    }

    static func fetchAvailableModels() async throws -> [CodexModelOption] {
        try await Task.detached(priority: .userInitiated) {
            try fetchAvailableModelsSynchronously()
        }.value
    }

    /// Codex app-server exposes the same live catalog used by Codex model
    /// pickers, including account availability and per-model effort choices.
    private static func fetchAvailableModelsSynchronously() throws -> [CodexModelOption] {
        guard let executableURL = LoginShellExecutableResolver.resolveExecutable(named: "codex") else {
            throw CodexModelCatalogError.cliNotInstalled
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.environment = HeadlessChildEnvironment.build(
            stripping: HeadlessExecutor.codex.environmentKeysToRemove
        )
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CodexModelCatalogError.launchFailed(error.localizedDescription)
        }

        let timeoutWorkItem = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + 10,
            execute: timeoutWorkItem
        )

        defer {
            timeoutWorkItem.cancel()
            try? inputPipe.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        try writeRequest(
            [
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": ["name": "heymate", "version": "1"],
                    "capabilities": [:]
                ]
            ],
            to: inputPipe.fileHandleForWriting
        )
        try writeRequest(["method": "initialized"], to: inputPipe.fileHandleForWriting)

        var requestIdentifier = 2
        try writeModelListRequest(
            id: requestIdentifier,
            cursor: nil,
            to: inputPipe.fileHandleForWriting
        )

        var availableModels: [CodexModelOption] = []
        var bufferedOutput = Data()

        while process.isRunning {
            let chunk = outputPipe.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            bufferedOutput.append(chunk)

            while let newlineIndex = bufferedOutput.firstIndex(of: 0x0A) {
                let lineData = bufferedOutput[..<newlineIndex]
                bufferedOutput.removeSubrange(...newlineIndex)
                guard !lineData.isEmpty,
                      let envelope = try? JSONDecoder().decode(ResponseEnvelope.self, from: lineData),
                      envelope.id == requestIdentifier else {
                    continue
                }

                if let error = envelope.error {
                    throw CodexModelCatalogError.serverError(error.message)
                }
                guard let result = envelope.result else {
                    throw CodexModelCatalogError.invalidResponse
                }

                availableModels.append(contentsOf: result.data.filter { !$0.hidden })
                guard let nextCursor = result.nextCursor else {
                    return availableModels
                }

                requestIdentifier += 1
                try writeModelListRequest(
                    id: requestIdentifier,
                    cursor: nextCursor,
                    to: inputPipe.fileHandleForWriting
                )
            }
        }

        throw CodexModelCatalogError.timedOut
    }

    private static func writeModelListRequest(
        id: Int,
        cursor: String?,
        to output: FileHandle
    ) throws {
        var parameters: [String: Any] = [
            "includeHidden": false,
            "limit": 100
        ]
        if let cursor { parameters["cursor"] = cursor }
        try writeRequest(
            ["id": id, "method": "model/list", "params": parameters],
            to: output
        )
    }

    private static func writeRequest(_ request: [String: Any], to output: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        try output.write(contentsOf: data)
    }
}
