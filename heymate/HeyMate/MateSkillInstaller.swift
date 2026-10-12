//
//  MateSkillInstaller.swift
//  HeyMate
//
//  Copies matched Claude Code-style skills into a mate workspace before an
//  execute leg so agent children can read them from disk.
//

import Foundation

enum MateSkillInstaller {

    /// Scans `skillsRoot` for `*/SKILL.md` files whose folder name or
    /// front-matter `name` appears in `userText`, then copies each match to
    /// `folder/skills/<name>/SKILL.md`. Missing `skillsRoot` is a no-op.
    static func installMatchedSkills(
        intoFolder folder: URL,
        userText: String,
        skillsRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: skillsRoot.path) else { return }

        let normalizedUserText = userText.lowercased()
        guard !normalizedUserText.isEmpty else { return }

        let skillFiles = discoverSkillMarkdownFiles(under: skillsRoot, fileManager: fileManager)
        for skillFileURL in skillFiles {
            let folderName = skillFileURL.deletingLastPathComponent().lastPathComponent
            let frontMatterName = skillName(from: skillFileURL)
            guard matches(userText: normalizedUserText, folderName: folderName, skillName: frontMatterName) else {
                continue
            }

            let destinationDirectory = folder
                .appendingPathComponent("skills", isDirectory: true)
                .appendingPathComponent(frontMatterName, isDirectory: true)
            let destinationFile = destinationDirectory.appendingPathComponent(
                SkillDirectoryScanner.claudeCodeSkillFileName
            )

            try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationFile.path) {
                try fileManager.removeItem(at: destinationFile)
            }
            try fileManager.copyItem(at: skillFileURL, to: destinationFile)
        }
    }

    /// Every `SKILL.md` that lives directly inside a skill directory under
    /// `root` (not loose files at `root` itself).
    static func discoverSkillMarkdownFiles(
        under root: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let skillFileName = SkillDirectoryScanner.claudeCodeSkillFileName
        var discovered: [URL] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == skillFileName else { continue }
            let parentDirectory = fileURL.deletingLastPathComponent().standardizedFileURL
            let standardizedRoot = root.standardizedFileURL
            guard parentDirectory != standardizedRoot else { continue }
            discovered.append(fileURL)
        }
        return discovered.sorted { $0.path < $1.path }
    }

    static func matches(userText: String, folderName: String, skillName: String) -> Bool {
        let haystack = userText.lowercased()
        return haystack.contains(folderName.lowercased())
            || haystack.contains(skillName.lowercased())
    }

    static func skillName(from skillFileURL: URL) -> String {
        if let markdown = try? String(contentsOf: skillFileURL, encoding: .utf8),
           let parsed = SkillMarkdownParser.parse(markdown),
           !parsed.name.isEmpty {
            return parsed.name
        }
        return skillFileURL.deletingLastPathComponent().lastPathComponent
    }
}
