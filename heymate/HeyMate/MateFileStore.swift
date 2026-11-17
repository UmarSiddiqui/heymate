//
//  MateFileStore.swift
//  HeyMate
//
//  What HeyMate remembers about the files in a mate's folder: where each one
//  came from, and earlier versions of files a mate turn overwrote or edited.
//
//  Origins are recorded where files are written, never guessed from paths:
//  the agent runtime appends "mate" when a mate turn's write tool creates a
//  file (agent-runtime/src/file-history.mjs), and HeyMate appends "person"
//  when files are dropped, attached or copied in. Versions are kept by the
//  runtime just before its write and edit tools change an existing file,
//  and by HeyMate before a restore. Everything lives under
//  HeyMateDataDirectory/mate-files/<key>, keyed per mate folder.
//
//  On disk (shared with the runtime, so keep both sides in step):
//    origins.jsonl            {"path","origin"} | {"path","moved_to"} | {"path","removed":true}, plus "at"
//    versions/index.json      {"files": {"<path>": [{"id","at","size","source"}]}}, oldest first
//    versions/blobs/<id>      the earlier bytes
//

import Foundation

nonisolated enum MateFileOrigin: String, Codable, Sendable {
    case mate
    case person
    case other

    var badge: String {
        switch self {
        case .mate: return "Made by mate"
        case .person: return "Given by you"
        case .other: return "Other"
        }
    }
}

nonisolated struct MateFileOriginEvent: Codable, Equatable, Sendable {
    var path: String
    var origin: MateFileOrigin?
    var movedTo: String?
    var removed: Bool?
    var at: String?

    enum CodingKeys: String, CodingKey {
        case path, origin, removed, at
        case movedTo = "moved_to"
    }
}

nonisolated enum MateFileOrigins {
    static func parse(_ data: Data) -> [MateFileOriginEvent] {
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? decoder.decode(MateFileOriginEvent.self, from: Data(line))
        }
    }

    /// Later events win. A move or removal carries everything under a folder.
    static func fold(_ events: [MateFileOriginEvent]) -> [String: MateFileOrigin] {
        var map: [String: MateFileOrigin] = [:]
        for event in events {
            let path = event.path
            if let origin = event.origin {
                map[path] = origin
            } else if let destination = event.movedTo {
                for (key, value) in map where key == path || key.hasPrefix(path + "/") {
                    map[key] = nil
                    map[destination + key.dropFirst(path.count)] = value
                }
            } else if event.removed == true {
                for key in map.keys where key == path || key.hasPrefix(path + "/") { map[key] = nil }
            }
        }
        return map
    }

    /// A file inside a dropped folder came from the person too.
    static func origin(of relativePath: String, in map: [String: MateFileOrigin]) -> MateFileOrigin {
        var candidate = relativePath
        while !candidate.isEmpty {
            if let origin = map[candidate] { return origin }
            guard let slash = candidate.lastIndex(of: "/") else { break }
            candidate = String(candidate[..<slash])
        }
        return .other
    }
}

nonisolated struct MateFileVersion: Codable, Equatable, Identifiable, Sendable {
    let id: String
    /// ISO 8601 with milliseconds, UTC, so it sorts as text.
    let at: String
    let size: Int64
    /// "mate" before a mate turn's write or edit, "restore" before a restore.
    let source: String

    var date: Date? { MateFileVersionPolicy.parse(at) }
}

nonisolated struct MateFileVersionIndex: Codable, Equatable, Sendable {
    var files: [String: [MateFileVersion]] = [:]
}

nonisolated enum MateFileVersionPolicy {
    static let maximumPerFile = 10
    static let maximumFileBytes: Int64 = 5 * 1024 * 1024
    static let maximumTotalBytes: Int64 = 200 * 1024 * 1024

    /// Keeps the newest `perFile` versions of each file, then drops the oldest
    /// versions across the mate until the total fits. Returns the ids removed.
    static func prune(
        _ index: MateFileVersionIndex,
        perFile: Int = maximumPerFile,
        totalBytes: Int64 = maximumTotalBytes
    ) -> (index: MateFileVersionIndex, removed: [String]) {
        var result = MateFileVersionIndex()
        var removed: [String] = []
        for (path, versions) in index.files {
            let kept = Array(versions.suffix(perFile))
            removed += versions.dropLast(kept.count).map(\.id)
            if !kept.isEmpty { result.files[path] = kept }
        }
        var total: Int64 = 0
        var everything: [(path: String, version: MateFileVersion)] = []
        for (path, versions) in result.files {
            for version in versions {
                total += version.size
                everything.append((path, version))
            }
        }
        if total > totalBytes {
            let oldestFirst = everything.sorted { lhs, rhs in
                lhs.version.at == rhs.version.at ? lhs.version.id < rhs.version.id : lhs.version.at < rhs.version.at
            }
            for (path, version) in oldestFirst where total > totalBytes {
                result.files[path]?.removeAll { $0.id == version.id }
                if result.files[path]?.isEmpty == true { result.files[path] = nil }
                removed.append(version.id)
                total -= version.size
            }
        }
        return (result, removed)
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

nonisolated enum MateFileStoreError: LocalizedError {
    case outsideFolder
    case missingVersion
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .outsideFolder: return "That path is outside this mate's folder."
        case .missingVersion: return "That earlier version is no longer saved."
        case .tooLarge: return "That file is too large to keep earlier versions of."
        }
    }
}

nonisolated struct MateFileStore: Sendable {
    static let directoryName = "mate-files"

    let folder: URL
    let root: URL

    init(folder: URL, dataRoot: URL = HeyMateDataDirectory.url) {
        self.folder = folder
        root = dataRoot.appendingPathComponent(Self.directoryName, isDirectory: true)
            .appendingPathComponent(MateFolderGuard.storeKey(for: folder), isDirectory: true)
    }

    var originsURL: URL { root.appendingPathComponent("origins.jsonl") }
    var versionsURL: URL { root.appendingPathComponent("versions", isDirectory: true) }
    var indexURL: URL { versionsURL.appendingPathComponent("index.json") }
    func blobURL(_ id: String) -> URL {
        versionsURL.appendingPathComponent("blobs", isDirectory: true).appendingPathComponent(id)
    }

    // MARK: Origins

    func origins() -> [String: MateFileOrigin] {
        guard let data = try? Data(contentsOf: originsURL) else { return [:] }
        return MateFileOrigins.fold(MateFileOrigins.parse(data))
    }

    func record(_ origin: MateFileOrigin, relativePaths: [String]) {
        append(relativePaths.map { MateFileOriginEvent(path: $0, origin: origin, at: MateFileVersionPolicy.timestamp()) })
    }

    /// Records files copied to absolute URLs, ignoring any outside the folder.
    func record(_ origin: MateFileOrigin, urls: [URL]) {
        record(origin, relativePaths: urls.compactMap { MateFolderGuard.relativePath(of: $0, in: folder) }.filter { !$0.isEmpty })
    }

    func recordMove(from source: String, to destination: String) {
        append([MateFileOriginEvent(path: source, movedTo: destination, at: MateFileVersionPolicy.timestamp())])
        moveVersions(from: source, to: destination)
    }

    func recordRemoval(_ relativePath: String) {
        append([MateFileOriginEvent(path: relativePath, removed: true, at: MateFileVersionPolicy.timestamp())])
    }

    /// One line per event, appended with O_APPEND so the runtime's appends
    /// interleave whole lines rather than overwrite.
    private func append(_ events: [MateFileOriginEvent]) {
        guard !events.isEmpty else { return }
        let encoder = JSONEncoder()
        var data = Data()
        for event in events {
            guard let line = try? encoder.encode(event) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = open(originsURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        data.withUnsafeBytes { buffer in
            _ = write(descriptor, buffer.baseAddress, buffer.count)
        }
    }

    // MARK: Versions

    func versionIndex() -> MateFileVersionIndex {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(MateFileVersionIndex.self, from: data) else { return MateFileVersionIndex() }
        return index
    }

    /// Newest first.
    func versions(of relativePath: String) -> [MateFileVersion] {
        (versionIndex().files[relativePath] ?? []).reversed()
    }

    func data(of version: MateFileVersion) -> Data? {
        try? Data(contentsOf: blobURL(version.id))
    }

    private func save(_ index: MateFileVersionIndex) throws {
        let pruned = MateFileVersionPolicy.prune(index)
        try FileManager.default.createDirectory(at: versionsURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(pruned.index)
        try data.write(to: indexURL, options: .atomic)
        for id in pruned.removed { try? FileManager.default.removeItem(at: blobURL(id)) }
    }

    /// Keeps the current bytes of an existing file. Nil when there is nothing
    /// to keep; throws `tooLarge` past the per-file cap.
    @discardableResult
    func snapshot(_ relativePath: String, source: String) throws -> MateFileVersion? {
        guard let url = MateFolderGuard.url(forRelative: relativePath, in: folder) else { throw MateFileStoreError.outsideFolder }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        guard size <= MateFileVersionPolicy.maximumFileBytes else { throw MateFileStoreError.tooLarge }
        let version = MateFileVersion(id: UUID().uuidString.lowercased(), at: MateFileVersionPolicy.timestamp(), size: size, source: source)
        try FileManager.default.createDirectory(at: blobURL(version.id).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: blobURL(version.id))
        var index = versionIndex()
        index.files[relativePath, default: []].append(version)
        try save(index)
        return version
    }

    /// Puts an earlier version back. The bytes it replaces are kept first, so
    /// a restore can itself be undone.
    func restore(_ version: MateFileVersion, of relativePath: String) throws {
        guard let url = MateFolderGuard.url(forRelative: relativePath, in: folder) else { throw MateFileStoreError.outsideFolder }
        guard let data = data(of: version) else { throw MateFileStoreError.missingVersion }
        try snapshot(relativePath, source: "restore")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func moveVersions(from source: String, to destination: String) {
        var index = versionIndex()
        var changed = false
        for key in Array(index.files.keys) where key == source || key.hasPrefix(source + "/") {
            let moved = destination + key.dropFirst(source.count)
            index.files[moved, default: []].append(contentsOf: index.files[key] ?? [])
            index.files[key] = nil
            changed = true
        }
        if changed { try? save(index) }
    }
}
