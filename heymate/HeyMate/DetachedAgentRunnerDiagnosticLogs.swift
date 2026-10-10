//
//  DetachedAgentRunnerDiagnosticLogs.swift
//  HeyMate
//
//  Each detached runner's stderr goes to
//  ~/Library/Logs/HeyMate/agent-runner-<attempt>.log so a runner that dies
//  before it can journal still leaves a reason behind. Almost every run exits
//  cleanly and leaves an empty file, so the empty ones are removed as soon as
//  the runner is reaped, and launch sweeps out logs whose run is gone or that
//  are older than a week. heymate.log and heymate.1.log share the folder and
//  are never touched. The unit-test host uses its scratch folder instead.
//

import Foundation

nonisolated enum DetachedAgentRunnerDiagnosticLogs {

    static let fileNamePrefix = "agent-runner-"
    static let fileNameExtension = "log"
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    /// Same folder as `HeyMateLog`, so tests never reach the real Logs folder.
    static var directoryURL: URL { HeyMateLog.directoryURL }

    static func fileURL(attemptID: UUID, directoryURL: URL = directoryURL) -> URL {
        directoryURL.appendingPathComponent(
            "\(fileNamePrefix)\(attemptID.uuidString.lowercased()).\(fileNameExtension)",
            isDirectory: false
        )
    }

    /// The attempt a file name belongs to, or nil for anything that is not an
    /// agent-runner log (heymate.log, heymate.1.log, stray files).
    static func attemptID(fromFileName fileName: String) -> UUID? {
        let suffix = ".\(fileNameExtension)"
        guard fileName.hasPrefix(fileNamePrefix), fileName.hasSuffix(suffix) else { return nil }
        let identifier = fileName.dropFirst(fileNamePrefix.count).dropLast(suffix.count)
        return UUID(uuidString: String(identifier))
    }

    /// The pruning rule: a log goes once its attempt no longer exists on disk
    /// or it has not been written for `maximumAge`.
    static func shouldPrune(
        attemptID: UUID,
        modifiedAt: Date,
        existingAttemptIDs: Set<UUID>,
        now: Date
    ) -> Bool {
        if !existingAttemptIDs.contains(attemptID) { return true }
        return now.timeIntervalSince(modifiedAt) > maximumAge
    }

    /// Call once the runner has exited. A clean run writes nothing to stderr.
    static func removeIfEmpty(
        attemptID: UUID,
        directoryURL: URL = directoryURL,
        fileManager: FileManager = .default
    ) {
        let url = fileURL(attemptID: attemptID, directoryURL: directoryURL)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value == 0 else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Attempt IDs that still have a folder under the runtime root
    /// (`<root>/<run>/<attempt>/`).
    static func existingAttemptIDs(
        runtimeRootURL: URL,
        fileManager: FileManager = .default
    ) -> Set<UUID> {
        var attemptIDs: Set<UUID> = []
        let runNames = (try? fileManager.contentsOfDirectory(atPath: runtimeRootURL.path)) ?? []
        for runName in runNames where UUID(uuidString: runName) != nil {
            let runURL = runtimeRootURL.appendingPathComponent(runName, isDirectory: true)
            let attemptNames = (try? fileManager.contentsOfDirectory(atPath: runURL.path)) ?? []
            for attemptName in attemptNames {
                if let attemptID = UUID(uuidString: attemptName) {
                    attemptIDs.insert(attemptID)
                }
            }
        }
        return attemptIDs
    }

    /// Removes stale agent-runner logs. Returns how many were removed.
    @discardableResult
    static func pruneStaleLogs(
        directoryURL: URL = directoryURL,
        runtimeRootURL: URL = DetachedAgentRuntimePaths.defaultRootURL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Int {
        guard let fileNames = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else {
            return 0
        }
        let existing = existingAttemptIDs(runtimeRootURL: runtimeRootURL, fileManager: fileManager)
        var removedCount = 0
        for fileName in fileNames {
            guard let attemptID = attemptID(fromFileName: fileName) else { continue }
            let url = directoryURL.appendingPathComponent(fileName, isDirectory: false)
            let modifiedAt = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
                ?? .distantPast
            guard shouldPrune(
                attemptID: attemptID,
                modifiedAt: modifiedAt,
                existingAttemptIDs: existing,
                now: now
            ) else { continue }
            if (try? fileManager.removeItem(at: url)) != nil {
                removedCount += 1
            }
        }
        return removedCount
    }
}
