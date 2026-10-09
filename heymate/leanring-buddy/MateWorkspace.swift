//
//  MateWorkspace.swift
//  leanring-buddy
//
//  A mate's folder lives under ~/Projects/heymate. Creating the folder is
//  explicit. Listing it never starts an agent.
//

import Foundation

nonisolated struct MateFileEntry: Equatable, Identifiable {
    let id: String
    let name: String
    let isDirectory: Bool
}

nonisolated enum MateWorkspace {
    static func projectsRoot(
        home: URL = HeyMateDataDirectory.homeURL
    ) -> URL {
        home.appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent("heymate", isDirectory: true)
    }

    static func slug(for name: String) -> String {
        let folded = name.lowercased()
        let cleaned = folded.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(cleaned).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "mate" : collapsed
    }

    static func proposedURL(for mate: Mate, projectsRoot: URL) -> URL {
        projectsRoot.appendingPathComponent(slug(for: mate.name), isDirectory: true)
    }

    static func ensureFolder(for mate: Mate, projectsRoot: URL) throws -> URL {
        let folder = proposedURL(for: mate, projectsRoot: projectsRoot)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func files(in folderPath: String) -> [MateFileEntry] {
        let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.map { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return MateFileEntry(id: url.path, name: url.lastPathComponent, isDirectory: isDirectory)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func moveToTrash(path: String) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    static func previewText(at filePath: String, limit: Int = 1_200) -> String? {
        let url = URL(fileURLWithPath: filePath)
        let allowed: Set<String> = ["md", "txt", "swift", "json", "csv"]
        guard allowed.contains(url.pathExtension.lowercased()) else { return nil }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    static func wantsFolder(_ text: String) -> Bool {
        let folded = text.lowercased()
        return folded.contains("folder") || folded.contains("file") || folded.contains("project")
    }
}
