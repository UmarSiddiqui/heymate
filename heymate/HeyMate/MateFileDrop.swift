//
//  MateFileDrop.swift
//  HeyMate
//
//  Files dropped on an agent become its work: copies land in the agent's
//  inbox/ folder and the chat box names them, ready for the person to say
//  what to do. Originals are never moved, and nothing is sent or started.
//

import Foundation
import UniformTypeIdentifiers

nonisolated enum MateFileDrop {
    static let inboxFolderName = "inbox"
    static let maximumItems = 20

    /// Pictures can ride along in the message itself; everything else is
    /// handed over as a file.
    static func split(_ urls: [URL]) -> (images: [URL], files: [URL]) {
        var images: [URL] = []
        var files: [URL] = []
        for url in urls where url.isFileURL {
            let type = UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .image) == true { images.append(url) } else { files.append(url) }
        }
        return (images, files)
    }

    /// A free name in `folder`: "report.pdf", then "report 2.pdf", and so on.
    static func uniqueURL(for name: String, in folder: URL, fileManager: FileManager = .default) -> URL {
        let first = folder.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: first.path) else { return first }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var number = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            let candidate = folder.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            number += 1
        }
    }

    /// Copies up to `maximumItems` files or folders into `mateFolder/inbox`
    /// and returns the names they were saved under. Items that cannot be
    /// read are skipped.
    static func copy(_ urls: [URL], into mateFolder: URL, fileManager: FileManager = .default) -> [String] {
        let inbox = mateFolder.appendingPathComponent(inboxFolderName, isDirectory: true)
        guard (try? fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)) != nil else {
            return []
        }
        var names: [String] = []
        for url in urls.filter(\.isFileURL).prefix(maximumItems) {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
            let destination = uniqueURL(for: url.lastPathComponent, in: inbox, fileManager: fileManager)
            guard (try? fileManager.copyItem(at: url, to: destination)) != nil else { continue }
            names.append(destination.lastPathComponent)
        }
        return names
    }

    /// The chat box text after a drop: what was already typed, then a line
    /// naming the files, left open for the instruction.
    static func draft(names: [String], existing: String) -> String {
        guard !names.isEmpty else { return existing }
        let line = "Files for you in \(inboxFolderName)/: \(names.joined(separator: ", "))\n"
        let typed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? line : "\(typed)\n\(line)"
    }
}
