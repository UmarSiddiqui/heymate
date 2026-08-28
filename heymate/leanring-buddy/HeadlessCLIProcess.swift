//
//  HeadlessCLIProcess.swift
//  leanring-buddy
//
//  One Foundation.Process with line-buffered stdout and a SIGTERM→SIGKILL
//  cancel ladder. Adapters never talk to Process themselves so OpenCode and
//  Claude Code share timeout / kill / PATH behavior.
//

import Darwin
import Foundation

/// Accumulates raw stdout bytes and yields only *complete* lines.
///
/// A `readabilityHandler` chunk boundary lands wherever the pipe happens to
/// flush, which is routinely in the middle of a JSON line — `opencode run`
/// emits lines close to a kilobyte for a single one-line file write, and a
/// real diff is far larger. Splitting each chunk on newlines independently
/// turns one valid event into two invalid fragments, and every agent event in
/// that line is then silently dropped. Buffering the trailing partial line
/// until the read that completes it is what makes streamed progress reliable.
///
/// Bytes are accumulated rather than `String`s for a second reason: a
/// multi-byte UTF-8 sequence can straddle a chunk boundary too, and decoding
/// each chunk on its own returns nil for the whole chunk when it does.
final class HeadlessCLILineAccumulator: @unchecked Sendable {

    /// A single line longer than this is treated as a runaway rather than
    /// buffered forever. No CLI emits a legitimate 8 MB JSON line.
    private static let maximumBufferedBytes = 8 * 1024 * 1024

    private let lock = NSLock()
    private var carriedBytes = Data()

    /// Complete lines contained in `chunk`, holding back any trailing partial
    /// line until a later read completes it.
    func completeLines(from chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        carriedBytes.append(chunk)

        var lines: [String] = []
        var lineStartIndex = carriedBytes.startIndex
        var searchIndex = carriedBytes.startIndex

        while let newlineIndex = carriedBytes[searchIndex...].firstIndex(of: UInt8(ascii: "\n")) {
            appendDecoded(carriedBytes[lineStartIndex..<newlineIndex], to: &lines)
            lineStartIndex = carriedBytes.index(after: newlineIndex)
            searchIndex = lineStartIndex
        }

        // Re-base once per read rather than once per line, so a chunk holding
        // many lines does not copy the remaining buffer repeatedly.
        carriedBytes = (lineStartIndex == carriedBytes.endIndex)
            ? Data()
            : Data(carriedBytes[lineStartIndex...])

        if carriedBytes.count > Self.maximumBufferedBytes {
            carriedBytes = Data()
        }

        return lines
    }

    /// Whatever is left when the pipe closes, so a final line written without
    /// a trailing newline is still delivered.
    func flushRemainder() -> [String] {
        lock.lock()
        defer { lock.unlock() }

        var lines: [String] = []
        appendDecoded(carriedBytes[carriedBytes.startIndex...], to: &lines)
        carriedBytes = Data()
        return lines
    }

    private func appendDecoded(_ lineBytes: Data.SubSequence, to lines: inout [String]) {
        guard !lineBytes.isEmpty,
              let line = String(data: Data(lineBytes), encoding: .utf8) else { return }
        let trimmedLine = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard !trimmedLine.isEmpty else { return }
        lines.append(trimmedLine)
    }
}

/// Keeps the tail of a child's stderr so a failure can say what actually went
/// wrong instead of "Exited with status 1".
///
/// Draining stderr is not optional. A pipe nobody reads fills at roughly 64 KB
/// and the child then blocks on its next stderr write — forever, as far as the
/// job is concerned, until the runtime timeout kills it. The bound exists
/// because a chatty CLI would otherwise pin an unbounded buffer in memory for
/// the life of the run.
final class HeadlessCLIStandardErrorTail: @unchecked Sendable {

    private static let maximumRetainedBytes = 16 * 1024

    private let lock = NSLock()
    private var retainedBytes = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        retainedBytes.append(chunk)
        if retainedBytes.count > Self.maximumRetainedBytes {
            retainedBytes = Data(retainedBytes.suffix(Self.maximumRetainedBytes))
        }
    }

    /// The last `lineLimit` non-empty lines, oldest first. The leading partial
    /// line is dropped when the buffer has already wrapped, because half a
    /// sentence reads worse than no sentence.
    func recentLines(limit lineLimit: Int) -> [String] {
        lock.lock()
        let snapshot = retainedBytes
        lock.unlock()

        guard let text = String(data: snapshot, encoding: .utf8) else { return [] }
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(lines.suffix(lineLimit))
    }
}

/// The environment every HeyMate-spawned CLI child receives.
///
/// `stripping` is the important argument. An executor running on a
/// subscription sign-in must not see a provider API key: `claude` prefers
/// `ANTHROPIC_API_KEY` when one is present, so a stray key in
/// `~/.config/heymate/secrets.env` silently moves the user from the Claude
/// subscription they are paying for onto metered API billing, with no visible
/// change anywhere in the UI.
nonisolated enum HeadlessChildEnvironment {

    static func build(
        stripping environmentKeysToRemove: [String],
        overrides: [String: String] = [:]
    ) -> [String: String] {
        var environment = HeyMateSecrets.mergedProcessEnvironment()
        environment["PATH"] = LoginShellExecutableResolver.loginPATH()
        // Keep CLIs from paging / prompting a TTY we do not own.
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        for (key, value) in overrides {
            environment[key] = value
        }
        for keyToRemove in environmentKeysToRemove {
            environment.removeValue(forKey: keyToRemove)
        }
        return environment
    }
}

@MainActor
final class HeadlessCLIProcess {

    static let maximumRuntime: TimeInterval = 15 * 60
    /// A read-only planning leg reads and thinks; it does not build. Fifteen
    /// minutes of that is a hang, not a long job.
    static let maximumPlanningRuntime: TimeInterval = 5 * 60
    static let killGracePeriod: TimeInterval = 2

    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stdinPipe = Pipe()
    private let stderrPipe = Pipe()

    private let stdoutAccumulator = HeadlessCLILineAccumulator()
    private let standardErrorTail = HeadlessCLIStandardErrorTail()

    var processIdentifier: Int32 { process.processIdentifier }

    /// The tail of the child's stderr, formatted for a run card. Empty when
    /// the child said nothing on stderr.
    var recentStandardErrorSummary: String {
        standardErrorTail.recentLines(limit: 6).joined(separator: " · ")
    }

    func start(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        environmentKeysToRemove: [String] = [],
        environmentOverrides: [String: String] = [:],
        usesDuplexStandardInput: Bool = false,
        onLine: @escaping (String) -> Void,
        onExit: @escaping (Int32) -> Void
    ) throws {
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = HeadlessChildEnvironment.build(
            stripping: environmentKeysToRemove,
            overrides: environmentOverrides
        )
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // A job that never answers approvals must not be handed a live pipe:
        // `claude -p` blocks three seconds waiting for stdin that is never
        // coming, on every single run.
        process.standardInput = usesDuplexStandardInput ? stdinPipe : FileHandle.nullDevice

        let stdoutAccumulator = self.stdoutAccumulator
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let lines = stdoutAccumulator.completeLines(from: data)
            guard !lines.isEmpty else { return }
            Task { @MainActor in
                for line in lines {
                    onLine(line)
                }
            }
        }

        let standardErrorTail = self.standardErrorTail
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            standardErrorTail.append(handle.availableData)
        }

        process.terminationHandler = { finishedProcess in
            let status = finishedProcess.terminationStatus
            Task { @MainActor in
                self.drainRemainingOutput(onLine: onLine)
                onExit(status)
            }
        }

        try process.run()
    }

    func writeToStandardInput(_ data: Data) {
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data("\n".utf8))
    }

    /// SIGTERM, then SIGKILL after `killGracePeriod` if the child is still up.
    func terminateThenKill() {
        guard process.isRunning else { return }
        let processID = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGracePeriod) {
            var unused: Int32 = 0
            if waitpid(processID, &unused, WNOHANG) == 0 {
                kill(processID, SIGKILL)
            }
        }
    }

    /// Reads whatever the child wrote between its last readability callback
    /// and exit, then releases the handlers. Both pipes have finite buffered
    /// content once the writer has exited, so the reads return promptly.
    private func drainRemainingOutput(onLine: (String) -> Void) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let trailingStandardOutput = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        for line in stdoutAccumulator.completeLines(from: trailingStandardOutput) {
            onLine(line)
        }
        for line in stdoutAccumulator.flushRemainder() {
            onLine(line)
        }

        standardErrorTail.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
    }
}
