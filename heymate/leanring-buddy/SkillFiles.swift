//
//  SkillFiles.swift
//  leanring-buddy
//
//  Markdown skill-file support (master spec FR-13, clean-room format).
//  Skills live as .md files with YAML frontmatter (name, trigger, tools)
//  followed by an instructions body. This module parses that tiny YAML
//  subset, loads every skill from the default Application Support folder,
//  and ranks skills against a conversation transcript so the companion can
//  inject only the relevant ones into a prompt.
//

import Foundation

/// One parsed skill definition loaded from a Markdown file with YAML
/// frontmatter (FR-13 clean-room format).
nonisolated struct SkillFile: Equatable {
    /// Frontmatter `name` — stable identifier used when injecting the skill.
    let name: String
    /// Frontmatter `trigger` — natural-language description matched against
    /// the transcript to decide relevance.
    let trigger: String
    /// Frontmatter `tools` YAML list; may be empty when the skill needs none.
    let tools: [String]
    /// Body after the second `---` fence, trimmed.
    let instructions: String
}

nonisolated enum SkillMarkdownParser {

    /// Parses frontmatter + body. Returns nil when: no --- fences, missing
    /// required name/trigger, or malformed fence structure. Tolerant of
    /// CRLF and trailing whitespace. Unknown frontmatter keys ignored.
    /// Simple YAML subset ONLY: `key: value` scalars and `key:` followed by
    /// `  - item` list lines. No nested maps, anchors, quotes handling beyond
    /// stripping surrounding double quotes on scalar values.
    nonisolated static func parse(_ markdown: String) -> SkillFile? {
        // Normalize line endings up front so CRLF files behave identically
        // to LF files everywhere below.
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        // The document must OPEN with a --- fence: find the first line that
        // carries any content and require it to be exactly the fence marker.
        guard let openingFenceIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[openingFenceIndex].trimmingCharacters(in: .whitespaces) == "---"
        else { return nil }

        // The frontmatter section must be CLOSED by a second --- fence;
        // anything else is a malformed structure.
        guard let closingFenceIndex = lines[(openingFenceIndex + 1)...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        })
        else { return nil }

        let frontmatterLines = lines[(openingFenceIndex + 1)..<closingFenceIndex]

        var nameValue: String?
        var triggerValue: String?
        var descriptionValue: String?
        var toolItems: [String] = []
        // Tracks whether loose `- item` lines belong to the `tools` key;
        // items under any other (unknown) key are ignored.
        var isCollectingToolItems = false

        for line in frontmatterLines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty { continue }

            if trimmedLine.hasPrefix("-") {
                guard isCollectingToolItems else { continue }
                let item = trimmedLine.dropFirst().trimmingCharacters(in: .whitespaces)
                toolItems.append(unquote(item))
                continue
            }

            guard let keySeparatorIndex = trimmedLine.firstIndex(of: ":") else { continue }
            let key = trimmedLine[..<keySeparatorIndex].trimmingCharacters(in: .whitespaces)
            let rawValue = trimmedLine[trimmedLine.index(after: keySeparatorIndex)...]
                .trimmingCharacters(in: .whitespaces)

            switch key {
            case "name":
                isCollectingToolItems = false
                nameValue = unquote(rawValue)
            case "trigger":
                isCollectingToolItems = false
                triggerValue = unquote(rawValue)
            case "description":
                isCollectingToolItems = false
                descriptionValue = unquote(rawValue)
            case "tools":
                // Only the block-list form (`tools:` followed by `- item`
                // lines) is supported; an inline value is not part of the
                // recognized subset and is ignored.
                isCollectingToolItems = rawValue.isEmpty
            case "allowed-tools":
                // Claude Code commonly declares tools as a single
                // whitespace/comma separated scalar. Preserve tool names for
                // review without treating this declaration as permission.
                isCollectingToolItems = false
                toolItems += rawValue
                    .split { $0 == "," || $0.isWhitespace }
                    .map(String.init)
                    .map(unquote)
                    .filter { !$0.isEmpty }
            default:
                // Unknown frontmatter keys are tolerated and skipped.
                isCollectingToolItems = false
            }
        }

        let triggerOrDescription = triggerValue ?? descriptionValue
        guard let parsedName = nameValue, !parsedName.isEmpty,
              let parsedTrigger = triggerOrDescription, !parsedTrigger.isEmpty
        else { return nil }

        let instructionLines = lines[(closingFenceIndex + 1)...]
        let instructions = instructionLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return SkillFile(
            name: parsedName,
            trigger: parsedTrigger,
            tools: toolItems,
            instructions: instructions
        )
    }

    /// Loads + parses every *.md in directory (sorted by filename).
    /// Missing directory → []. Non-recursive.
    static func loadAll(fromDirectory url: URL) -> [SkillFile] {
        let fileManager = FileManager.default
        guard let directoryEntries = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }

        let markdownFileURLs = directoryEntries
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return markdownFileURLs.compactMap { markdownFileURL in
            guard let markdown = try? String(contentsOf: markdownFileURL, encoding: .utf8) else {
                return nil
            }
            return parse(markdown)
        }
    }

    /// Default dir: Application Support/heymate/skills (auto-created).
    static func defaultDirectory() -> URL {
        let fileManager = FileManager.default
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        let skillsDirectoryURL = applicationSupportURL
            .appendingPathComponent("heymate", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)

        try? fileManager.createDirectory(at: skillsDirectoryURL, withIntermediateDirectories: true)
        return skillsDirectoryURL
    }

    /// Writes every bundled default skill that does not exist yet in the
    /// destination directory (HeyClicky ships a curated library; HeyMate
    /// seeds its own clean-room set so the skill pipeline is useful on first
    /// launch). Files already present are never touched — user edits and
    /// deletions survive app updates. Returns the file names written.
    nonisolated static func seedDefaultsIfNeeded(
        intoDirectory destinationURL: URL,
        defaults: [(fileName: String, markdown: String)] = DefaultSkillCatalog.skills,
        fileManager: FileManager = .default
    ) -> [String] {
        try? fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        var writtenFileNames: [String] = []
        for defaultSkill in defaults {
            let destinationFileURL = destinationURL.appendingPathComponent(defaultSkill.fileName)
            let alreadyExists = fileManager.fileExists(atPath: destinationFileURL.path)
            guard !alreadyExists else { continue }

            do {
                try defaultSkill.markdown.write(
                    to: destinationFileURL,
                    atomically: true,
                    encoding: .utf8
                )
                writtenFileNames.append(defaultSkill.fileName)
            } catch {
                // A failed seed must never break app startup; skip it.
                continue
            }
        }
        return writtenFileNames
    }

    /// Strips one pair of surrounding double quotes from a scalar value,
    /// leaving interior content untouched.
    private nonisolated static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}

nonisolated enum SkillRetrieval {

    /// Scores skills by case-insensitive word overlap between the skill's
    /// trigger text and the transcript; returns top `limit` with score > 0,
    /// highest first. Ties broken by original order.
    nonisolated static func relevant(
        skills: [SkillFile],
        transcript: String,
        limit: Int = 3
    ) -> [SkillFile] {
        let transcriptWords = Set(tokenize(transcript))

        var scoredSkills: [(originalIndex: Int, score: Int, skill: SkillFile)] = []
        for (originalIndex, skill) in skills.enumerated() {
            let triggerWords = Set(tokenize(skill.trigger))
            let overlapScore = triggerWords.filter { transcriptWords.contains($0) }.count
            guard overlapScore > 0 else { continue }
            scoredSkills.append((originalIndex, overlapScore, skill))
        }

        let rankedSkills = scoredSkills.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            // Equal scores fall back to original ordering so ranking is
            // deterministic regardless of how the sort algorithm shuffles.
            return lhs.originalIndex < rhs.originalIndex
        }

        return Array(rankedSkills.prefix(max(limit, 0)).map(\.skill))
    }

    /// Lowercases and splits into alphanumeric word tokens so punctuation
    /// and casing never affect the overlap comparison.
    private nonisolated static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
