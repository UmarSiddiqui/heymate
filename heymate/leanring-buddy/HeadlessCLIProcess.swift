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
nonisolated final class HeadlessCLILineAccumulator: @unchecked Sendable {

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
nonisolated final class HeadlessCLIStandardErrorTail: @unchecked Sendable {

    private static let maximumRetainedBytes = 16 * 1024

    private let lock = NSLock()
    private var retainedBytes = Data()
    private let beforeAppend: (@Sendable () -> Void)?

    init(beforeAppend: (@Sendable () -> Void)? = nil) {
        self.beforeAppend = beforeAppend
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        beforeAppend?()
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

/// Serializes stderr callback reads with terminal drain. Tail owns its memory
/// bound; this reader only closes race where callback has removed pipe bytes
/// but has not appended them when `onExit` asks for diagnostic summary.
nonisolated final class HeadlessCLIStandardErrorReader: @unchecked Sendable {
    private let lock = NSLock()
    private let tail: HeadlessCLIStandardErrorTail
    private var isSealed = false

    init(tail: HeadlessCLIStandardErrorTail) {
        self.tail = tail
    }

    func readAvailableData(from handle: FileHandle) {
        lock.lock()
        defer { lock.unlock() }
        guard !isSealed else { return }
        tail.append(handle.availableData)
    }

    func readToEndAndSeal(from handle: FileHandle) {
        lock.lock()
        defer { lock.unlock() }
        guard !isSealed else { return }
        tail.append(handle.readDataToEndOfFile())
        isSealed = true
    }

    func sealWithoutReading() {
        lock.lock()
        isSealed = true
        lock.unlock()
    }
}

/// Bounded bridge from FileHandle's callback queue to MainActor parsing.
/// One drain task serves many reads; overflow stops job instead of growing an
/// unbounded task/line backlog from a malicious or broken CLI.
nonisolated final class HeadlessCLIOutputDeliveryBuffer: @unchecked Sendable {
    enum DrainResult {
        case lines([String])
        case overflow
        case finished
    }

    private static let maximumPendingLines = 512
    private static let maximumPendingBytes = 2 * 1024 * 1024
    private static let batchSize = 32

    private let lock = NSLock()
    private var pendingLines: [String] = []
    private var pendingBytes = 0
    private var drainScheduled = false
    private var didOverflow = false
    private var deliveredOverflow = false

    /// Returns true only when caller must schedule one MainActor drain.
    func enqueue(_ lines: [String]) -> Bool {
        guard !lines.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard !didOverflow else { return false }

        for line in lines {
            let byteCount = line.utf8.count
            guard pendingLines.count < Self.maximumPendingLines,
                  pendingBytes <= Self.maximumPendingBytes - min(
                    byteCount,
                    Self.maximumPendingBytes + 1
                  ) else {
                pendingLines.removeAll(keepingCapacity: false)
                pendingBytes = 0
                didOverflow = true
                break
            }
            pendingLines.append(line)
            pendingBytes += byteCount
        }

        guard !drainScheduled else { return false }
        drainScheduled = true
        return true
    }

    func nextBatch() -> DrainResult {
        lock.lock()
        defer { lock.unlock() }

        if didOverflow, !deliveredOverflow {
            deliveredOverflow = true
            drainScheduled = false
            return .overflow
        }
        guard !pendingLines.isEmpty else {
            drainScheduled = false
            return .finished
        }

        let count = min(Self.batchSize, pendingLines.count)
        let lines = Array(pendingLines.prefix(count))
        pendingLines.removeFirst(count)
        pendingBytes -= lines.reduce(0) { $0 + $1.utf8.count }
        return .lines(lines)
    }

    var hasOverflowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didOverflow
    }
}

/// Serializes pipe reads with terminal sealing. FileHandle may already be
/// running a readability callback when waitpid observes child exit. Without
/// this gate, terminal cleanup can read later bytes first or fire `onExit`
/// while callback still has earlier bytes waiting to enter delivery queue.
nonisolated final class HeadlessCLIStandardOutputReader: @unchecked Sendable {
    private let lock = NSLock()
    private let accumulator = HeadlessCLILineAccumulator()
    private let deliveryBuffer: HeadlessCLIOutputDeliveryBuffer
    private var isSealed = false

    init(deliveryBuffer: HeadlessCLIOutputDeliveryBuffer) {
        self.deliveryBuffer = deliveryBuffer
    }

    /// Reads one readiness notification. Returns true only when caller must
    /// schedule delivery drain.
    func readAvailableData(from handle: FileHandle) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isSealed else { return false }

        let data = handle.availableData
        guard !data.isEmpty else { return false }
        return deliveryBuffer.enqueue(accumulator.completeLines(from: data))
    }

    /// Called after process group has closed stdout. Earlier callback either
    /// completes before this lock or observes sealed state afterward, keeping
    /// bytes and callbacks in one order.
    func readToEndAndSeal(from handle: FileHandle) {
        lock.lock()
        defer { lock.unlock() }
        guard !isSealed else { return }

        let trailingData = handle.readDataToEndOfFile()
        _ = deliveryBuffer.enqueue(accumulator.completeLines(from: trailingData))
        _ = deliveryBuffer.enqueue(accumulator.flushRemainder())
        isSealed = true
    }

    /// Used when descendants keep pipe open past cleanup deadline. Existing
    /// callback finishes first; unread kernel bytes are discarded without a
    /// blocking read.
    func sealWithoutReading() {
        lock.lock()
        isSealed = true
        lock.unlock()
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
    /// Read end is inherited by a tiny shell monitor; write end stays here.
    /// If this owner crashes, EOF makes monitor kill CLI process group.
    private let lifetimePipe = Pipe()

    private let stdoutDeliveryBuffer = HeadlessCLIOutputDeliveryBuffer()
    private lazy var stdoutReader = HeadlessCLIStandardOutputReader(
        deliveryBuffer: stdoutDeliveryBuffer
    )
    private let standardErrorTail: HeadlessCLIStandardErrorTail
    private lazy var standardErrorReader = HeadlessCLIStandardErrorReader(
        tail: standardErrorTail
    )

    private var spawnedProcessIdentifier: pid_t = 0
    private var spawnedProcessGroupIdentifier: pid_t = 0
    private var spawnedProcessIdentity: AgentProcessIdentity?
    private var isRunning = false

    init(standardErrorTail: HeadlessCLIStandardErrorTail = HeadlessCLIStandardErrorTail()) {
        self.standardErrorTail = standardErrorTail
        // Monitor or CLI may exit between readiness and a write. Convert that
        // race to EPIPE instead of terminating HeyMate with SIGPIPE.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(lifetimePipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

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

        let stdoutReader = self.stdoutReader
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            guard stdoutReader.readAvailableData(from: handle) else { return }
            Task { @MainActor [weak self] in
                await self?.drainBufferedOutput(onLine: onLine)
            }
        }

        let standardErrorReader = self.standardErrorReader
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            standardErrorReader.readAvailableData(from: handle)
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
                standardErrorFileDescriptor: stderrPipe.fileHandleForWriting.fileDescriptor,
                lifetimeFileDescriptor: lifetimePipe.fileHandleForReading.fileDescriptor
            )

            // POSIX_SPAWN_SETPGROUP with a zero group value makes the child
            // leader of a fresh group whose ID is its PID. Every child and
            // grandchild inherits that group unless it explicitly detaches.
            spawnedProcessIdentifier = processID
            spawnedProcessGroupIdentifier = processID
            guard let processIdentity = AgentProcessIdentityInspector.identity(for: processID),
                  AgentProcessIdentityInspector.matchesLiveProcessGeneration(processIdentity),
                  getpgid(processID) == processID else {
                kill(-processID, SIGKILL)
                var waitStatus: Int32 = 0
                while waitpid(processID, &waitStatus, 0) == -1, errno == EINTR {}
                throw POSIXError(.EIO)
            }
            spawnedProcessIdentity = processIdentity
            isRunning = true

            // Parent must release its copies of the child-side descriptors or
            // EOF never reaches the readability handlers after the group exits.
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            stdinPipe.fileHandleForReading.closeFile()
            lifetimePipe.fileHandleForReading.closeFile()
            if !usesDuplexStandardInput {
                stdinPipe.fileHandleForWriting.closeFile()
            }

            DispatchQueue.global(qos: .utility).async {
                var waitStatus: Int32 = 0
                var waitResult: pid_t
                repeat {
                    waitResult = waitpid(processID, &waitStatus, 0)
                } while waitResult == -1 && errno == EINTR
                let terminationStatus = waitResult == processID
                    ? Self.terminationStatus(fromWaitStatus: waitStatus)
                    : 70
                OpenCodeTemporaryDirectoryCleaner.remove(temporaryDirectoriesToRemove)
                Task { @MainActor in
                    // Distinguish expected cleanup from owner death. Crash
                    // closes pipe without marker, so monitor always kills
                    // owned group even if CLI leader already exited.
                    try? self.lifetimePipe.fileHandleForWriting.write(
                        contentsOf: Data("owner-complete\n".utf8)
                    )
                    self.lifetimePipe.fileHandleForWriting.closeFile()
                    let processTreeExited = await self.waitForProcessGroupToExit(
                        timeout: .seconds(Self.killGracePeriod + 2)
                    )
                    self.isRunning = false
                    let outputDeliveredWithoutOverflow: Bool
                    if processTreeExited {
                        outputDeliveredWithoutOverflow = self.drainRemainingOutput(
                            onLine: onLine
                        )
                    } else {
                        outputDeliveredWithoutOverflow = self.closeOutputWithoutBlocking(
                            onLine: onLine
                        )
                    }
                    onExit(
                        processTreeExited && outputDeliveredWithoutOverflow
                            ? terminationStatus
                            : 70
                    )
                }
            }
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            lifetimePipe.fileHandleForReading.closeFile()
            lifetimePipe.fileHandleForWriting.closeFile()
            OpenCodeTemporaryDirectoryCleaner.remove(temporaryDirectoriesToRemove)
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
        standardErrorFileDescriptor: Int32,
        lifetimeFileDescriptor: Int32
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
        let inheritedLifetimeFileDescriptor: Int32 = 64
        try requireSpawnSuccess(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                lifetimeFileDescriptor,
                inheritedLifetimeFileDescriptor
            )
        )
        let duplicatedFileDescriptors = Set(
            [standardOutputFileDescriptor, standardErrorFileDescriptor]
                + [standardInputFileDescriptor, lifetimeFileDescriptor].compactMap { $0 }
        )
        for fileDescriptor in duplicatedFileDescriptors
        where fileDescriptor > STDERR_FILENO
            && fileDescriptor != inheritedLifetimeFileDescriptor {
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
        // macOS has no parent-death signal. Fixed shell monitor owns only FD
        // 64; owner death closes write end without normal marker, causing
        // TERM/KILL of CLI group.
        // Actual executable and arguments are positional values, never shell
        // source, so user text cannot alter monitor command.
        let shellPath = "/bin/sh"
        let lifetimeGuardScript = """
        group_id=$$
        /bin/sh -c '
          trap "" TERM HUP INT
          group_id="$1"
          normal_shutdown=0
          while IFS= read -r marker <&64; do
            if [ "$marker" = "owner-complete" ]; then
              normal_shutdown=1
            fi
          done
          if [ "$normal_shutdown" = "1" ]; then
            other_member=0
            for member in $(/usr/bin/pgrep -g "$group_id" . 2>/dev/null); do
              if [ "$member" != "$$" ]; then
                other_member=1
                break
              fi
            done
            if [ "$other_member" = "0" ]; then
              exit 0
            fi
          fi
          /bin/kill -TERM -- -"$group_id" 2>/dev/null || true
          /bin/sleep 2
          /bin/kill -KILL -- -"$group_id" 2>/dev/null || true
        ' heymate-agent-lifetime-monitor "$group_id" </dev/null >/dev/null 2>&1 &
        exec "$@" 64>&-
        """
        let guardedArguments = [
            shellPath,
            "-c",
            lifetimeGuardScript,
            "heymate-agent-lifetime-guard",
            executablePath
        ] + arguments
        var argumentPointers: [UnsafeMutablePointer<CChar>?] =
            guardedArguments.map { strdup($0) }
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
                    shellPath,
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

    @discardableResult
    func writeToStandardInput(_ data: Data) -> Bool {
        do {
            var framedData = data
            framedData.append(0x0A)
            try stdinPipe.fileHandleForWriting.write(contentsOf: framedData)
            return true
        } catch {
            return false
        }
    }

    /// SIGTERM, then SIGKILL after `killGracePeriod` if any member of the
    /// process tree is still up. Negative targets signal the whole group.
    func terminateThenKill() {
        guard let signalTarget = ownedSignalTarget() else { return }

        kill(signalTarget, SIGTERM)
        Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            try? await clock.sleep(for: .seconds(Self.killGracePeriod))
            guard let currentTarget = self?.ownedSignalTarget() else { return }
            kill(currentTarget, SIGKILL)
        }
    }

    /// Stops the owned process tree and returns only after it is gone.
    /// Terminal takeover uses this path so two CLI clients never drive the
    /// same persisted session at once.
    @discardableResult
    func terminateAndWait() async -> Bool {
        guard let signalTarget = ownedSignalTarget() else {
            return await waitForProcessGroupToExit(
                timeout: .seconds(Self.killGracePeriod + 2)
            )
        }

        kill(signalTarget, SIGTERM)
        let clock = ContinuousClock()
        let terminateDeadline = clock.now.advanced(by: .seconds(Self.killGracePeriod))
        while Self.processTreeExists(signalTarget: signalTarget), clock.now < terminateDeadline {
            if Task.isCancelled { break }
            try? await clock.sleep(for: .milliseconds(25))
        }

        if Self.processTreeExists(signalTarget: signalTarget),
           let currentTarget = ownedSignalTarget() {
            kill(currentTarget, SIGKILL)
        }

        let killDeadline = clock.now.advanced(by: .seconds(1))
        while Self.processTreeExists(signalTarget: signalTarget), clock.now < killDeadline {
            if Task.isCancelled { break }
            try? await clock.sleep(for: .milliseconds(25))
        }
        return !Self.processTreeExists(signalTarget: signalTarget)
    }

    private func ownedSignalTarget() -> pid_t? {
        let processID = spawnedProcessIdentifier
        let processGroupID = spawnedProcessGroupIdentifier
        guard processID > 1,
              let processIdentity = spawnedProcessIdentity,
              AgentProcessIdentityInspector.matchesLiveProcessGeneration(processIdentity),
              getpgid(processID) == processGroupID else { return nil }
        let ownsSafeProcessGroup = processGroupID == processID
            && processGroupID > 1
            && processGroupID != getpgrp()
        return ownsSafeProcessGroup ? -processGroupID : nil
    }

    nonisolated private static func processTreeExists(signalTarget: pid_t) -> Bool {
        kill(signalTarget, 0) == 0 || errno == EPERM
    }

    private func waitForProcessGroupToExit(timeout: Duration) async -> Bool {
        let signalTarget = -spawnedProcessGroupIdentifier
        guard signalTarget < -1 else { return true }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while Self.processTreeExists(signalTarget: signalTarget), clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(25))
        }
        return !Self.processTreeExists(signalTarget: signalTarget)
    }

    /// Reads whatever the child wrote between its last readability callback
    /// and exit, then releases the handlers. Both pipes have finite buffered
    /// content once the writer has exited, so the reads return promptly.
    private func drainRemainingOutput(onLine: (String) -> Void) -> Bool {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        stdoutReader.readToEndAndSeal(from: stdoutPipe.fileHandleForReading)
        drainBufferedOutputSynchronously(onLine: onLine)

        standardErrorReader.readToEndAndSeal(from: stderrPipe.fileHandleForReading)
        return !stdoutDeliveryBuffer.hasOverflowed
    }

    private func drainBufferedOutput(onLine: (String) -> Void) async {
        while true {
            switch stdoutDeliveryBuffer.nextBatch() {
            case .lines(let lines):
                for line in lines { onLine(line) }
                await Task.yield()
            case .overflow:
                terminateThenKill()
                return
            case .finished:
                return
            }
        }
    }

    /// Final drain never yields: queued callbacks must finish before terminal
    /// callback mutates runner state. Queue remains bounded at 512 lines/2 MB.
    private func drainBufferedOutputSynchronously(onLine: (String) -> Void) {
        while true {
            switch stdoutDeliveryBuffer.nextBatch() {
            case .lines(let lines):
                for line in lines { onLine(line) }
            case .overflow:
                terminateThenKill()
                return
            case .finished:
                return
            }
        }
    }

    private func closeOutputWithoutBlocking(onLine: (String) -> Void) -> Bool {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutReader.sealWithoutReading()
        standardErrorReader.sealWithoutReading()
        drainBufferedOutputSynchronously(onLine: onLine)
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        return !stdoutDeliveryBuffer.hasOverflowed
    }
}
