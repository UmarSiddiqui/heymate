//
//  MateFileActions.swift
//  HeyMate
//
//  Changes the Files view can make in a mate's folder. Every path is checked
//  by MateFolderGuard first; removal always goes to the Trash; files brought
//  in are copied, never moved. Origins and version history follow renames.
//

import Foundation

nonisolated enum MateFileActionError: LocalizedError {
    case outsideFolder
    case invalidName
    case exists(String)

    var errorDescription: String? {
        switch self {
        case .outsideFolder: return "That is outside this mate's folder."
        case .invalidName: return "Use a name without slashes or a leading dot."
        case .exists(let name): return "Something named \(name) is already there."
        }
    }
}

nonisolated enum MateFileActions {
    /// The directory a new item goes into: the folder itself for "", the
    /// directory for a directory row, its parent for a file row.
    static func directory(for node: MateFileNode?) -> String {
        guard let node else { return "" }
        return node.isExpandable ? node.relativePath : node.parentPath
    }

    @discardableResult
    static func rename(_ relativePath: String, to newName: String, in folder: URL, store: MateFileStore,
                       fileManager: FileManager = .default) throws -> String {
        guard MateFolderGuard.isValidName(newName) else { throw MateFileActionError.invalidName }
        guard !relativePath.isEmpty, let source = MateFolderGuard.url(forRelative: relativePath, in: folder) else {
            throw MateFileActionError.outsideFolder
        }
        let parent = (relativePath as NSString).deletingLastPathComponent
        let destinationPath = parent.isEmpty ? newName : parent + "/" + newName
        guard let destination = MateFolderGuard.url(forRelative: destinationPath, in: folder) else {
            throw MateFileActionError.outsideFolder
        }
        guard destination.path != source.path else { return relativePath }
        // A case-only rename is the same file on a case-insensitive volume.
        if fileManager.fileExists(atPath: destination.path),
           destination.path.lowercased() != source.path.lowercased() {
            throw MateFileActionError.exists(newName)
        }
        try fileManager.moveItem(at: source, to: destination)
        store.recordMove(from: relativePath, to: destinationPath)
        return destinationPath
    }

    @discardableResult
    static func newFolder(named name: String, inDirectory directory: String, in folder: URL,
                          fileManager: FileManager = .default) throws -> String {
        guard MateFolderGuard.isValidName(name) else { throw MateFileActionError.invalidName }
        let path = directory.isEmpty ? name : directory + "/" + name
        guard let url = MateFolderGuard.url(forRelative: path, in: folder) else { throw MateFileActionError.outsideFolder }
        guard !fileManager.fileExists(atPath: url.path) else { throw MateFileActionError.exists(name) }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return path
    }

    /// Moves to the Trash only; there is no permanent delete here.
    static func moveToTrash(_ relativePath: String, in folder: URL, store: MateFileStore,
                            fileManager: FileManager = .default) throws {
        guard !relativePath.isEmpty, let url = MateFolderGuard.url(forRelative: relativePath, in: folder) else {
            throw MateFileActionError.outsideFolder
        }
        try fileManager.trashItem(at: url, resultingItemURL: nil)
        store.recordRemoval(relativePath)
    }

    /// Copies files and folders in from elsewhere, recorded as given by the
    /// person. Returns the new relative paths.
    @discardableResult
    static func copyIn(_ urls: [URL], toDirectory directory: String, in folder: URL, store: MateFileStore,
                       fileManager: FileManager = .default) throws -> [String] {
        guard let target = MateFolderGuard.url(forRelative: directory, in: folder) else { throw MateFileActionError.outsideFolder }
        var copied: [String] = []
        for url in urls where url.isFileURL {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
            // Dragging a file that is already here onto its own folder is a no-op.
            if MateFolderGuard.contained(url, in: folder) != nil,
               url.deletingLastPathComponent().resolvingSymlinksInPath().path == target.path { continue }
            let destination = MateFileDrop.uniqueURL(for: url.lastPathComponent, in: target, fileManager: fileManager)
            guard (try? fileManager.copyItem(at: url, to: destination)) != nil else { continue }
            let name = destination.lastPathComponent
            copied.append(directory.isEmpty ? name : directory + "/" + name)
        }
        store.record(.person, relativePaths: copied)
        return copied
    }
}
