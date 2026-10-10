//
//  ClaudeModelCatalog.swift
//  HeyMate
//
//  Models come from the Claude CLI installed on this Mac. Updating Claude
//  Code is what adds a model. HeyMate does not keep its own list.
//

import Foundation

nonisolated struct ClaudeModelOption: Equatable, Hashable, Identifiable {
    /// Passed straight to `claude --model`. An alias such as `opus` tracks
    /// the latest of that family. A full id pins one model.
    let id: String
    let displayName: String
    let summary: String
    let isLatestAlias: Bool
}

nonisolated enum ClaudeModelCatalogError: LocalizedError {
    case cliNotInstalled
    case unreadableCLI

    var errorDescription: String? {
        switch self {
        case .cliNotInstalled:
            return "Claude CLI is not installed."
        case .unreadableCLI:
            return "Could not read the Claude CLI's model list."
        }
    }
}

nonisolated enum ClaudeModelCatalogParser {
    /// Used only when the installed CLI cannot be read.
    static let fallbackOptions: [ClaudeModelOption] = [
        option(alias: "fable", summary: "Latest Fable in your Claude CLI"),
        option(alias: "opus", summary: "Latest Opus in your Claude CLI"),
        option(alias: "sonnet", summary: "Latest Sonnet in your Claude CLI"),
        option(alias: "haiku", summary: "Latest Haiku in your Claude CLI")
    ]

    static func identifiers(in text: String) -> [String] {
        longestIdentifierRun(in: Data(text.utf8))
    }

    /// Longest run of quoted `claude-…` ids. The CLI embeds that run; the
    /// newest install is what makes a new id show up.
    static func longestIdentifierRun(in data: Data) -> [String] {
        let needle = Data("\"claude-".utf8)
        var best: [String] = []
        var searchStart = data.startIndex
        while let found = data[searchStart...].range(of: needle) {
            let run = identifierRun(in: data, startingAt: found.lowerBound)
            if run.ids.count > best.count { best = run.ids }
            searchStart = run.next
            if searchStart >= data.endIndex { break }
        }
        var seen = Set<String>()
        return best.filter { seen.insert($0).inserted }
    }

    private static func identifierRun(in data: Data, startingAt start: Data.Index) -> (ids: [String], next: Data.Index) {
        var ids: [String] = []
        var cursor = start
        while cursor < data.endIndex, data[cursor] == quote,
              let parsed = quotedClaudeIdentifier(in: data, from: cursor) {
            ids.append(parsed.id)
            cursor = parsed.next
            guard cursor < data.endIndex, data[cursor] == comma else { break }
            cursor = data.index(after: cursor)
        }
        let next = cursor < data.endIndex ? data.index(after: cursor) : data.endIndex
        return (ids, next)
    }

    private static func quotedClaudeIdentifier(
        in data: Data,
        from start: Data.Index
    ) -> (id: String, next: Data.Index)? {
        guard start < data.endIndex, data[start] == quote else { return nil }
        var cursor = data.index(after: start)
        var collected: [UInt8] = []
        while cursor < data.endIndex, data[cursor] != quote {
            let byte = data[cursor]
            let isAllowed = byte == 45 || (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122)
            guard isAllowed else { return nil }
            collected.append(byte)
            cursor = data.index(after: cursor)
            if collected.count > 80 { return nil }
        }
        guard cursor < data.endIndex, data[cursor] == quote else { return nil }
        guard let id = String(bytes: collected, encoding: .utf8), id.hasPrefix("claude-") else { return nil }
        return (id, data.index(after: cursor))
    }

    private static let quote: UInt8 = 34
    private static let comma: UInt8 = 44

    static func options(from identifiers: [String]) -> [ClaudeModelOption] {
        let concrete = identifiers.filter { familyName($0) != nil }
        guard !concrete.isEmpty else { return [] }
        var newestByFamily: [String: String] = [:]
        for identifier in concrete {
            guard let family = familyName(identifier) else { continue }
            if let current = newestByFamily[family], !isNewer(identifier, than: current) { continue }
            newestByFamily[family] = identifier
        }
        let aliases = preferredFamilies.compactMap { family -> ClaudeModelOption? in
            guard let latest = newestByFamily[family] else { return nil }
            return ClaudeModelOption(
                id: family,
                displayName: displayName(for: latest),
                summary: "Latest \(family.capitalized) in your Claude CLI",
                isLatestAlias: true
            )
        }
        let newestIDs = Set(newestByFamily.values)
        let older = concrete
            .filter { !newestIDs.contains($0) }
            .map { id in
                ClaudeModelOption(
                    id: id,
                    displayName: displayName(for: id),
                    summary: "Pinned model from your Claude CLI",
                    isLatestAlias: false
                )
            }
        return aliases + older
    }

    private static let preferredFamilies = ["fable", "mythos", "opus", "sonnet", "haiku"]

    private static func option(alias: String, summary: String) -> ClaudeModelOption {
        ClaudeModelOption(
            id: alias,
            displayName: alias.prefix(1).uppercased() + alias.dropFirst(),
            summary: summary,
            isLatestAlias: true
        )
    }

    /// `claude-fable-5-1` is newer than `claude-fable-5`. Missing trailing
    /// parts count as zero, so `5` loses to `5.1` and `5.5`.
    static func isNewer(_ identifier: String, than other: String) -> Bool {
        let left = versionNumbers(in: identifier)
        let right = versionNumbers(in: other)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let leftPart = index < left.count ? left[index] : 0
            let rightPart = index < right.count ? right[index] : 0
            if leftPart != rightPart { return leftPart > rightPart }
        }
        return false
    }

    private static func versionNumbers(in identifier: String) -> [Int] {
        identifier.split(separator: "-").dropFirst(2).compactMap { Int($0) }
    }

    /// `claude-opus-4-8` → opus. `claude-3-5-sonnet` is not a family alias.
    static func familyName(_ identifier: String) -> String? {
        let parts = identifier.split(separator: "-").map(String.init)
        guard parts.count >= 2, parts[0] == "claude" else { return nil }
        let family = parts[1]
        guard family.allSatisfy(\.isLetter) else { return nil }
        return family
    }

    static func displayName(for identifier: String) -> String {
        guard let family = familyName(identifier) else { return identifier }
        let parts = identifier.split(separator: "-").map(String.init)
        let version = parts.dropFirst(2).joined(separator: ".")
        let title = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? title : "\(title) \(version)"
    }
}

nonisolated enum ClaudeModelCatalogLoader {
    static func fetchAvailableModels() async throws -> [ClaudeModelOption] {
        try await Task.detached(priority: .userInitiated) {
            try fetchAvailableModelsSynchronously()
        }.value
    }

    private static func fetchAvailableModelsSynchronously() throws -> [ClaudeModelOption] {
        guard let executableURL = LoginShellExecutableResolver.resolveExecutable(named: "claude") else {
            throw ClaudeModelCatalogError.cliNotInstalled
        }
        let resolved = executableURL.resolvingSymlinksInPath()
        let data: Data
        do {
            data = try Data(contentsOf: resolved, options: [.mappedIfSafe])
        } catch {
            throw ClaudeModelCatalogError.unreadableCLI
        }
        let options = ClaudeModelCatalogParser.options(
            from: ClaudeModelCatalogParser.longestIdentifierRun(in: data)
        )
        guard !options.isEmpty else { throw ClaudeModelCatalogError.unreadableCLI }
        return options
    }
}

/// One `claude --effort` level. The levels come from the installed CLI's
/// own help text, so a new level shows up when Claude Code adds it.
nonisolated struct ClaudeEffortOption: Equatable, Hashable, Identifiable {
    let effort: String

    var id: String { effort }

    var displayName: String {
        effort == "xhigh" ? "X-High" : effort.capitalized
    }
}

nonisolated enum ClaudeEffortCatalog {
    /// Used only when the installed CLI's help cannot be read.
    static let fallbackOptions: [ClaudeEffortOption] = ["low", "medium", "high", "xhigh", "max"]
        .map(ClaudeEffortOption.init(effort:))

    /// Pulls `(low, medium, …)` out of the `--effort <level>` help entry.
    /// Returns an empty list when the CLI has no `--effort` flag at all.
    static func options(fromHelpText helpText: String) -> [ClaudeEffortOption] {
        guard let flagRange = helpText.range(of: "--effort"),
              let open = helpText[flagRange.upperBound...].firstIndex(of: "("),
              let close = helpText[open...].firstIndex(of: ")") else { return [] }
        let levels = helpText[helpText.index(after: open)..<close]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isLetter } }
        return levels.map(ClaudeEffortOption.init(effort:))
    }

    static func fetchAvailableEfforts() async -> [ClaudeEffortOption] {
        await Task.detached(priority: .utility) {
            guard let helpText = readHelpText() else { return fallbackOptions }
            return options(fromHelpText: helpText)
        }.value
    }

    private static func readHelpText() -> String? {
        guard let executableURL = LoginShellExecutableResolver.resolveExecutable(named: "claude") else {
            return nil
        }
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--help"]
        process.environment = HeadlessChildEnvironment.build(
            stripping: HeadlessExecutor.claudeCode.environmentKeysToRemove
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let timeoutWorkItem = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: timeoutWorkItem)
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutWorkItem.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
