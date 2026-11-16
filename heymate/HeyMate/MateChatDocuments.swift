//
//  MateChatDocuments.swift
//  HeyMate
//
//  Documents attached to a chat message. Images still ride in the message
//  itself (ChatImageAttachment). PDFs, office documents, text, code and CSV
//  are copied into the mate's inbox/ and named to the model by path, so its
//  read tool opens them; originals are never moved. PDFs and word-processor
//  files also get a plain-text copy in inbox/.text/, because a read tool
//  cannot see inside them. The message shows the files as chips; the path
//  list is kept at the end of the message text for the model.
//

import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

nonisolated struct MateChatDocument: Identifiable, Equatable, Sendable {
    let id = UUID()
    /// Saved name in inbox/, after de-duplication.
    let name: String
    let path: String
    let textCopyPath: String?
}

nonisolated enum MateChatDocuments {
    static let maximumBytes: Int64 = 25 * 1024 * 1024
    static let maximumCount = 6
    static let textFolderName = ".text"
    static let textCopyCharacterLimit = 400_000
    static let marker = "Attached files (copied to your folder; open them with read):"

    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "rtf", "rtfd", "odt", "pages", "xls", "xlsx", "numbers", "ods",
        "ppt", "pptx", "key", "odp", "csv", "tsv", "txt", "md", "markdown", "json", "yaml", "yml",
        "xml", "html", "htm", "log", "ini", "toml", "sql", "swift", "py", "js", "mjs", "ts", "tsx",
        "jsx", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp", "m", "cs", "php", "sh", "css"
    ]
    private static let textCopyExtensions: Set<String> = ["pdf", "doc", "docx", "rtf", "rtfd", "odt"]

    static func isDocument(_ url: URL) -> Bool {
        guard url.isFileURL, !url.hasDirectoryPath else { return false }
        let ext = url.pathExtension.lowercased()
        if documentExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        if type.conforms(to: .image) || type.conforms(to: .directory) { return false }
        return type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .sourceCode)
    }

    /// Pictures for the message, documents for the inbox, and everything else
    /// (folders, archives, apps) for the older drop-into-inbox path.
    static func classify(_ urls: [URL]) -> (images: [URL], documents: [URL], other: [URL]) {
        let split = MateFileDrop.split(urls)
        var documents: [URL] = []
        var other: [URL] = []
        for url in split.files {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if exists, !isDirectory.boolValue, isDocument(url) { documents.append(url) } else { other.append(url) }
        }
        return (split.images, documents, other)
    }

    /// A message for the person, or nil when the file can be attached.
    static func problem(with url: URL, size: Int64?) -> String? {
        guard let size else { return "\(url.lastPathComponent) could not be read." }
        guard size <= maximumBytes else {
            let shown = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            let limit = ByteCountFormatter.string(fromByteCount: maximumBytes, countStyle: .file)
            return "\(url.lastPathComponent) is \(shown). Files up to \(limit) can be attached."
        }
        return nil
    }

    /// Copies documents into `mateFolder/inbox`, records them as given by the
    /// person, and writes text copies for PDFs and word-processor files.
    static func attach(_ urls: [URL], into mateFolder: URL, store: MateFileStore? = nil,
                       fileManager: FileManager = .default) -> (documents: [MateChatDocument], problems: [String]) {
        let inbox = mateFolder.appendingPathComponent(MateFileDrop.inboxFolderName, isDirectory: true)
        guard (try? fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)) != nil,
              MateFolderGuard.contained(inbox, in: mateFolder) != nil else {
            return ([], ["This mate's inbox folder could not be created."])
        }
        var documents: [MateChatDocument] = []
        var problems: [String] = []
        if urls.count > maximumCount { problems.append("Up to \(maximumCount) files per message.") }
        for url in urls.prefix(maximumCount) {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init)
            if let problem = problem(with: url, size: size) { problems.append(problem); continue }
            let destination = MateFileDrop.uniqueURL(for: url.lastPathComponent, in: inbox, fileManager: fileManager)
            do { try fileManager.copyItem(at: url, to: destination) } catch {
                problems.append("\(url.lastPathComponent) could not be copied."); continue
            }
            let textCopy = writeTextCopy(of: destination, in: inbox, fileManager: fileManager)
            documents.append(MateChatDocument(name: destination.lastPathComponent, path: destination.path, textCopyPath: textCopy?.path))
        }
        (store ?? MateFileStore(folder: mateFolder)).record(.person, urls: documents.map { URL(fileURLWithPath: $0.path) })
        return (documents, problems)
    }

    static func writeTextCopy(of url: URL, in inbox: URL, fileManager: FileManager = .default) -> URL? {
        guard textCopyExtensions.contains(url.pathExtension.lowercased()),
              var text = extractText(from: url)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        if text.count > textCopyCharacterLimit {
            text = String(text.prefix(textCopyCharacterLimit)) + "\n\n[Text copy truncated at \(textCopyCharacterLimit) characters.]"
        }
        let folder = inbox.appendingPathComponent(textFolderName, isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent + ".txt")
        return (try? text.write(to: copy, atomically: true, encoding: .utf8)) == nil ? nil : copy
    }

    static func extractText(from url: URL) -> String? {
        if url.pathExtension.lowercased() == "pdf" {
            return PDFDocument(url: url)?.string
        }
        return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
    }

    // MARK: Message text

    /// The block appended to the message for the model.
    static func modelReference(_ documents: [MateChatDocument]) -> String {
        guard !documents.isEmpty else { return "" }
        let lines = documents.map { document in
            "- " + document.path + (document.textCopyPath.map { " (plain-text copy: \($0))" } ?? "")
        }
        return marker + "\n" + lines.joined(separator: "\n")
    }

    static func messageText(_ typed: String, documents: [MateChatDocument]) -> String {
        let reference = modelReference(documents)
        guard !reference.isEmpty else { return typed }
        let body = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? "Here are some files.\n\n" + reference : body + "\n\n" + reference
    }

    /// What the chat shows: the typed text, and the attached file names as chips.
    static func display(_ text: String) -> (body: String, names: [String]) {
        guard let range = text.range(of: "\n\n" + marker + "\n", options: .backwards) else { return (text, []) }
        let tail = text[range.upperBound...]
        var names: [String] = []
        for line in tail.split(separator: "\n") {
            guard line.hasPrefix("- /") else { return (text, []) }
            var path = String(line.dropFirst(2))
            if let note = path.range(of: " (plain-text copy: ") { path = String(path[..<note.lowerBound]) }
            names.append((path as NSString).lastPathComponent)
        }
        guard !names.isEmpty else { return (text, []) }
        return (String(text[..<range.lowerBound]), names)
    }
}
