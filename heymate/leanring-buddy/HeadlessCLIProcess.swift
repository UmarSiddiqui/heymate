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
        overrides: [String: String] = [:],
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        // Agent children inherit only the app's launch environment. Never
        // overlay ~/.config/heymate/secrets.env here: that file holds app and
        // Worker credentials which a coding agent has no reason to read.
        // Narrow runtime values (bridge / connector credentials) are added
        // explicitly through `overrides` for write-enabled legs only.
        var environment = processEnvironment
        environment["PATH"] = LoginShellExecutableResolver.loginPATH()
        // Keep CLIs from paging / prompting a TTY we do not own.
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        for keyToRemove in environmentKeysToRemove {
            environment.removeValue(forKey: keyToRemove)
        }
        // Trusted, per-leg values are applied after inherited secrets are
        // stripped. This lets an execute leg reintroduce only its scoped
        // loopback bridge token without exposing an app or Worker token.
        for (key, value) in overrides {
            environment[key] = value
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

    private let stdoutPipe = Pipe()
    private let stdinPipe = Pipe()
    private let stderrPipe = Pipe()

    private let stdoutAccumulator = HeadlessCLILineAccumulator()
    private let standardErrorTail = HeadlessCLIStandardErrorTail()

    private var spawnedProcessIdentifier: pid_t = 0
    private var spawnedProcessGroupIdentifier: pid_t = 0
    private var isRunning = false

    var processIdentifier: Int32 { spawnedProcessIdentifier }

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
        temporaryDirectoriesToRemove: [URL] = [],
        usesDuplexStandardInput: Bool = false,
        onLine: @escaping (String) -> Void,
        onExit: @escaping (Int32) -> Void
    ) throws {
        let environment = HeadlessChildEnvironment.build(
            stripping: environmentKeysToRemove,
            overrides: environmentOverrides
        )

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

        do {
            let processID = try Self.spawn(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectoryURL: currentDirectoryURL,
                environment: environment,
                standardInputFileDescriptor: usesDuplexStandardInput
                    ? stdinPipe.fileHandleForReading.fileDescriptor
                    : nil,
                standardOutputFileDescriptor: stdoutPipe.fileHandleForWriting.fileDescriptor,
                standardErrorFileDescriptor: stderrPipe.fileHandleForWriting.fileDescriptor
            )

            // POSIX_SPAWN_SETPGROUP with a zero group value makes the child
            // leader of a fresh group whose ID is its PID. Every child and
            // grandchild inherits that group unless it explicitly detaches.
            spawnedProcessIdentifier = processID
            spawnedProcessGroupIdentifier = processID
            isRunning = true

            // Parent must release its copies of the child-side descriptors or
            // EOF never reaches the readability handlers after the group exits.
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            stdinPipe.fileHandleForReading.closeFile()
            if !usesDuplexStandardInput {
                stdinPipe.fileHandleForWriting.closeFile()
            }

            DispatchQueue.global(qos: .utility).async {
                var waitStatus: Int32 = 0
                while waitpid(processID, &waitStatus, 0) == -1, errno == EINTR {}
                let terminationStatus = Self.terminationStatus(fromWaitStatus: waitStatus)
                Self.removeTemporaryDirectories(temporaryDirectoriesToRemove)
                Task { @MainActor in
                    self.isRunning = false
                    self.drainRemainingOutput(onLine: onLine)
                    onExit(terminationStatus)
                }
            }
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Self.removeTemporaryDirectories(temporaryDirectoriesToRemove)
            throw error
        }
    }

    /// Launches the CLI as leader of a dedicated process group. Foundation's
    /// `Process` has no public process-group configuration; calling
    /// `setpgid` after `run()` is already too late because the child has exec'd.
    nonisolated private static func spawn(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        environment: [String: String],
        standardInputFileDescriptor: Int32?,
        standardOutputFileDescriptor: Int32,
        standardErrorFileDescriptor: Int32
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?

        try requireSpawnSuccess(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try requireSpawnSuccess(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }

        if #available(macOS 26.0, *) {
            try requireSpawnSuccess(
                posix_spawn_file_actions_addchdir(&fileActions, currentDirectoryURL.path)
            )
        } else {
            try requireSpawnSuccess(
                posix_spawn_file_actions_addchdir_np(&fileActions, currentDirectoryURL.path)
            )
        }

        if let standardInputFileDescriptor {
            try requireSpawnSuccess(
                posix_spawn_file_actions_adddup2(
                    &fileActions,
                    standardInputFileDescriptor,
                    STDIN_FILENO
                )
            )
        } else {
            // A job that never answers approvals must not inherit a live pipe:
            // `claude -p` waits for input when stdin remains open.
            try requireSpawnSuccess(
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDIN_FILENO,
                    "/dev/null",
                    O_RDONLY,
                    0
                )
            )
        }
        try requireSpawnSuccess(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                standardOutputFileDescriptor,
                STDOUT_FILENO
            )
        )
        try requireSpawnSuccess(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                standardErrorFileDescriptor,
                STDERR_FILENO
            )
        )
        let duplicatedFileDescriptors = Set(
            [standardOutputFileDescriptor, standardErrorFileDescriptor]
                + [standardInputFileDescriptor].compactMap { $0 }
        )
        for fileDescriptor in duplicatedFileDescriptors where fileDescriptor > STDERR_FILENO {
            try requireSpawnSuccess(
                posix_spawn_file_actions_addclose(&fileActions, fileDescriptor)
            )
        }

        try requireSpawnSuccess(
            posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
            )
        )
        try requireSpawnSuccess(posix_spawnattr_setpgroup(&attributes, 0))

        let executablePath = executableURL.path
        var argumentPointers: [UnsafeMutablePointer<CChar>?] =
            ([executablePath] + arguments).map { strdup($0) }
        argumentPointers.append(nil)
        defer {
            for case let pointer? in argumentPointers {
                free(pointer)
            }
        }

        let environmentStrings: [String] = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var environmentPointers: [UnsafeMutablePointer<CChar>?] = environmentStrings
            .map { strdup($0) }
        environmentPointers.append(nil)
        defer {
            for case let pointer? in environmentPointers {
                free(pointer)
            }
        }

        var processID: pid_t = 0
        let spawnResult = argumentPointers.withUnsafeMutableBufferPointer { argv in
            environmentPointers.withUnsafeMutableBufferPointer { envp in
                posix_spawn(
                    &processID,
                    executablePath,
                    &fileActions,
                    &attributes,
                    argv.baseAddress,
                    envp.baseAddress
                )
            }
        }
        try requireSpawnSuccess(spawnResult)
        return processID
    }

    nonisolated private static func requireSpawnSuccess(_ result: Int32) throws {
        guard result != 0 else { return }
        throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
    }

    nonisolated private static func terminationStatus(fromWaitStatus waitStatus: Int32) -> Int32 {
        let terminationSignal = waitStatus & 0x7f
        if terminationSignal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return terminationSignal
    }

    nonisolated private static func removeTemporaryDirectories(_ directories: [URL]) {
        let allowedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.heymate.app", isDirectory: true)
            .appendingPathComponent("opencode-config", isDirectory: true)
            .standardizedFileURL.path
        for directory in directories {
            let path = directory.standardizedFileURL.path
            guard path.hasPrefix(allowedRoot + "/") else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func writeToStandardInput(_ data: Data) {
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data("\n".utf8))
    }

    /// SIGTERM, then SIGKILL after `killGracePeriod` if any member of the
    /// process tree is still up. Negative targets signal the whole group.
    func terminateThenKill() {
        guard isRunning else { return }
        let processID = spawnedProcessIdentifier
        let processGroupID = spawnedProcessGroupIdentifier
        let ownsSafeProcessGroup = processGroupID == processID
            && processGroupID > 1
            && processGroupID != getpgrp()
        let signalTarget = ownsSafeProcessGroup ? -processGroupID : processID

        kill(signalTarget, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGracePeriod) {
            // Signal zero checks group existence without racing the waitpid
            // thread. EPERM still means a matching process exists.
            if kill(signalTarget, 0) == 0 || errno == EPERM {
                kill(signalTarget, SIGKILL)
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
