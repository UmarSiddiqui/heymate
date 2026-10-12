import Foundation

nonisolated enum AgentReceiptPrivacy {
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

    /// Private final answers still redact obvious credentials and identifiers.
    /// Keep paragraphs, but bound the result to the durable summary limit.
    /// This is not sufficient to make arbitrary answer prose shareable.
    static func safeResult(_ value: String) -> String {
        var safe = redactAbsolutePaths(in: redactSecrets(in: value))
        for pattern in [#"(?i)\b(?:https?|file)://[^\s<>\"']+"#,
                        #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#] {
            if let expression = try? NSRegularExpression(pattern: pattern) {
                safe = expression.stringByReplacingMatches(in: safe, range: NSRange(safe.startIndex..., in: safe), withTemplate: "[REDACTED]")
            }
        }
        let trimmed = safe.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 512 ? String(trimmed.prefix(511)) + "…" : trimmed
    }

    /// Private result text may contain ordinary source URLs and email addresses.
    /// Credentials and local absolute paths are still removed. This value must
    /// never enter portable receipts, diagnostics, or the metadata journal.
    static func privateAnswer(_ value: String) -> String {
        let safe = redactAbsolutePaths(in: redactSecrets(in: value))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard safe.utf8.count > AgentFinalResult.maximumAnswerBytes else { return safe }
        let notice = "\n\n[Result truncated at 32 KiB. Ask the agent for a shorter answer or a specific section.]"
        let bytes = safe.utf8.prefix(AgentFinalResult.maximumAnswerBytes - notice.utf8.count)
        // Drop an incomplete trailing UTF-8 scalar rather than inserting an
        // invalid byte or exceeding the artifact's byte limit.
        var prefix = Data(bytes)
        while String(data: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        return (String(data: prefix, encoding: .utf8) ?? "") + notice
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
