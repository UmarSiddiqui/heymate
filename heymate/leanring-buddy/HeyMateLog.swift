//
//  HeyMateLog.swift
//  leanring-buddy
//
//  Lightweight development log. Every line goes to the unified log
//  (subsystem = bundle id, category = the calling file) and is appended to
//  ~/Library/Logs/HeyMate/heymate.log with a millisecond timestamp, so a
//  choppy reply or a slow turn can be read back after the fact:
//
//      tail -f ~/Library/Logs/HeyMate/heymate.log
//
//  The file rolls over to heymate.1.log at 1 MB, so it never holds more than
//  about 2 MB. Lines carry timings, counts, and states — never transcripts,
//  replies, or keys. The unit-test host writes to its scratch folder instead.
//

import Foundation
import os

nonisolated enum HeyMateLog {

    static let subsystem = Bundle.main.bundleIdentifier ?? "com.heymate.app"

    static let directoryURL: URL = HeyMateDataDirectory.isHostingTests
        ? HeyMateDataDirectory.applicationSupportURL.appendingPathComponent("Logs", isDirectory: true)
        : FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/HeyMate", isDirectory: true)

    static let fileURL = directoryURL.appendingPathComponent("heymate.log")
    private static let rolledFileURL = directoryURL.appendingPathComponent("heymate.1.log")
    private static let maximumFileBytes: UInt64 = 1_000_000

    /// Writes one line. `category` defaults to the calling file's name.
    static func log(_ message: String, category: String? = nil, fileID: String = #fileID) {
        let resolvedCategory = category ?? categoryName(fromFileID: fileID)
        logger(for: resolvedCategory).log("\(message, privacy: .public)")
        let line = "\(timestampFormatter.string(from: Date())) [\(resolvedCategory)] \(message)\n"
        writeQueue.async { append(line) }
    }

    /// Milliseconds elapsed since `start`, for timing lines.
    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    // MARK: - Private

    private static let writeQueue = DispatchQueue(label: "com.heymate.log", qos: .utility)
    nonisolated(unsafe) private static var fileHandle: FileHandle?
    nonisolated(unsafe) private static var loggers: [String: Logger] = [:]
    private static let loggersLock = NSLock()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static func logger(for category: String) -> Logger {
        loggersLock.lock()
        defer { loggersLock.unlock() }
        if let existing = loggers[category] { return existing }
        let created = Logger(subsystem: subsystem, category: category)
        loggers[category] = created
        return created
    }

    private static func categoryName(fromFileID fileID: String) -> String {
        let fileName = fileID.split(separator: "/").last.map(String.init) ?? fileID
        return fileName.hasSuffix(".swift") ? String(fileName.dropLast(6)) : fileName
    }

    /// Runs on `writeQueue` only.
    private static func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        if fileHandle == nil { openFile() }
        guard let handle = fileHandle else { return }
        handle.write(data)
        if handle.offsetInFile > maximumFileBytes {
            try? handle.close()
            fileHandle = nil
            try? FileManager.default.removeItem(at: rolledFileURL)
            try? FileManager.default.moveItem(at: fileURL, to: rolledFileURL)
        }
    }

    private static func openFile() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        fileHandle?.seekToEndOfFile()
    }
}
