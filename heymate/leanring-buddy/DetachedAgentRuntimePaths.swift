//
//  DetachedAgentRuntimePaths.swift
//  leanring-buddy
//

import Foundation

nonisolated enum DetachedAgentRuntimePaths {
    static var defaultRootURL: URL {
        HeyMateDataDirectory.applicationSupportURL
        .appendingPathComponent("heymate", isDirectory: true)
        .appendingPathComponent("detached-agent-runtime", isDirectory: true)
    }

    static func runDirectoryURL(rootDirectoryURL: URL, runID: UUID) -> URL {
        rootDirectoryURL.appendingPathComponent(runID.uuidString.lowercased(), isDirectory: true)
    }

    static func attemptDirectoryURL(
        rootDirectoryURL: URL,
        runID: UUID,
        attemptID: UUID
    ) -> URL {
        runDirectoryURL(rootDirectoryURL: rootDirectoryURL, runID: runID)
            .appendingPathComponent(attemptID.uuidString.lowercased(), isDirectory: true)
    }
}
