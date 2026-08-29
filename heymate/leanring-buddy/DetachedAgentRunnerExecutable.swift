//
//  DetachedAgentRunnerExecutable.swift
//  leanring-buddy
//
//  Resolves only HeyMate's signed, embedded command-line runner.
//

import Darwin
import Foundation

nonisolated enum DetachedAgentRunnerExecutable {
    static let executableName = "HeyMateAgentRunner"
    static let relativePathComponents = ["Contents", "Helpers", executableName]

    static func bundledURL(
        bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard bundleURL.isFileURL, bundleURL.path.hasPrefix("/") else { return nil }

        let resolvedBundleURL = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let helpersURL = resolvedBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .standardizedFileURL
        let candidateURL = helpersURL
            .appendingPathComponent(executableName, isDirectory: false)
            .standardizedFileURL

        guard candidateURL.deletingLastPathComponent() == helpersURL,
              fileManager.isExecutableFile(atPath: candidateURL.path) else {
            return nil
        }

        // Runner must be a real regular file inside signed bundle. Refusing a
        // symlink prevents path replacement from redirecting the privileged
        // bootstrap pipe into unrelated code.
        var fileStatus = stat()
        guard lstat(candidateURL.path, &fileStatus) == 0,
              fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            return nil
        }
        return candidateURL
    }

    /// Resolves app containing currently running helper only when executable
    /// occupies exact signed-bundle location used by build's embed phase.
    static func containingAppBundleURL(executableURL: URL) -> URL? {
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/") else { return nil }
        let resolvedExecutableURL = executableURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard resolvedExecutableURL.lastPathComponent == executableName else { return nil }

        let helpersURL = resolvedExecutableURL.deletingLastPathComponent()
        let contentsURL = helpersURL.deletingLastPathComponent()
        let appURL = contentsURL.deletingLastPathComponent()
        guard helpersURL.lastPathComponent == "Helpers",
              contentsURL.lastPathComponent == "Contents",
              appURL.pathExtension == "app",
              appURL.appendingPathComponent("Contents/Helpers/\(executableName)")
                .standardizedFileURL == resolvedExecutableURL else {
            return nil
        }
        return appURL
    }
}

/// Runner owns no notification identity. Waking signed app hidden lets app
/// recover journal and use its existing authorized notification center.
nonisolated enum DetachedAgentMainAppWake {
    static func wake(
        runnerExecutableURL: URL = URL(
            fileURLWithPath: ProcessInfo.processInfo.arguments.first ?? ""
        )
    ) {
        guard let appURL = DetachedAgentRunnerExecutable.containingAppBundleURL(
            executableURL: runnerExecutableURL
        ) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-j", appURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
