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
    private let rootDirectoryURL: URL
    private var process = HeadlessCLIProcess()
    private let adapter: HeadlessCLIAdapter
    private let journal: DetachedAgentRuntimeJournal
    private let stateStore: DetachedAgentDurableStateStore
    private let commandMailbox: DetachedAgentCommandMailbox
    private let workClock = SuspendingClock()
    private let exitProcess: (Int32) -> Void
    private let wakeMainApp: () -> Void

    private var state: DetachedAgentDurableState
    private var finalResult = AgentFinalResult()
    private var providerFailureMessage: String?
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
    private var codexConnection: CodexAppServerConnection?
    private var codexExecution: CodexAppServerExecutionSession?
    private var codexStartTask: Task<Void, Never>?
    private var codexCompleting = false
    private var codexTurnToken: UUID?
    private var liveInputTasks: [UUID: Task<Void, Never>] = [:]
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
        self.rootDirectoryURL = rootDirectoryURL
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
            if let launch = request.codexExecution, request.executor == .codex {
                startCommandLoop()
                startHeartbeatLoop()
                resumeWorkTimeout()
                startCodexExecution(launch)
                return
            }
            try process.start(
                executableURL: request.spec.executableURL,
                arguments: request.spec.arguments,
                currentDirectoryURL: request.spec.currentDirectoryURL,
                environmentKeysToRemove: request.spec.environmentKeysToRemove,
                environmentOverrides: request.spec.environmentOverrides,
                temporaryDirectoriesToRemove: request.spec.temporaryDirectoriesToRemove,
                usesDuplexStandardInput: request.spec.usesDuplexStandardInput,
                initialStandardInput: request.spec.initialStandardInput,
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

    private func startCodexExecution(_ launch: CodexExecutionLaunch) {
        codexStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                let probe = CodexAppServerConnection()
                self.codexConnection = probe
                probe.onProcessStarted = { [weak self] in self?.captureChildIdentity() }
                try await probe.launch(executableURL: self.request.spec.executableURL,
                    workspaceURL: self.request.spec.currentDirectoryURL, process: self.process,
                    arguments: CodexPlanningIsolation.arguments,
                    environmentKeysToRemove: self.request.spec.environmentKeysToRemove,
                    environmentOverrides: self.request.spec.environmentOverrides)
                let config = try await probe.request(method: "config/read", params: .object([
                    "includeLayers": .bool(false), "cwd": .string(self.request.spec.currentDirectoryURL.path)
                ]))
                let arguments = try CodexExecutionIsolation.arguments(probe: config, mcpArguments: launch.mcpArguments)
                guard await probe.shutdown() else { throw CodexPlanningIsolation.Failure.unsafeConfiguration }
                try Task.checkCancellation()
                guard !self.isTerminal, !self.isStopping else { return }
                self.childIdentityTask?.cancel()
                self.process = HeadlessCLIProcess()
                let connection = CodexAppServerConnection()
                self.codexConnection = connection
                connection.onProcessStarted = { [weak self] in self?.captureChildIdentity() }
                try await connection.launch(executableURL: self.request.spec.executableURL,
                    workspaceURL: self.request.spec.currentDirectoryURL, process: self.process, arguments: arguments,
                    environmentKeysToRemove: self.request.spec.environmentKeysToRemove,
                    environmentOverrides: self.request.spec.environmentOverrides)
                let finalConfig = try await connection.request(method: "config/read", params: .object([
                    "includeLayers": .bool(false), "cwd": .string(self.request.spec.currentDirectoryURL.path)
                ]))
                try CodexExecutionIsolation.validate(finalConfig, mcpArguments: launch.mcpArguments)
                try Task.checkCancellation()
                guard !self.isTerminal, !self.isStopping else { return }
                let execution = CodexAppServerExecutionSession(connection: connection)
                self.codexExecution = execution
                execution.onProgress = { [weak self] summary in
                    self?.finalResult.consume(.tool(summary: summary))
                    self?.recordProgress(summary)
                }
                execution.onApproval = { [weak self] approval in
                    guard let self, !self.codexCompleting, !self.isStopping, !self.isTerminal else { return }
                    self.beginApprovalWait(providerID: approval.localID, details: approval.details)
                }
                execution.onApprovalCleared = { [weak self] id in self?.clearCodexApproval(id) }
                execution.onOutcome = { [weak self] outcome in self?.finishCodexExecution(outcome) }
                _ = try await execution.start(launch: launch, workspace: self.request.spec.currentDirectoryURL)
                try Task.checkCancellation()
                guard !self.isTerminal, !self.isStopping, !self.codexCompleting else { return }
                self.codexTurnToken = UUID()
                if self.state.phase != .waitingForApproval {
                    try self.append(.phaseChanged(.running)) { state in
                        state.phase = .running
                        state.liveSteeringToken = self.codexTurnToken
                        state.latestSafeSummary = "Working"
                    }
                }
            } catch {
                guard !self.isTerminal, !self.isStopping, !self.codexCompleting else { return }
                self.providerFailureMessage = "Could not start isolated Codex execution. " + error.localizedDescription
                self.finalResult.consume(.failed(message: "Could not start isolated Codex execution."))
                self.codexCompleting = true
                let stopped = await self.process.terminateAndWait()
                guard !self.isTerminal, !self.isStopping else { return }
                guard stopped else { self.stopAfterPersistenceFailure(); return }
                self.handleProcessExit(status: 1)
            }
        }
    }

    private func clearCodexApproval(_ id: String) {
        guard !isTerminal, !isStopping, !codexCompleting, pendingProviderApprovalID == id else { return }
        pendingProviderApprovalID = nil
        approvalTimeoutTask?.cancel()
        do {
            try append(.phaseChanged(.running)) { state in
                state.phase = .running
                state.pendingApprovalToken = nil
                state.liveSteeringToken = self.codexTurnToken
                state.latestSafeSummary = "Approval request cleared — continuing"
            }
            resumeWorkTimeout()
        } catch { stopAfterPersistenceFailure() }
    }

    private func acceptLiveInput(_ command: DetachedAgentRuntimeCommand, messageID: UUID) -> Bool {
        if state.liveInputReceipts?.contains(where: { $0.messageID == messageID }) == true { return true }
        guard let token = command.liveSteeringToken else { return true }
        guard (state.liveInputReceipts?.count ?? 0) < 256 else { return false }
        let validText = command.text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 65_536 } ?? false
        let available = validText && !isStopping && !codexCompleting && state.phase == .running
            && token == state.liveSteeringToken && codexExecution?.identity != nil
        let receipt = DetachedLiveInputReceipt(messageID: messageID, turnToken: token,
                                               status: !validText ? .rejected : (available ? .sending : .unavailable))
        state.liveInputReceipts = (state.liveInputReceipts ?? []) + [receipt]
        do { try stateStore.save(state) } catch { stopAfterPersistenceFailure(); return false }
        guard available, let execution = codexExecution, let identity = execution.identity,
              let text = command.text else { return true }
        liveInputTasks[messageID] = Task { [weak self] in
            let result = await execution.steer(text: text, expectedTurnID: identity.turnID, messageID: messageID)
            guard let self, !self.isTerminal else { return }
            if let index = self.state.liveInputReceipts?.firstIndex(where: { $0.messageID == messageID }) {
                self.state.liveInputReceipts?[index].status = result
            }
            do { try self.stateStore.save(self.state) } catch { self.stopAfterPersistenceFailure() }
            self.liveInputTasks[messageID] = nil
        }
        return true
    }

    private func finishCodexExecution(_ outcome: CodexAppServerExecutionSession.Outcome) {
        guard !isTerminal, !isStopping, !codexCompleting else { return }
        codexCompleting = true
        state.liveSteeringToken = nil
        pauseWorkTimeout()
        approvalTimeoutTask?.cancel()
        do { try stateStore.save(state) } catch { stopAfterPersistenceFailure(); return }
        Task { [weak self] in
            guard let self else { return }
            // Late acknowledgements may follow turn/completed. Keep reading the
            // connection until every already-dispatched request settles.
            let pending = Array(self.liveInputTasks.values)
            for task in pending { await task.value }
            guard !self.isTerminal, !self.isStopping else { return }
            do { _ = try self.commandMailbox.drain { self.accept($0.command, messageID: $0.messageID) } }
            catch { self.stopAfterPersistenceFailure(); return }
            guard await self.codexConnection?.shutdown() == true else {
                self.stopAfterPersistenceFailure(); return
            }
            guard !self.isTerminal, !self.isStopping else { return }
            switch outcome {
            case .completed(let answer):
                self.finalResult.consume(.text(answer))
                self.handleProcessExit(status: 0)
            case .failed(let message):
                self.providerFailureMessage = message
                self.finalResult.consume(.failed(message: message))
                self.handleProcessExit(status: 1)
            case .interrupted:
                self.finishTerminal(phase: .cancelled, exitCode: nil, summary: "Interrupted", error: nil)
            }
        }
    }

    private func handleStandardOutputLine(_ line: String) {
        guard !isTerminal, !isStopping else { return }

        for event in adapter.events(fromStdoutLine: line) {
            finalResult.consume(event)
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
                // Only the final, bounded/redacted result projection is
                // retained by finalResult. Raw commentary is never persisted.
                continue
            case .planReady:
                // Initial rollout detaches write-enabled execute legs only.
                recordProgress("Runner received an unsupported plan event")
            case .approvalRequested(let providerID, let details):
                beginApprovalWait(providerID: providerID, details: details)
            case .failed(let message):
                let safe = AgentReceiptPrivacy.privateAnswer(message)
                if !safe.isEmpty { providerFailureMessage = safe }
            case .finished:
                // A stream-json result ends this one approved turn. Closing
                // input lets Claude exit normally so exit status still gates
                // durable success; killing it here would lose that proof.
                if request.executor == .claudeCode { process.closeStandardInput() }
            }
        }
    }

    private func handleProcessExit(status: Int32) {
        guard !isTerminal, !isStopping else { return }
        pauseWorkTimeout()
        approvalTimeoutTask?.cancel()

        if status != 0 || finalResult.outcome == .failed {
            // Failure prose belongs in the private result artifact, never in
            // the metadata journal. Preserve the actual provider/stderr cause.
            let headline = status == 0 ? "Coding agent reported an error" : "Coding agent exited with status \(status)"
            let details = [providerFailureMessage, process.recentStandardErrorSummary]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let report = headline + "\n\n" + (details.isEmpty
                ? "The coding agent supplied no additional error details. No completed result is available."
                : details.joined(separator: "\n\n"))
            try? AgentPrivateResultStore.save(report, root: rootDirectoryURL,
                                             runID: request.runID, attemptID: request.attemptID)
        }
        if finalResult.outcome == .failed {
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
        switch finalResult.outcome {
        case .blocked(let reason):
            try? AgentPrivateResultStore.save(reason, root: rootDirectoryURL, runID: request.runID, attemptID: request.attemptID)
            finishTerminal(
                phase: .failed,
                exitCode: status,
                summary: nil,
                error: AgentFinalResult.blockedSummary
            )
        case .reported(let answer):
            do {
                try AgentPrivateResultStore.save(answer, root: rootDirectoryURL, runID: request.runID, attemptID: request.attemptID)
                finishTerminal(phase: .succeeded, exitCode: 0, summary: AgentFinalResult.availableSummary, error: nil)
            } catch {
                // The work may have succeeded even if saving its answer failed.
                finishTerminal(phase: .succeeded, exitCode: 0, summary: AgentFinalResult.missingMessage, error: nil)
            }
        case .missing, .failed:
            // A missing answer is a delivery limitation, not evidence the
            // work failed. Keep process success, with an explicit unknown outcome.
            finishTerminal(phase: .succeeded, exitCode: 0,
                           summary: AgentFinalResult.missingMessage, error: nil)
        }
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

    private func beginApprovalWait(providerID: String, details: String? = nil) {
        guard pendingProviderApprovalID == nil else { return }
        discardPendingProgress()
        pauseWorkTimeout()
        let token = DetachedAgentApprovalToken()
        pendingProviderApprovalID = providerID
        do {
            if let details {
                try AgentPrivateApprovalStore.save(details, root: rootDirectoryURL, runID: request.runID,
                                                   attemptID: request.attemptID, token: token.rawValue)
            }
            let safeSummary = "Agent needs approval"
            try append(.approvalRequested(token: token, summary: safeSummary)) { state in
                state.phase = .waitingForApproval
                state.liveSteeringToken = nil
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
                        self.accept(envelope.command, messageID: envelope.messageID)
                    }
                } catch {
                    self.stopAfterPersistenceFailure()
                    return
                }
                try? await clock.sleep(for: .milliseconds(250))
            }
        }
    }

    private func accept(_ command: DetachedAgentRuntimeCommand, messageID: UUID = UUID()) -> Bool {
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
            guard command.liveSteeringToken != nil else { return true }
            return acceptLiveInput(command, messageID: messageID)
        }
    }

    private func resolveApproval(_ command: DetachedAgentRuntimeCommand) -> Bool {
        guard state.phase == .waitingForApproval,
              let expectedToken = state.pendingApprovalToken,
              command.approvalToken == expectedToken,
              let decision = command.approvalDecision,
              let providerID = pendingProviderApprovalID else { return true }

        if let execution = codexExecution {
            guard execution.resolveApproval(localID: providerID, approve: decision == .approve) else { return false }
            approvalTimeoutTask?.cancel()
            pendingProviderApprovalID = nil
            if decision == .deny { return beginStop(.cancelled) }
            do {
                try append(.phaseChanged(.running)) { state in
                    state.phase = .running
                    state.pendingApprovalToken = nil
                    state.liveSteeringToken = self.codexCompleting ? nil : self.codexTurnToken
                    state.latestSafeSummary = "Approved — continuing"
                }
                resumeWorkTimeout()
                execution.presentNextApproval()
                return true
            } catch { stopAfterPersistenceFailure(); return false }
        }

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
        codexStartTask?.cancel()
        discardPendingProgress()
        pauseWorkTimeout()
        approvalTimeoutTask?.cancel()
        let didPersistStopIntent: Bool
        do {
            try append(.phaseChanged(.interrupting)) { state in
                state.phase = .interrupting
                state.liveSteeringToken = nil
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
            await self.codexExecution?.interrupt()
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
        codexStartTask?.cancel()
        // A process/connection loss leaves in-flight sends uncertain, never safe
        // to replay. Preserve definitive receipts already persisted.
        state.liveInputReceipts = state.liveInputReceipts?.map {
            var receipt = $0
            if receipt.status == .sending { receipt.status = .unknown }
            return receipt
        }

        do {
            let event: DetachedAgentRuntimeEvent = handedOff
                ? .handedOff
                : .finished(phase: phase, exitCode: exitCode, summary: summary ?? error)
            try append(event) { state in
                state.phase = phase
                state.liveSteeringToken = nil
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
        if let interpreter = shebangInterpreter(atPath: scriptPath) {
            paths.insert(resolved(interpreter.path))
            if let program = interpreter.envProgram,
               let programPath = lookUp(program, searchPATH: searchPATH, fileManager: fileManager) {
                paths.insert(resolved(programPath))
            }
        }
        // macOS /bin/sh is an executable dispatcher, not a symlink. After
        // exec, proc_pidpath reports the selected backend instead of sh.
        // Only the system selector and its fixed system backends qualify.
        if let backend = selectedSystemShellBackend(
            expectedPaths: paths,
            selection: try? fileManager.destinationOfSymbolicLink(atPath: "/private/var/select/sh")
        ), fileManager.isExecutableFile(atPath: backend) {
            paths.insert(backend)
        }
        return paths
    }

    static func selectedSystemShellBackend(expectedPaths: Set<String>, selection: String?) -> String? {
        guard expectedPaths.contains("/bin/sh"), let selection,
              ["/bin/bash", "/bin/dash", "/bin/zsh"].contains(selection) else { return nil }
        return selection
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
