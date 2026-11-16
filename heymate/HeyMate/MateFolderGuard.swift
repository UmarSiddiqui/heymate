//
//  MateFolderGuard.swift
//  HeyMate
//
//  Every file operation in a mate's Files view goes through here. A path is
//  usable only when, after `..` and symlinks are resolved, it still lies
//  inside the mate's folder. Callers then act on the returned URL, never on
//  the path they were given.
//

import CryptoKit
import Darwin
import Foundation

nonisolated enum MateFolderGuard {
    /// The canonical form of `url`: `..` collapsed, every existing component
    /// resolved through `realpath`, and any components that do not exist yet
    /// appended unchanged. Nil for a dangling symlink, which would otherwise
    /// let a write land wherever the link points.
    static func resolve(_ url: URL) -> URL? {
        var base = url.standardizedFileURL.path
        var tail: [String] = []
        var info = stat()
        while lstat(base, &info) != 0 {
            guard base != "/", !base.isEmpty else { return nil }
            tail.insert((base as NSString).lastPathComponent, at: 0)
            base = (base as NSString).deletingLastPathComponent
        }
        guard let real = realpath(base, nil) else { return nil }
        defer { free(real) }
        var result = URL(fileURLWithPath: String(cString: real))
        for component in tail where component != "." {
            guard component != ".." else { return nil }
            result.appendPathComponent(component)
        }
        return result
    }

    /// The resolved URL when it lies inside the resolved `folder` (or is the
    /// folder itself), otherwise nil.
    static func contained(_ url: URL, in folder: URL) -> URL? {
        guard let root = resolve(folder), let target = resolve(url) else { return nil }
        let rootPath = root.path
        let targetPath = target.path
        if targetPath == rootPath { return target }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return targetPath.hasPrefix(prefix) ? target : nil
    }

    /// A path relative to the mate's folder ("notes/plan.md"), checked.
    static func url(forRelative relativePath: String, in folder: URL) -> URL? {
        guard !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~") else { return nil }
        let candidate = relativePath.isEmpty ? folder : folder.appendingPathComponent(relativePath)
        return contained(candidate, in: folder)
    }

    /// "notes/plan.md" for a URL inside the folder; "" for the folder itself.
    static func relativePath(of url: URL, in folder: URL) -> String? {
        guard let root = resolve(folder), let target = contained(url, in: folder) else { return nil }
        if target.path == root.path { return "" }
        return String(target.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// A single new file or folder name typed by the person: no separators,
    /// no leading dot (hidden files are not shown), not "." or "..".
    static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == name, trimmed.count <= 255 else { return false }
        guard !trimmed.contains("/"), !trimmed.contains(":"), !trimmed.hasPrefix(".") else { return false }
        return !trimmed.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Stable per-mate key for stored file records. The agent runtime computes
    /// the same value (sha256 of the realpath, first 16 hex characters) so it
    /// can record versions and origins without knowing mate IDs.
    static func storeKey(for folder: URL) -> String {
        let path = resolve(folder)?.path ?? folder.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
