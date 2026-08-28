//
//  HeyMateSecrets.swift
//  leanring-buddy
//
//  Reads local KEY=VALUE secrets from disk so API keys never need to live
//  in the repo. Process environment always wins over the file. Values are
//  never logged — `presentKeys()` returns names only.
//
//  Known keys (none are required; missing → nil):
//  ANTHROPIC_API_KEY, OPENAI_API_KEY, ASSEMBLYAI_API_KEY, ELEVENLABS_API_KEY,
//  ELEVENLABS_VOICE_ID, GOG_KEYRING_PASSWORD, HEYMATE_BRIDGE_TOKEN
//

import Foundation

nonisolated enum HeyMateSecrets {

    static let secretsFileEnvironmentKey = "HEYMATE_SECRETS_FILE"

    static let documentedKeyNames: [String] = [
        "ANTHROPIC_API_KEY",
        "OPENAI_API_KEY",
        "ASSEMBLYAI_API_KEY",
        "ELEVENLABS_API_KEY",
        "ELEVENLABS_VOICE_ID",
        "GOG_KEYRING_PASSWORD",
        "HEYMATE_BRIDGE_TOKEN"
    ]

    // MARK: - Production lookup

    /// Process environment (non-empty) → secrets file → nil.
    static func lookup(_ key: String) -> String? {
        lookup(
            key,
            fileURLs: secretsFileURLs(),
            processEnvironment: ProcessInfo.processInfo.environment
        )
    }

    /// Names of documented keys that currently resolve to a value. Never values.
    static func presentKeys() -> [String] {
        presentKeys(
            fileURLs: secretsFileURLs(),
            processEnvironment: ProcessInfo.processInfo.environment
        )
    }

    /// Process environment plus file keys that are not already set (non-empty)
    /// in the process environment. Intended for child CLI processes.
    static func mergedProcessEnvironment() -> [String: String] {
        mergedProcessEnvironment(
            processEnvironment: ProcessInfo.processInfo.environment,
            fileURLs: secretsFileURLs()
        )
    }

    /// `HEYMATE_SECRETS_FILE` (absolute path) first, then `~/.config/heymate/secrets.env`.
    static func secretsFileURLs() -> [URL] {
        secretsFileURLs(
            processEnvironment: ProcessInfo.processInfo.environment,
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    // MARK: - Testable hooks (no default `~/.config` access)

    static func secretsFileURLs(
        processEnvironment: [String: String],
        homeDirectoryURL: URL
    ) -> [URL] {
        var urls: [URL] = []

        if let explicitSecretsFilePath = normalizedValue(processEnvironment[secretsFileEnvironmentKey]) {
            urls.append(URL(fileURLWithPath: explicitSecretsFilePath))
        }

        urls.append(
            homeDirectoryURL
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("heymate", isDirectory: true)
                .appendingPathComponent("secrets.env", isDirectory: false)
        )

        return urls
    }

    static func lookup(
        _ key: String,
        fileContents: String,
        processEnvironment: [String: String]
    ) -> String? {
        if let processValue = normalizedValue(processEnvironment[key]) {
            return processValue
        }
        return parseEntries(from: fileContents)[key]
    }

    static func lookup(
        _ key: String,
        fileURLs: [URL],
        processEnvironment: [String: String]
    ) -> String? {
        if let processValue = normalizedValue(processEnvironment[key]) {
            return processValue
        }
        return parsedEntries(from: fileURLs)[key]
    }

    static func presentKeys(
        fileContents: String,
        processEnvironment: [String: String]
    ) -> [String] {
        documentedKeyNames.filter { key in
            lookup(key, fileContents: fileContents, processEnvironment: processEnvironment) != nil
        }
    }

    static func presentKeys(
        fileURLs: [URL],
        processEnvironment: [String: String]
    ) -> [String] {
        documentedKeyNames.filter { key in
            lookup(key, fileURLs: fileURLs, processEnvironment: processEnvironment) != nil
        }
    }

    static func mergedProcessEnvironment(
        processEnvironment: [String: String],
        fileContents: String
    ) -> [String: String] {
        overlay(
            processEnvironment: processEnvironment,
            fileEntries: parseEntries(from: fileContents)
        )
    }

    static func mergedProcessEnvironment(
        processEnvironment: [String: String],
        fileURLs: [URL]
    ) -> [String: String] {
        overlay(
            processEnvironment: processEnvironment,
            fileEntries: parsedEntries(from: fileURLs)
        )
    }

    // MARK: - Parsing

    private static func overlay(
        processEnvironment: [String: String],
        fileEntries: [String: String]
    ) -> [String: String] {
        var merged = processEnvironment
        for (key, value) in fileEntries {
            if normalizedValue(processEnvironment[key]) == nil {
                merged[key] = value
            }
        }
        return merged
    }

    /// Earlier URLs win. Unreadable / missing files are skipped.
    private static func parsedEntries(from fileURLs: [URL]) -> [String: String] {
        var entries: [String: String] = [:]
        for fileURL in fileURLs {
            guard let fileContents = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            for (key, value) in parseEntries(from: fileContents) where entries[key] == nil {
                entries[key] = value
            }
        }
        return entries
    }

    private static func parseEntries(from fileContents: String) -> [String: String] {
        var entries: [String: String] = [:]

        for rawLine in fileContents.components(separatedBy: .newlines) {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("#") else {
                continue
            }

            let lineWithoutExportPrefix: String
            if trimmedLine.hasPrefix("export ") {
                lineWithoutExportPrefix = String(trimmedLine.dropFirst("export ".count))
            } else {
                lineWithoutExportPrefix = trimmedLine
            }

            let keyValueParts = lineWithoutExportPrefix.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard keyValueParts.count == 2 else {
                continue
            }

            let parsedKey = keyValueParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !parsedKey.isEmpty, entries[parsedKey] == nil else {
                continue
            }

            let rawValue = keyValueParts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = normalizedValue(trimmingMatchingQuotes(rawValue)) {
                entries[parsedKey] = value
            }
        }

        return entries
    }

    private static func normalizedValue(_ value: String?) -> String? {
        guard let value else { return nil }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }

        // Unresolved placeholders (Info.plist / env templates) must not be
        // treated as real secrets.
        if trimmedValue.hasPrefix("$("), trimmedValue.hasSuffix(")") {
            return nil
        }

        return trimmedValue
    }

    private static func trimmingMatchingQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }

        if value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }

        if value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }

        return value
    }
}
