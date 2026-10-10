//
//  AppleScript.swift
//  HeyMate
//
//  Runs a snippet of AppleScript through osascript: enough to glue
//  HeyMate to Music, Spotify, Terminal and friends. Computer use has its
//  own driver; keep this small.
//

import Foundation

nonisolated enum AppleScript {
    nonisolated struct Outcome: Equatable, Sendable {
        /// Standard output, trimmed. `-ss` makes results AppleScript
        /// source, so a string comes back quoted.
        let output: String
        let errorOutput: String
        /// osascript's exit status, or -1 when it could not be launched.
        let status: Int32

        var succeeded: Bool { status == 0 }
    }

    /// `text` as an AppleScript string literal, quotes included, so it can
    /// be spliced into a script without changing its meaning.
    static func literal(_ text: String) -> String {
        var quoted = "\""
        for character in text {
            if character == "\\" || character == "\"" { quoted.append("\\") }
            quoted.append(character)
        }
        quoted.append("\"")
        return quoted
    }

    /// Runs `source` and waits for it. Blocks the calling thread, so call it
    /// off the main thread for anything that talks to another app.
    static func run(_ source: String) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-ss", "-e", source]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return Outcome(output: "", errorOutput: error.localizedDescription, status: -1)
        }
        // Drain both pipes before waiting: a script that prints more than a
        // pipe holds would otherwise block on write while we block on exit.
        let errorData = DrainedPipe(stderr)
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Outcome(
            output: trimmed(outputData),
            errorOutput: trimmed(errorData.wait()),
            status: process.terminationStatus
        )
    }

    private static func trimmed(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads a pipe to its end on a background thread.
    private nonisolated final class DrainedPipe: @unchecked Sendable {
        private var data = Data()
        private let done = DispatchSemaphore(value: 0)

        init(_ pipe: Pipe) {
            let handle = pipe.fileHandleForReading
            DispatchQueue.global(qos: .utility).async {
                self.data = handle.readDataToEndOfFile()
                self.done.signal()
            }
        }

        /// Blocks until the writer closes the pipe. Call once.
        func wait() -> Data {
            done.wait()
            return data
        }
    }
}
