//
//  LoginShellExecutableResolver.swift
//  leanring-buddy
//
//  GUI apps inherit a starved PATH, so Homebrew `opencode` / `claude` are
//  invisible to `Process` unless we rebuild PATH from a login zsh. Cached
//  for the process lifetime because spawning zsh on every agent start is
//  slower than the job’s own boot.
//

import Foundation

nonisolated enum LoginShellExecutableResolver {

    private static var cachedPATH: String?
    private static let lock = NSLock()

    /// Directories a login zsh reports, plus the usual Homebrew locations
    /// in case the non-interactive `-lc` PATH is still incomplete.
    static func loginPATH() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cachedPATH { return cachedPATH }

        var pathEntries: [String] = extraDirectories()
        if let printedPATH = pathPrintedByLoginZsh() {
            pathEntries.append(contentsOf: printedPATH.split(separator: ":").map(String.init))
        }
        if let processPATH = ProcessInfo.processInfo.environment["PATH"] {
            pathEntries.append(contentsOf: processPATH.split(separator: ":").map(String.init))
        }

        var uniqueEntries: [String] = []
        var seen = Set<String>()
        for entry in pathEntries where !entry.isEmpty && seen.insert(entry).inserted {
            uniqueEntries.append(entry)
        }

        let joinedPATH = uniqueEntries.joined(separator: ":")
        cachedPATH = joinedPATH
        return joinedPATH
    }

    static func resolveExecutable(named executableName: String) -> URL? {
        for directory in loginPATH().split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(executableName)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func isExecutableAvailable(named executableName: String) -> Bool {
        resolveExecutable(named: executableName) != nil
    }

    private static func extraDirectories() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.npm-global/bin",
            "/Applications/ChatGPT.app/Contents/Resources",
            "/usr/bin",
            "/bin"
        ]
    }

    private static func pathPrintedByLoginZsh() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "printenv PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let printed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (printed?.isEmpty == false) ? printed : nil
    }
}
