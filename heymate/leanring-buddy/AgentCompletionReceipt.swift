//
//  AgentCompletionReceipt.swift
//  leanring-buddy
//
//  Shareable proof of completed agent work. Receipts deliberately contain
//  outcome metadata, not the private task prompt, workspace location, CLI
//  session identifier, or activity log.
//

import CryptoKit
import Foundation

nonisolated enum AgentWorkspaceChangeKind: String, Codable, Equatable, Sendable {
    case added
    case modified
    case deleted
}

nonisolated struct AgentWorkspaceChange: Codable, Equatable, Sendable {
    let kind: AgentWorkspaceChangeKind
    let path: String
}

/// Exact change counts plus a bounded set of relative paths suitable for UI
/// and sharing. Counts remain complete when `displayedChanges` is capped.
nonisolated struct AgentWorkspaceChangeSummary: Codable, Equatable, Sendable {
    let addedCount: Int
    let modifiedCount: Int
    let deletedCount: Int
    let displayedChanges: [AgentWorkspaceChange]
    let omittedDisplayPathCount: Int

    var totalCount: Int {
        addedCount + modifiedCount + deletedCount
    }

    static let empty = AgentWorkspaceChangeSummary(
        addedCount: 0,
        modifiedCount: 0,
        deletedCount: 0,
        displayedChanges: [],
        omittedDisplayPathCount: 0
    )
}

nonisolated enum AgentWorkspaceChangeScannerError: LocalizedError, Equatable {
    case directoryMissing(String)
    case couldNotEnumerate(String)

    var errorDescription: String? {
        switch self {
        case .directoryMissing(let label):
            return "Could not measure agent changes because the \(label) directory is missing."
        case .couldNotEnumerate(let detail):
            return "Could not measure agent changes: \(detail)"
        }
    }
}

/// Compares the pre-write undo snapshot with the current workspace by file
/// content rather than timestamp or byte count. Generated dependency trees
/// and build products never become shareable receipt paths.
nonisolated enum AgentWorkspaceChangeScanner {
    static let defaultMaximumDisplayedPaths = 12

    private static let excludedDirectoryNames: Set<String> = [
        ".git",
        ".build",
        "build",
        "deriveddata",
        "node_modules"
    ]

    private static let excludedBundleExtensions: Set<String> = [
        "app",
        "appex",
        "dsym",
        "framework",
        "xcarchive",
        "xcresult"
    ]

    static func scan(
        beforeSnapshotURL: URL,
        currentWorkspaceURL: URL,
        maximumDisplayedPaths: Int = defaultMaximumDisplayedPaths,
        fileManager: FileManager = .default
    ) throws -> AgentWorkspaceChangeSummary {
        let beforeFingerprints = try fingerprints(
            below: beforeSnapshotURL,
            label: "before snapshot",
            fileManager: fileManager
        )
        let currentFingerprints = try fingerprints(
            below: currentWorkspaceURL,
            label: "current workspace",
            fileManager: fileManager
        )

        let beforePaths = Set(beforeFingerprints.keys)
        let currentPaths = Set(currentFingerprints.keys)
        let addedPaths = currentPaths.subtracting(beforePaths)
        let deletedPaths = beforePaths.subtracting(currentPaths)
        let modifiedPaths = beforePaths.intersection(currentPaths).filter {
            beforeFingerprints[$0] != currentFingerprints[$0]
        }

        var allChanges = addedPaths.map {
            AgentWorkspaceChange(kind: .added, path: $0)
        }
        allChanges += modifiedPaths.map {
            AgentWorkspaceChange(kind: .modified, path: $0)
        }
        allChanges += deletedPaths.map {
            AgentWorkspaceChange(kind: .deleted, path: $0)
        }
        allChanges.sort {
            if $0.path == $1.path {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }

        let displayLimit = max(0, maximumDisplayedPaths)
        let displayedChanges = Array(allChanges.prefix(displayLimit))
        return AgentWorkspaceChangeSummary(
            addedCount: addedPaths.count,
            modifiedCount: modifiedPaths.count,
            deletedCount: deletedPaths.count,
            displayedChanges: displayedChanges,
            omittedDisplayPathCount: allChanges.count - displayedChanges.count
        )
    }

    private static func fingerprints(
        below rootURL: URL,
        label: String,
        fileManager: FileManager
    ) throws -> [String: String] {
        let standardizedRootURL = rootURL.standardizedFileURL
        var rootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: standardizedRootURL.path,
            isDirectory: &rootIsDirectory
        ), rootIsDirectory.boolValue else {
            throw AgentWorkspaceChangeScannerError.directoryMissing(label)
        }

        let resourceKeys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: standardizedRootURL,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: { _, error in
                enumerationError = enumerationError ?? error
                return false
            }
        ) else {
            throw AgentWorkspaceChangeScannerError.couldNotEnumerate(label)
        }

        var result: [String: String] = [:]
        for case let fileURL as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: Set(resourceKeys))
            } catch {
                throw AgentWorkspaceChangeScannerError.couldNotEnumerate(
                    error.localizedDescription
                )
            }

            if values.isDirectory == true, shouldExcludeDirectory(fileURL) {
                enumerator.skipDescendants()
                continue
            }

            guard let relativePath = relativePath(for: fileURL, below: standardizedRootURL) else {
                continue
            }

            do {
                if values.isSymbolicLink == true {
                    let destination = try fileManager.destinationOfSymbolicLink(atPath: fileURL.path)
                    result[relativePath] = sha256Hex(Data("symlink:\(destination)".utf8))
                } else if values.isRegularFile == true {
                    result[relativePath] = try sha256Hex(ofFileAt: fileURL)
                }
            } catch {
                throw AgentWorkspaceChangeScannerError.couldNotEnumerate(
                    error.localizedDescription
                )
            }
        }

        if let enumerationError {
            throw AgentWorkspaceChangeScannerError.couldNotEnumerate(
                enumerationError.localizedDescription
            )
        }
        return result
    }

    private static func shouldExcludeDirectory(_ directoryURL: URL) -> Bool {
        let name = directoryURL.lastPathComponent.lowercased()
        if excludedDirectoryNames.contains(name) { return true }
        return excludedBundleExtensions.contains(directoryURL.pathExtension.lowercased())
    }

    private static func relativePath(for fileURL: URL, below rootURL: URL) -> String? {
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return nil }
        return String(filePath.dropFirst(rootPath.count))
    }

    private static func sha256Hex(ofFileAt fileURL: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        while let chunk = try fileHandle.read(upToCount: 256 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Builds a portable Markdown receipt from user-safe fields only. This type
/// never reads `title` (derived from the prompt), `prompt`, `workspacePath`,
/// `sessionIdentifier`, `activity`, `latestAction`, or `error` from `AgentRun`.
nonisolated enum AgentCompletionReceipt {
    static func markdown(
        for run: AgentRun,
        changes: AgentWorkspaceChangeSummary? = nil,
        generatedAt: Date = Date()
    ) -> String {
        let outcome = AgentReceiptPrivacy.safeInline(
            run.summary,
            fallback: "No shareable outcome was recorded."
        )
        let startDate = run.startedAt ?? run.createdAt
        let endDate = run.finishedAt ?? generatedAt

        var lines = [
            "# HeyMate completion receipt",
            "",
            "## Completed agent work",
            "",
            "- Result: \(statusLabel(for: run.status))",
            "- Duration: \(durationLabel(max(0, endDate.timeIntervalSince(startDate))))",
            "- Agent: \(executorSignInLabel(for: run.executor))",
            "- Changes: \(changeCountLabel(changes))",
            "",
            "### Outcome",
            "",
            outcome
        ]

        if let changes, !changes.displayedChanges.isEmpty {
            lines += ["", "### Changed files", ""]
            for change in changes.displayedChanges {
                guard let path = AgentReceiptPrivacy.safeRelativePath(change.path) else { continue }
                lines.append("- \(changeLabel(change.kind)): `\(path)`")
            }
            if changes.omittedDisplayPathCount > 0 {
                lines.append("- \(changes.omittedDisplayPathCount) more path\(changes.omittedDisplayPathCount == 1 ? "" : "s") not shown")
            }
        }

        lines += [
            "",
            "### Safety",
            "",
            "- Plan gate: \(planGateLabel(for: run))",
            "- Undo: \(undoLabel(for: run))",
            "",
            "Generated by HeyMate."
        ]
        return lines.joined(separator: "\n")
    }

    private static func statusLabel(for status: AgentRunStatus) -> String {
        switch status {
        case .queued: return "Queued"
        case .planning: return "Planning"
        case .awaitingPlanApproval: return "Awaiting plan approval"
        case .running: return "Running"
        case .waitingForApproval: return "Waiting for approval"
        case .succeeded: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private static func durationLabel(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded())
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        if totalSeconds < 3_600 {
            return "\(totalSeconds / 60)m \(totalSeconds % 60)s"
        }
        return "\(totalSeconds / 3_600)h \((totalSeconds % 3_600) / 60)m"
    }

    private static func executorSignInLabel(for executor: HeadlessExecutor) -> String {
        switch executor {
        case .claudeCode:
            return "Claude Code via your existing Claude subscription sign-in"
        case .codex:
            return "Codex via your existing ChatGPT subscription sign-in"
        case .openCode:
            return "OpenCode via your configured provider sign-in"
        }
    }

    private static func changeCountLabel(_ changes: AgentWorkspaceChangeSummary?) -> String {
        guard let changes else { return "Not measured" }
        return "\(changes.addedCount) added, \(changes.modifiedCount) modified, \(changes.deletedCount) deleted"
    }

    private static func changeLabel(_ kind: AgentWorkspaceChangeKind) -> String {
        switch kind {
        case .added: return "Added"
        case .modified: return "Modified"
        case .deleted: return "Deleted"
        }
    }

    private static func planGateLabel(for run: AgentRun) -> String {
        if !run.planText.isEmpty, !run.undoEntryIdentifier.isEmpty {
            return "Read-only plan approved before write access."
        }
        if !run.planText.isEmpty {
            return "Read-only plan recorded; write approval is not recorded in this receipt."
        }
        return "No plan-gate record is available for this run."
    }

    private static func undoLabel(for run: AgentRun) -> String {
        run.undoEntryIdentifier.isEmpty
            ? "No pre-write workspace snapshot is recorded."
            : "Pre-write workspace snapshot recorded for Undo."
    }
}

nonisolated private enum AgentReceiptPrivacy {
    private static let replacement = "[REDACTED]"
    private static let maximumTextLength = 800

    private static let secretPatterns: [(pattern: String, template: String)] = [
        (#"-----BEGIN [^-\n]*PRIVATE KEY-----[\s\S]*?-----END [^-\n]*PRIVATE KEY-----"#, replacement),
        (#"(?i)(authorization\s*:\s*bearer\s+)[^\s\"']+"#, "$1\(replacement)"),
        (#"(?i)((?:api[_-]?key|access[_-]?token|auth[_-]?token|token|client[_-]?secret|password|passwd|secret)\s*[:=]\s*[\"']?)[^\s,\"'}]+"#, "$1\(replacement)"),
        (#"(?i)(--(?:api-key|token|password|secret)(?:=|\s+))[^\s]+"#, "$1\(replacement)"),
        (#"(?i)\b(?:sk-(?:ant-|proj-)?|github_pat_|gh[pousr]_|xox[baprs]-)[A-Za-z0-9_\-]+"#, replacement),
        (#"\bAKIA[0-9A-Z]{16}\b"#, replacement),
        (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, replacement)
    ]

    private static let absolutePathPatterns: [(pattern: String, template: String)] = [
        (#"(?i)file:///[^\s,;:)\]}>\"']+"#, "[local path]"),
        (#"(?i)(^|[\s(\"'=])~/(?:[^\s,;:)\]}>\"']+)"#, "$1[local path]"),
        (#"(?i)(^|[\s(\[\{\"'=,:;])/(?!/)(?:[^\s,;:)\]}>\"']+)"#, "$1[local path]"),
        (#"(?i)\b[A-Z]:\\(?:[^\\\s]+\\)*[^\\\s]+"#, "[local path]")
    ]

    static func safeInline(_ value: String, fallback: String) -> String {
        var safeValue = redactSecrets(in: value)
        safeValue = redactAbsolutePaths(in: safeValue)
        safeValue = safeValue
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        if safeValue.count > maximumTextLength {
            safeValue = String(safeValue.prefix(maximumTextLength)) + "…"
        }
        guard !safeValue.isEmpty else { return fallback }
        return escapeMarkdownInline(safeValue)
    }

    static func safeRelativePath(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty,
              !trimmedValue.hasPrefix("/"),
              !trimmedValue.hasPrefix("~/"),
              !trimmedValue.lowercased().hasPrefix("file:"),
              trimmedValue.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) == nil else {
            return nil
        }

        let normalizedValue = trimmedValue.replacingOccurrences(of: "\\", with: "/")
        let components = normalizedValue.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else { return nil }
        return escapeMarkdownCode(redactSecrets(in: normalizedValue))
    }

    private static func redactSecrets(in value: String) -> String {
        var result = value
        for item in secretPatterns {
            guard let expression = try? NSRegularExpression(
                pattern: item.pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: item.template
            )
        }
        return result
    }

    private static func redactAbsolutePaths(in value: String) -> String {
        var result = value
        for item in absolutePathPatterns {
            guard let expression = try? NSRegularExpression(pattern: item.pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: item.template
            )
        }
        return result
    }

    private static func escapeMarkdownInline(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["`", "*", "_", "[", "]", "<", ">"] {
            result = result.replacingOccurrences(of: character, with: "\\\(character)")
        }
        return result
    }

    private static func escapeMarkdownCode(_ value: String) -> String {
        value.replacingOccurrences(of: "`", with: "′")
    }
}
