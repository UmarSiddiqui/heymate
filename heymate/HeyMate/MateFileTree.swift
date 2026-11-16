//
//  MateFileTree.swift
//  HeyMate
//
//  The Files view's folder tree. A directory is listed only when it is
//  expanded, hidden files are skipped, symlinks that leave the mate's folder
//  are dropped and symlinked folders are never descended. Large directories
//  show a page at a time. No UI here; the view runs these off the main thread.
//

import Foundation

nonisolated struct MateFileNode: Identifiable, Equatable, Hashable, Sendable {
    var id: String { relativePath }
    /// Relative to the mate's folder, "/"-separated.
    let relativePath: String
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64?
    let modified: Date?

    /// Symlinked folders stay closed so a link cannot loop the tree.
    var isExpandable: Bool { isDirectory && !isSymlink }

    var parentPath: String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }
}

nonisolated enum MateFileSort: String, CaseIterable, Identifiable, Sendable {
    case name
    case modified

    var id: String { rawValue }
    var title: String { self == .name ? "Name" : "Date modified" }
}

nonisolated struct MateFolderListing: Equatable, Sendable {
    /// Every readable entry, already sorted.
    let entries: [MateFileNode]
    /// How many of `entries` are shown; "Show more" raises it.
    var shownCount: Int

    var shown: ArraySlice<MateFileNode> { entries.prefix(shownCount) }
    var remaining: Int { max(0, entries.count - shownCount) }
}

nonisolated enum MateFileRow: Identifiable, Equatable, Sendable {
    case node(MateFileNode, depth: Int)
    case more(directory: String, remaining: Int, depth: Int)

    var id: String {
        switch self {
        case .node(let node, _): return "n:" + node.relativePath
        case .more(let directory, _, _): return "m:" + directory
        }
    }
}

nonisolated enum MateFileTree {
    static let pageSize = 200
    /// Hard ceiling on entries read from one directory, so a folder with a
    /// million files cannot stall the view.
    static let maximumEntriesPerDirectory = 20_000

    /// One directory, sorted, at most `maximumEntriesPerDirectory` entries.
    static func list(
        _ relativeDirectory: String,
        in folder: URL,
        sort: MateFileSort,
        pageSize: Int = pageSize,
        fileManager: FileManager = .default
    ) -> MateFolderListing {
        guard let directory = MateFolderGuard.url(forRelative: relativeDirectory, in: folder),
              let root = MateFolderGuard.resolve(folder) else {
            return MateFolderListing(entries: [], shownCount: 0)
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return MateFolderListing(entries: [], shownCount: 0) }
        var nodes: [MateFileNode] = []
        for url in urls.prefix(maximumEntriesPerDirectory) {
            guard let node = node(for: url, root: root, relativeParent: relativeDirectory) else { continue }
            nodes.append(node)
        }
        let sorted = Self.sorted(nodes, by: sort)
        return MateFolderListing(entries: sorted, shownCount: min(pageSize, sorted.count))
    }

    /// Nil for anything outside the folder once symlinks are resolved.
    static func node(for url: URL, root: URL, relativeParent: String) -> MateFileNode? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        let isSymlink = values?.isSymbolicLink ?? false
        var isDirectory = values?.isDirectory ?? false
        var size = values?.fileSize.map(Int64.init)
        var modified = values?.contentModificationDate
        if isSymlink {
            guard MateFolderGuard.contained(url, in: root) != nil else { return nil }
            let target = url.resolvingSymlinksInPath()
            let targetValues = try? target.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            isDirectory = targetValues?.isDirectory ?? false
            size = targetValues?.fileSize.map(Int64.init)
            modified = targetValues?.contentModificationDate ?? modified
        }
        let name = url.lastPathComponent
        return MateFileNode(
            relativePath: relativeParent.isEmpty ? name : relativeParent + "/" + name,
            name: name,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: isDirectory ? nil : size,
            modified: modified
        )
    }

    /// Folders first by name; by date, newest first with folders mixed in.
    static func sorted(_ nodes: [MateFileNode], by sort: MateFileSort) -> [MateFileNode] {
        switch sort {
        case .name:
            return nodes.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        case .modified:
            return nodes.sorted { lhs, rhs in
                let left = lhs.modified ?? .distantPast
                let right = rhs.modified ?? .distantPast
                if left != right { return left > right }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    /// The tree as visible rows: listed directories that are expanded are
    /// opened in place, each followed by a "Show more" row when capped.
    static func rows(listings: [String: MateFolderListing], expanded: Set<String>, root: String = "") -> [MateFileRow] {
        var rows: [MateFileRow] = []
        func walk(_ directory: String, depth: Int) {
            guard let listing = listings[directory] else { return }
            for node in listing.shown {
                rows.append(.node(node, depth: depth))
                if node.isExpandable, expanded.contains(node.relativePath) {
                    walk(node.relativePath, depth: depth + 1)
                }
            }
            if listing.remaining > 0 {
                rows.append(.more(directory: directory, remaining: listing.remaining, depth: depth))
            }
        }
        walk(root, depth: 0)
        return rows
    }

    /// Case- and diacritic-insensitive match on the file name.
    static func matches(name: String, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Name search across the whole folder. Stops after `limit` matches or
    /// `maximumVisited` entries, and whenever `isCancelled` says so. Never
    /// descends hidden folders, packages or symlinked folders.
    static func search(
        _ query: String,
        in folder: URL,
        limit: Int = 300,
        maximumVisited: Int = 50_000,
        fileManager: FileManager = .default,
        isCancelled: () -> Bool = { false }
    ) -> (matches: [MateFileNode], complete: Bool) {
        guard let root = MateFolderGuard.resolve(folder),
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ([], true) }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return ([], true) }
        var matches: [MateFileNode] = []
        var visited = 0
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        while let url = enumerator.nextObject() as? URL {
            if isCancelled() { return (matches, false) }
            visited += 1
            if visited > maximumVisited { return (matches, false) }
            guard Self.matches(name: url.lastPathComponent, query: query) else { continue }
            // The enumerator reports paths under the resolved root; anything
            // else is checked the slow way.
            let path = url.path
            let relative: String
            if path.hasPrefix(rootPrefix) {
                relative = String(path.dropFirst(rootPrefix.count))
            } else if let checked = MateFolderGuard.relativePath(of: url, in: root), !checked.isEmpty {
                relative = checked
            } else { continue }
            let parent = (relative as NSString).deletingLastPathComponent
            guard let node = node(for: url, root: root, relativeParent: parent) else { continue }
            matches.append(node)
            if matches.count >= limit { return (matches, false) }
        }
        return (matches, true)
    }

    static func formattedSize(_ bytes: Int64?) -> String {
        guard let bytes else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
