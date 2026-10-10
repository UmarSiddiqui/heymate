//
//  DetachedAgentRunnerEngine.swift
//  HeyMate
//
//  One process owns one CLI execution attempt. UI communicates through
//  durable, attempt-scoped state/journal/command files and may exit freely.
//

import Darwin
import Dispatch
import Foundation

@MainActor
final class DetachedAgentRunnerEngine {
    private enum InitializationError: Error {
        case unsupportedLeg
    }

    private enum StopReason {
        case cancelled
        case timedOut
        case approvalTimedOut
        case handedOff
        case shutdown
    }

    private let request: DetachedAgentLaunchRequest
    private let process = HeadlessCLIProcess()
    private let adapter: HeadlessCLIAdapter
    private let journal: DetachedAgentRuntimeJournal
    private let stateStore: DetachedAgentDurableStateStore
    private let commandMailbox: DetachedAgentCommandMailbox
    private let workClock = SuspendingClock()
    private let exitProcess: (Int32) -> Void
    private let wakeMainApp: () -> Void

    private var state: DetachedAgentDurableState
    private var agentReportedFailure = false
    private var agentReportedBlocked = false
    private var pendingProviderApprovalID: String?
    private var workBudgetRemaining: Duration
    private var workSegmentStartedAt: SuspendingClock.Instant?
    private var workTimeoutTask: Task<Void, Never>?
    private var approvalTimeoutTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var childIdentityTask: Task<Void, Never>?
    private var progressFlushTask: Task<Void, Never>?
    private var pendingProgressSummary: String?
    private var isStopping = false
    private var isTerminal = false

    init(
        request: DetachedAgentLaunchRequest,
        rootDirectoryURL: URL = DetachedAgentRuntimePaths.defaultRootURL,
        exitProcess: @escaping (Int32) -> Void = { Darwin.exit($0) },
        wakeMainApp: @escaping () -> Void = { DetachedAgentMainAppWake.wake() }
    ) throws {
        guard request.leg == .execute else {
            throw InitializationError.unsupportedLeg
        }
        self.request = request
        self.exitProcess = exitProcess
        self.wakeMainApp = wakeMainApp
        adapter = HeadlessCLIAdapterFactory.adapter(for: request.executor)
        journal = try DetachedAgentRuntimeJournal(
            rootDirectoryURL: rootDirectoryURL,
            runID: request.runID,
            attemptID: request.attemptID
        )
        stateStore = try DetachedAgentDurableStateStore(
            rootDirectoryURL: rootDirectoryURL,
            runID: request.runID,
            attemptID: request.attemptID
        )
        commandMailbox = try DetachedAgentCommandMailbox(
            rootDirectoryURL: rootDirectoryURL,
            runID: request.runID,
            attemptID: request.attemptID
        )
        guard let runnerIdentity = AgentProcessIdentityInspector.identity(for: getpid()) else {
            throw DetachedAgentPersistenceError.invalidPersistencePath("runner identity")
        }
        state = DetachedAgentDurableState(
            runID: request.runID,
            attemptID: request.attemptID,
            leg: request.leg,
            phase: .queued,
            runnerIdentity: runnerIdentity,
            lastHeartbeatAt: Date()
        )
        workBudgetRemaining = .seconds(request.spec.runtimeLimit)
    }

    func start() {
        do {
            try append(.ready)
            try append(.phaseChanged(.launching)) { state in
                state.phase = .launching
            }
            try process.start(
                executableURL: request.spec.executableURL,
                arguments: request.spec.arguments,
                currentDirectoryURL: request.spec.currentDirectoryURL,
                environmentKeysToRemove: request.spec.environmentKeysToRemove,
                environmentOverrides: request.spec.environmentOverrides,
                temporaryDirectoriesToRemove: request.spec.temporaryDirectoriesToRemove,
                usesDuplexStandardInput: request.spec.usesDuplexStandardInput,
                onLine: { [weak self] line in
                    self?.handleStandardOutputLine(line)
                },
                onExit: { [weak self] status in
                    self?.handleProcessExit(status: status)
                }
            )

            try append(.phaseChanged(.running)) { state in
                state.phase = .running
                state.lastHeartbeatAt = Date()
                state.latestSafeSummary = "Working"
            }
            captureChildIdentity()
            resumeWorkTimeout()
            startCommandLoop()
            startHeartbeatLoop()
        } catch {
            finishAfterStartupFailure()
        }
    }

    private func handleStandardOutputLine(_ line: String) {
        guard !isTerminal, !isStopping else { return }

        for event in adapter.events(fromStdoutLine: line) {
            switch event {
            case .started:
                continue
            case .sessionIdentified:
                // Execution resumes app's existing session. Session identifiers
                // never enter detached persistence.
                continue
            case .tool(let summary):
                recordProgress(summary)
            case .text:
                // Raw assistant output stays in runner memory/pipe only. It
                // must never be disguised as a persistence-safe summary.
                continue
            case .planReady:
                // Initial rollout detaches write-enabled execute legs only.
                recordProgress("Runner received an unsupported plan event")
            case .approvalRequested(let providerID, _):
                beginApprovalWait(providerID: providerID)
            case .finished(let finalMessage):
                // Read in memory only; the message itself is never persisted.
                if headlessAgentReportsBlocked(finalMessage) { agentReportedBlocked = true }
            case .failed:
                agentReportedFailure = true
            }
        }
    }

    private func handleProcessExit(status: Int32) {
        guard !isTerminal, !isStopping else { return }
        pauseWorkTimeout()
        approvalTimeoutTask?.cancel()

        if agentReportedFailure {
            finishTerminal(
                phase: .failed,
                exitCode: status,
                summary: nil,
                error: "Coding agent reported an error"
            )
            return
        }
        guard status == 0 else {
            finishTerminal(
                phase: .failed,
                exitCode: status,
                summary: nil,
                error: "Coding agent exited with status \(status)"
            )
            return
        }
        // Exit 0 only means the process ended. An agent that was refused a
        // permission or lacked a tool says so and still exits cleanly.
        if agentReportedBlocked {
            finishTerminal(
                phase: .failed,
                exitCode: status,
                summary: nil,
                error: "Agent could not finish the task. Open its chat for details."
            )
            return
        }
        finishTerminal(
            phase: .succeeded,
            exitCode: 0,
            summary: "Work completed",
            error: nil
        )
    }

    private func recordProgress(_ summary: String) {
        pendingProgressSummary = summary
        guard progressFlushTask == nil else { return }
        progressFlushTask = Task { [weak self] in
            let clock = SuspendingClock()
            try? await clock.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.progressFlushTask = nil
            self?.flushPendingProgress()
        }
    }

    private func flushPendingProgress() {
        guard !isTerminal, !isStopping, state.phase == .running,
              let summary = pendingProgressSummary else { return }
        pendingProgressSummary = nil
        do {
            try append(.progress(summary)) { state in
                state.phase = .running
                state.latestSafeSummary = summary
            }
        } catch {
            stopAfterPersistenceFailure()
        }
    }

    private func beginApprovalWait(providerID: String) {
        guard pendingProviderApprovalID == nil else { return }
        discardPendingProgress()
        pauseWorkTimeout()
        let token = DetachedAgentApprovalToken()
        pendingProviderApprovalID = providerID
        do {
            let safeSummary = "Agent needs approval"
            try append(.approvalRequested(token: token, summary: safeSummary)) { state in
                state.phase = .waitingForApproval
                state.pendingApprovalToken = token
                state.latestSafeSummary = safeSummary
            }
        } catch {
            stopAfterPersistenceFailure()
            return
        }
        wakeMainApp()

        approvalTimeoutTask?.cancel()
        approvalTimeoutTask = Task { [weak self] in
            let clock = SuspendingClock()
            try? await clock.sleep(for: .seconds(86_400))
            guard !Task.isCancelled else { return }
            self?.beginStop(.approvalTimedOut)
        }
    }

    private func startCommandLoop() {
        commandTask = Task { [weak self] in
            let clock = SuspendingClock()
            while let self, !Task.isCancelled, !self.isTerminal {
                do {
                    _ = try self.commandMailbox.drain { envelope in
                        self.accept(envelope.command)
                    }
                } catch {
                    self.stopAfterPersistenceFailure()
                    return
                }
                try? await clock.sleep(for: .milliseconds(250))
            }
        }
    }

    private func accept(_ command: DetachedAgentRuntimeCommand) -> Bool {
        guard !isTerminal else { return true }
        switch command.kind {
        case .interrupt, .cancel:
            return beginStop(.cancelled)
        case .takeOverInTerminal:
            return beginStop(.handedOff)
        case .shutdown:
            return beginStop(.shutdown)
        case .respondToApproval:
            return resolveApproval(command)
        case .requestSnapshot, .detach, .resume:
            return true
        case .sendFollowUp:
            // Logical follow-up queue stays in app and starts a fresh attempt.
            return true
        }
    }

    private func resolveApproval(_ command: DetachedAgentRuntimeCommand) -> Bool {
        guard state.phase == .waitingForApproval,
              let expectedToken = state.pendingApprovalToken,
              command.approvalToken == expectedToken,
              let decision = command.approvalDecision,
              let providerID = pendingProviderApprovalID else { return true }

        if decision == .deny {
            if let payload = adapter.stdinPayloadForApproval(id: providerID, approve: false) {
                guard process.writeToStandardInput(payload) else { return false }
            }
            approvalTimeoutTask?.cancel()
            return beginStop(.cancelled)
        }

        guard let payload = adapter.stdinPayloadForApproval(id: providerID, approve: true),
              process.writeToStandardInput(payload) else { return false }
        approvalTimeoutTask?.cancel()
        pendingProviderApprovalID = nil
        do {
            try append(.phaseChanged(.running)) { state in
                state.phase = .running
                state.pendingApprovalToken = nil
                state.latestSafeSummary = "Approved — continuing"
            }
            resumeWorkTimeout()
            return true
        } catch {
            stopAfterPersistenceFailure()
            return false
        }
    }

    @discardableResult
    private func beginStop(_ reason: StopReason) -> Bool {
        guard !isTerminal, !isStopping else { return true }
        isStopping = true
        discardPendingProgress()
        pauseWorkTimeout()
        approvalTimeoutTask?.cancel()
        let didPersistStopIntent: Bool
        do {
            try append(.phaseChanged(.interrupting)) { state in
                state.phase = .interrupting
                state.latestSafeSummary = "Stopping safely"
            }
            didPersistStopIntent = true
        } catch {
            // Still kill owned process tree, but retain mailbox command so a
            // durable ACK is never claimed for failed persistence.
            didPersistStopIntent = false
        }

        Task { [weak self] in
            guard let self else { return }
            let didStop = await self.process.terminateAndWait()
            self.isStopping = false
            guard didStop else {
                self.finishTerminal(
                    phase: .failed,
                    exitCode: nil,
                    summary: nil,
                    error: "Could not stop agent process tree"
                )
                return
            }

            switch reason {
            case .handedOff:
                self.finishTerminal(
                    phase: .cancelled,
                    exitCode: nil,
                    summary: "Handed off to Terminal",
                    error: nil,
                    handedOff: true
                )
            case .timedOut:
                self.finishTerminal(
                    phase: .failed,
                    exitCode: nil,
                    summary: nil,
                    error: "Timed out"
                )
            case .approvalTimedOut:
                self.finishTerminal(
                    phase: .failed,
                    exitCode: nil,
                    summary: nil,
                    error: "Approval timed out"
                )
            case .cancelled, .shutdown:
                self.finishTerminal(
                    phase: .cancelled,
                    exitCode: nil,
                    summary: "Cancelled",
                    error: nil
                )
            }
        }
        return didPersistStopIntent
    }

    private func resumeWorkTimeout() {
        guard !isTerminal, !isStopping, workTimeoutTask == nil else { return }
        guard workBudgetRemaining > .zero else {
            beginStop(.timedOut)
            return
        }
        let duration = workBudgetRemaining
        workSegmentStartedAt = workClock.now
        workTimeoutTask = Task { [weak self] in
            let clock = SuspendingClock()
            try? await clock.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.workTimeoutTask = nil
            self?.workSegmentStartedAt = nil
            self?.workBudgetRemaining = .zero
            self?.beginStop(.timedOut)
        }
    }

    private func pauseWorkTimeout() {
        workTimeoutTask?.cancel()
        workTimeoutTask = nil
        guard let startedAt = workSegmentStartedAt else { return }
        workSegmentStartedAt = nil
        let elapsed = startedAt.duration(to: workClock.now)
        workBudgetRemaining = elapsed < workBudgetRemaining
            ? workBudgetRemaining - elapsed
            : .zero
    }

    private func startHeartbeatLoop() {
        heartbeatTask = Task { [weak self] in
            let clock = SuspendingClock()
            while let self, !Task.isCancelled, !self.isTerminal {
                try? await clock.sleep(for: .seconds(5))
                guard !Task.isCancelled, !self.isTerminal else { return }
                self.state.lastHeartbeatAt = Date()
                self.state.updatedAt = Date()
                do {
                    try self.stateStore.save(self.state)
                } catch {
                    self.stopAfterPersistenceFailure()
                    return
                }
            }
        }
    }

    private func captureChildIdentity() {
        let processID = process.processIdentifier
        let searchPATH = request.spec.environmentOverrides["PATH"]
            ?? LoginShellExecutableResolver.loginPATH()
        let expectedPaths = DetachedAgentChildExecutable.expectedExecutablePaths(
            for: request.spec.executableURL,
            searchPATH: searchPATH
        )
        childIdentityTask = Task { [weak self] in
            let clock = SuspendingClock()
            for _ in 0..<100 {
                guard let self, !Task.isCancelled, !self.isTerminal else { return }
                if let identity = AgentProcessIdentityInspector.identity(for: processID),
                   expectedPaths.contains(
                       URL(fileURLWithPath: identity.executablePath).resolvingSymlinksInPath().path
                   ) {
                    self.state.childIdentity = identity
                    self.state.childProcessGroupID = processID
                    self.state.updatedAt = Date()
                    do {
                        try self.stateStore.save(self.state)
                    } catch {
                        self.stopAfterPersistenceFailure()
                    }
                    return
                }
                try? await clock.sleep(for: .milliseconds(10))
            }
            self?.stopAfterPersistenceFailure()
        }
    }

    private func finishAfterStartupFailure() {
        isStopping = true
        Task { [weak self] in
            guard let self else { return }
            _ = await self.process.terminateAndWait()
            self.isStopping = false
            self.finishTerminal(
                phase: .failed,
                exitCode: nil,
                summary: nil,
                error: "Could not start coding agent"
            )
        }
    }

    private func stopAfterPersistenceFailure() {
        guard !isTerminal, !isStopping else { return }
        isStopping = true
        Task { [weak self] in
            guard let self else { return }
            _ = await self.process.terminateAndWait()
            self.exitProcess(74)
        }
    }

    private func finishTerminal(
        phase: DetachedAgentRuntimePhase,
        exitCode: Int32?,
        summary: String?,
        error: String?,
        handedOff: Bool = false
    ) {
        guard !isTerminal else { return }
        flushPendingProgress()
        isTerminal = true
        pauseWorkTimeout()
        approvalTimeoutTask?.cancel()
        commandTask?.cancel()
        heartbeatTask?.cancel()
        childIdentityTask?.cancel()
        discardPendingProgress()
        pendingProviderApprovalID = nil

        do {
            let event: DetachedAgentRuntimeEvent = handedOff
                ? .handedOff
                : .finished(phase: phase, exitCode: exitCode, summary: summary ?? error)
            try append(event) { state in
                state.phase = phase
                state.pendingApprovalToken = nil
                state.terminalSafeSummary = summary
                state.terminalSafeError = error
                state.latestSafeSummary = summary ?? error
                state.handedOffToTerminal = handedOff
                state.exitCode = exitCode
            }
        } catch {
            exitProcess(74)
            return
        }

        if phase == .succeeded || phase == .failed {
            wakeMainApp()
        }
        exitProcess(phase == .failed ? 1 : 0)
    }

    private func append(
        _ event: DetachedAgentRuntimeEvent,
        mutate: (inout DetachedAgentDurableState) -> Void = { _ in }
    ) throws {
        mutate(&state)
        state.updatedAt = Date()
        let record = try journal.append(
            DetachedAgentEventEnvelope(
                runID: request.runID,
                attemptID: request.attemptID,
                event: event
            )
        )
        state.lastJournalSequence = record.sequence
        try stateStore.save(state)
    }

    private func discardPendingProgress() {
        progressFlushTask?.cancel()
        progressFlushTask = nil
        pendingProgressSummary = nil
    }
}

nonisolated enum DetachedAgentRunnerProgram {
    @MainActor private static var activeEngine: DetachedAgentRunnerEngine?

    static func run(invocation: DetachedAgentRunnerInvocation) -> Never {
        var coreLimit = rlimit(rlim_cur: 0, rlim_max: 0)
        _ = setrlimit(RLIMIT_CORE, &coreLimit)
        _ = signal(SIGPIPE, SIG_IGN)

        let handle = FileHandle(
            fileDescriptor: invocation.bootstrapFileDescriptor,
            closeOnDealloc: true
        )
        let request: DetachedAgentLaunchRequest
        do {
            request = try DetachedAgentLaunchRequest.read(
                from: handle,
                expectedRunID: invocation.runID,
                expectedAttemptID: invocation.attemptID
            )
            try handle.close()
        } catch {
            Darwin.exit(65)
        }

        Task { @MainActor in
            do {
                let engine = try DetachedAgentRunnerEngine(request: request)
                activeEngine = engine
                engine.start()
            } catch {
                Darwin.exit(70)
            }
        }
        dispatchMain()
    }
}

/// Paths a freshly spawned agent CLI may legitimately report as its own
/// executable. npm installs `codex` as `codex.js` with a `#!/usr/bin/env node`
/// shebang, so the kernel reports `node` (and briefly `env`), never the
/// script. Matching only the script path made every npm-installed CLI look
/// like a stranger and the runner quit before the agent could do anything.
nonisolated enum DetachedAgentChildExecutable {
    static func expectedExecutablePaths(
        for executableURL: URL,
        searchPATH: String,
        fileManager: FileManager = .default
    ) -> Set<String> {
        let scriptPath = executableURL.resolvingSymlinksInPath().path
        var paths: Set<String> = [scriptPath]
        guard let interpreter = shebangInterpreter(atPath: scriptPath) else { return paths }

        paths.insert(resolved(interpreter.path))
        if let program = interpreter.envProgram,
           let programPath = lookUp(program, searchPATH: searchPATH, fileManager: fileManager) {
            paths.insert(resolved(programPath))
        }
        return paths
    }

    /// The interpreter from a `#!` line. For `/usr/bin/env [-S] [flags] prog`
    /// `envProgram` is `prog`, which env then execs in place.
    static func shebangInterpreter(atPath path: String) -> (path: String, envProgram: String?)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256),
              head.starts(with: Array("#!".utf8)),
              let text = String(data: head.dropFirst(2), encoding: .utf8),
              let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first else {
            return nil
        }
        let tokens = firstLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let interpreterPath = tokens.first, interpreterPath.hasPrefix("/") else { return nil }
        guard URL(fileURLWithPath: interpreterPath).lastPathComponent == "env" else {
            return (interpreterPath, nil)
        }
        let program = tokens.dropFirst().first { !$0.hasPrefix("-") && !$0.contains("=") }
        return (interpreterPath, program)
    }

    private static func lookUp(_ program: String, searchPATH: String, fileManager: FileManager) -> String? {
        if program.hasPrefix("/") {
            return fileManager.isExecutableFile(atPath: program) ? program : nil
        }
        for directory in searchPATH.split(separator: ":") where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(program, isDirectory: false).path
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
