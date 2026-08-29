//
//  HeadlessAgentLauncher.swift
//  leanring-buddy
//
//  Owns folder creation, TASK.md, process spawn, timeout, and cancel, plus
//  the two-leg approval gate: leg one plans with writes turned off, the user
//  approves, leg two resumes the same CLI session and does the work.
//  CompanionManager only decides *when* to start a job and how to reflect
//  it in CompanionState — it never talks to Process directly.
//

import Darwin
import Foundation

@MainActor
final class HeadlessAgentLauncher {

    private struct LiveSession {
        let process: HeadlessCLIProcess
        let adapter: HeadlessCLIAdapter
        let leg: AgentRunLeg
        var timeoutTask: Task<Void, Never>?
        /// Assistant prose from a read-only leg. This is the plan the user
        /// will be asked to approve, so it is collected rather than
        /// overwritten the way `summary` is.
        var planFragments: [String] = []
    }

    private enum PendingStopReason {
        case cancellation
        case timeout(standardErrorSummary: String)

        var stoppingAction: String {
            switch self {
            case .cancellation:
                return "Stopping safely…"
            case .timeout:
                return "Timed out — stopping safely…"
            }
        }

        var couldNotStopAction: String {
            switch self {
            case .cancellation:
                return "Couldn't stop the agent process — try again."
            case .timeout:
                return "Timed out, but the agent process did not stop. Try Cancel again."
            }
        }
    }

    private struct PendingStop {
        let identifier: UUID
        let process: HeadlessCLIProcess
        let leg: AgentRunLeg
        let reason: PendingStopReason
    }

    private let store: FileAgentRunStore
    private let undoLedger: FileAgentUndoLedger
    private let fileManager: FileManager
    private var sessions: [UUID: LiveSession] = [:]
    private var pendingStops: [UUID: PendingStop] = [:]
    private var receiptScansInFlight: Set<UUID> = []

    /// Write-enabled legs run in a signed embedded command-line helper.
    /// Planning, replanning, and follow-ups remain short, read-only child
    /// processes owned by the app so session selection stays unchanged.
    var detachedExecutionEnabled = true
    var detachedRuntimeRootURL = DetachedAgentRuntimePaths.defaultRootURL
    var detachedRunnerExecutableURL: () -> URL? = {
        DetachedAgentRunnerExecutable.bundledURL()
    }
    var spawnDetachedRunner: (URL, DetachedAgentLaunchRequest) throws -> Int32 = {
        try DetachedAgentRunnerBootstrap.spawn(executableURL: $0, request: $1)
    }
    var inspectProcessIdentity: (Int32) -> AgentProcessIdentity? = {
        AgentProcessIdentityInspector.identity(for: $0)
    }
    var matchesLiveProcessIdentity: (AgentProcessIdentity) -> Bool = {
        AgentProcessIdentityInspector.matchesLiveProcess($0)
    }
    var matchesLiveChildProcessGroup: (AgentProcessIdentity, Int32) -> Bool = {
        AgentProcessIdentityInspector.matchesLiveProcessGroup(leader: $0, processGroupID: $1)
    }
    /// Read-only, conservative group check. Safe for deciding whether to keep
    /// quit/undo blocked after leader exit; never authorizes a signal.
    var detachedProcessGroupExists: (Int32) -> Bool = { processGroupID in
        guard processGroupID > 1, processGroupID != getpgrp() else { return false }
        return kill(-processGroupID, 0) == 0 || errno == EPERM
    }
    var detachedMonitorInterval: Duration = .milliseconds(250)
    var detachedCleanupGracePeriod: TimeInterval = 3
    var detachedPersistenceRecoveryGracePeriod: TimeInterval = 8
    var detachedCurrentDate: () -> Date = { Date() }

    private var detachedMonitorTasks: [UUID: Task<Void, Never>] = [:]
    private var detachedExpectedRunnerPIDs: [UUID: Int32] = [:]
    private var detachedExpectedRunnerIdentities: [UUID: AgentProcessIdentity] = [:]
    private var detachedJournalByteCounts: [UUID: UInt64] = [:]
    private var detachedSafetyHoldStartedAt: [UUID: Date] = [:]
    private var pendingDetachedRunIDs: Set<UUID> = []
    private var verifiedDetachedRunIDs: Set<UUID> = []

    /// Fired after every store mutation so the Agents tab can republish.
    var onRunsChanged: (() -> Void)?

    /// Foreground companion-state hook (agentStarted / planReady / finished).
    var onEvent: ((UUID, AgentEvent) -> Void)?

    /// Fired when a snapshot becomes undoable or is restored.
    var onUndoLedgerChanged: (() -> Void)?

    /// Tests replace this so unit tests never spawn a real `opencode`/`claude`.
    var resolveExecutable: (String) -> URL? = { LoginShellExecutableResolver.resolveExecutable(named: $0) }

    /// Last known sign-in state per executor, supplied by `CompanionManager`
    /// from a cache it refreshes off the main actor. Reading a cached value
    /// keeps the spawn path from blocking on a probe; the default is
    /// deliberately permissive so an unrefreshed cache never blocks a job.
    var readinessForExecutor: (HeadlessExecutor) -> HeadlessExecutorReadiness = { _ in .indeterminate() }

    /// `provider/model` for OpenCode jobs, from the model picked in Settings.
    var openCodeModelIdentifier: () -> String? = { nil }

    /// `--model` / `-m` for Claude and Codex jobs.
    var claudeModelIdentifier: () -> String? = { nil }
    var codexModelIdentifier: () -> String? = { nil }
    var codexReasoningEffort: () -> String? = { nil }

    /// Injectable so timeout lifecycle tests use milliseconds rather than the
    /// production five- and fifteen-minute limits.
    var runtimeLimitForLeg: (AgentRunLeg) -> TimeInterval = { leg in
        leg.isReadOnly
            ? HeadlessCLIProcess.maximumPlanningRuntime
            : HeadlessCLIProcess.maximumRuntime
    }

    /// Injectable independently from the duration so timeout tests can fire
    /// only after their process fixture is fully running.
    var waitForRuntimeLimit: (TimeInterval) async -> Void = { runtimeLimit in
        // `SuspendingClock` stops while Mac sleeps. A wall/continuous deadline
        // makes an overnight sleep look like a hung agent and kills healthy
        // work immediately after wake.
        let clock = SuspendingClock()
        try? await clock.sleep(for: .seconds(runtimeLimit))
    }

    /// Inline MCP config giving a working leg HeyMate's own tools. Resolved
    /// per spawn because it depends on the bridge port and on a script that is
    /// seeded lazily; nil is a normal answer and simply means no HeyMate tools.
    var openCodeMCPConfigurationJSON: () -> String? = { nil }
    var codexMCPConfigurationArguments: () -> [String] = { [] }
    var mcpChildEnvironment: (HeadlessExecutor) -> [String: String] = { _ in [:] }

    init(
        store: FileAgentRunStore,
        undoLedger: FileAgentUndoLedger,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.undoLedger = undoLedger
        self.fileManager = fileManager
    }

    /// Number of jobs that make normal Cmd-Q unsafe. A detached execute leg is
    /// exempt only while its persisted full process identity still matches the
    /// live runner. Launch races, corrupt state, planning legs, and legacy
    /// in-process work all continue to block quit.
    var terminationBlockingRunCount: Int {
        store.runningRuns().count { run in
            guard run.status != .awaitingPlanApproval else { return false }
            return !detachedRunCanSurviveAppTermination(run)
        }
    }

    /// Reattaches durable execute attempts before legacy interruption cleanup.
    /// Terminal state can be imported after its runner exits; nonterminal state
    /// is trusted only after PID-reuse-resistant identity verification.
    func recoverPersistedRuns() {
        var liveDetachedRunIDs = Set<UUID>()

        for run in store.runningRuns() where run.detachedAttemptID != nil {
            switch refreshDetachedRun(runID: run.id, allowMissingStateWhileSpawned: false) {
            case .activeVerified:
                liveDetachedRunIDs.insert(run.id)
                beginDetachedMonitoring(runID: run.id)
                onEvent?(run.id, .started)
                if store.run(id: run.id)?.status == .waitingForApproval,
                   let refreshedRun = store.run(id: run.id) {
                    onEvent?(
                        run.id,
                        .approvalRequested(
                            id: refreshedRun.pendingApprovalID,
                            summary: refreshedRun.latestAction
                        )
                    )
                }
            case .pending:
                // Runner may have crashed while its lifetime monitor is still
                // terminating the verified child process group. Keep snapshot
                // prepared and Cmd-Q blocked until that group is gone.
                liveDetachedRunIDs.insert(run.id)
                beginDetachedMonitoring(runID: run.id)
            case .terminal, .failed:
                break
            }
        }

        _ = store.reconcileInterruptedRuns(excludingRunIDs: liveDetachedRunIDs)
        undoLedger.recoverInterruptedPreparedEntries(excludingRunIDs: liveDetachedRunIDs)
        onRunsChanged?()
        onUndoLedgerChanged?()
    }

    // MARK: - Starting a job (leg one)

    func startSandbox(
        prompt: String,
        executor: HeadlessExecutor,
        screenContext: AgentScreenContext,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> UUID {
        let runID = UUID()
        let workspaceURL = AgentFolderNaming.sandboxFolderURL(
            prompt: prompt,
            uuid: runID,
            homeDirectoryURL: homeDirectoryURL
        )
        return beginRun(
            runID: runID,
            prompt: prompt,
            executor: executor,
            origin: .sandbox,
            workspaceURL: workspaceURL,
            screenContext: screenContext,
            createWorkspace: true
        )
    }

    func startAttached(
        prompt: String,
        executor: HeadlessExecutor,
        workspaceURL: URL,
        screenContext: AgentScreenContext
    ) -> UUID {
        beginRun(
            runID: UUID(),
            prompt: prompt,
            executor: executor,
            origin: .attached,
            workspaceURL: workspaceURL,
            screenContext: screenContext,
            createWorkspace: false
        )
    }

    // MARK: - The gate

    /// The user read the plan and said yes. Leg two resumes the same session
    /// with writes enabled.
    func approvePlan(runID: UUID) {
        guard let run = store.run(id: runID), run.status == .awaitingPlanApproval else { return }

        guard !run.sessionIdentifier.isEmpty else {
            // Without a session there is nothing to resume, and re-prompting
            // from scratch would execute work the user never read.
            apply(
                .failed(message: "Lost the planning session — start this job again."),
                to: runID
            )
            return
        }

        // Approval means write permission. Snapshot must finish first; if it
        // cannot, work stays stopped and plan remains available to retry.
        let undoEntry: AgentUndoEntry
        do {
            undoEntry = try undoLedger.prepareSnapshot(for: run)
        } catch {
            _ = store.update(id: runID) { current in
                current.latestAction = "Could not prepare undo"
                current.error = error.localizedDescription
            }
            onRunsChanged?()
            return
        }

        do {
            guard try store.updateDurably(id: runID, mutate: { current in
                current.undoEntryIdentifier = undoEntry.id.uuidString
                current.workspaceChangeSummary = nil
                current.status = .running
                current.latestAction = "Approved — starting work"
                current.error = ""
                current.appendActivity(kind: .user, text: "Approved plan")
                current.appendActivity(kind: .status, text: current.latestAction)
            }) != nil else {
                try? undoLedger.discardPrepared(entryID: undoEntry.id)
                return
            }
        } catch {
            try? undoLedger.discardPrepared(entryID: undoEntry.id)
            _ = store.update(id: runID) { current in
                current.latestAction = "Could not save the approved job safely"
                current.error = error.localizedDescription
            }
            onRunsChanged?()
            return
        }
        onRunsChanged?()
        spawn(runID: runID, leg: .execute)
    }

    /// The user pushed back. The session is kept so the model re-plans knowing
    /// what it got wrong, rather than starting from a blank slate.
    func requestReplan(runID: UUID, feedback: String) {
        let trimmedFeedback = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let run = store.run(id: runID),
              run.status == .awaitingPlanApproval,
              !trimmedFeedback.isEmpty,
              !run.sessionIdentifier.isEmpty else { return }

        _ = store.update(id: runID) { current in
            current.status = .planning
            current.planText = ""
            current.latestAction = "Revising the plan…"
            current.error = ""
            current.appendActivity(kind: .user, text: trimmedFeedback)
            current.appendActivity(kind: .status, text: current.latestAction)
        }
        onRunsChanged?()
        spawn(runID: runID, leg: .replan(feedback: trimmedFeedback))
    }

    /// "Also make it dark mode." More work stays in the same CLI session. If
    /// the agent is busy, the instruction waits for the current write leg to
    /// finish; a one-shot CLI process cannot safely accept a new turn midway.
    ///
    /// Returns false when the job cannot be continued, which the caller shows
    /// rather than silently starting a fresh, context-free job.
    @discardableResult
    func sendFollowUp(runID: UUID, instruction: String) -> Bool {
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let run = store.run(id: runID),
              !trimmedInstruction.isEmpty,
              !run.status.isTerminal || !run.sessionIdentifier.isEmpty else { return false }

        guard run.status.isTerminal else {
            if AgentFollowUpIntent.classify(trimmedInstruction) == .statusQuestion {
                _ = store.update(id: runID) { current in
                    current.appendActivity(kind: .user, text: trimmedInstruction)
                    current.appendActivity(kind: .agent, text: Self.liveStatusReply(for: current))
                }
                onRunsChanged?()
                return true
            }

            _ = store.update(id: runID) { current in
                current.queuedFollowUpInstructions.append(trimmedInstruction)
                current.appendActivity(kind: .user, text: trimmedInstruction)
                current.appendActivity(
                    kind: .status,
                    text: "Follow-up queued for after the current step"
                )
            }
            onRunsChanged?()
            return true
        }

        _ = store.update(id: runID) { current in
            current.status = .planning
            current.planText = ""
            current.summary = ""
            current.error = ""
            current.finishedAt = nil
            current.undoEntryIdentifier = ""
            current.workspaceChangeSummary = nil
            current.detachedAttemptIdentifier = ""
            current.lastDetachedJournalSequence = 0
            current.latestAction = "Planning the follow-up…"
            current.appendActivity(kind: .user, text: trimmedInstruction)
            current.appendActivity(kind: .status, text: current.latestAction)
        }
        onRunsChanged?()
        spawn(runID: runID, leg: .followUp(instruction: trimmedInstruction))
        return true
    }

    private static func liveStatusReply(for run: AgentRun, now: Date = Date()) -> String {
        let statusLead: String
        switch run.status {
        case .queued: statusLead = "Queued — waiting to start."
        case .planning: statusLead = "Still planning."
        case .awaitingPlanApproval: statusLead = "Plan ready — waiting for your approval."
        case .running: statusLead = "Still working."
        case .waitingForApproval: statusLead = "Paused — waiting for your approval."
        case .succeeded: statusLead = "Done."
        case .failed: statusLead = "Stopped with an error."
        case .cancelled: statusLead = "Cancelled."
        }

        let currentStep = run.latestAction.trimmingCharacters(in: .whitespacesAndNewlines)
        let stepSentence = currentStep.isEmpty ? "" : " Current step: \(currentStep)."
        guard let startedAt = run.startedAt, !run.status.isTerminal else {
            return statusLead + stepSentence
        }

        let elapsedMinutes = max(0, Int(now.timeIntervalSince(startedAt) / 60))
        let elapsedSentence = elapsedMinutes < 1
            ? " Running for under a minute."
            : " Running for \(elapsedMinutes) minute\(elapsedMinutes == 1 ? "" : "s")."
        return statusLead + stepSentence + elapsedSentence
    }

    /// Busy jobs accept queued turns. Finished jobs need a captured session so
    /// the next turn does not silently start a context-free agent.
    func canSendFollowUp(runID: UUID) -> Bool {
        guard let run = store.run(id: runID) else { return false }
        return !run.status.isTerminal || !run.sessionIdentifier.isEmpty
    }

    /// The user does not want this job at all. Nothing was written, so there
    /// is nothing to undo.
    func dismissPlan(runID: UUID) {
        guard let run = store.run(id: runID), run.status == .awaitingPlanApproval else { return }
        _ = store.update(id: runID) { current in
            current.status = .cancelled
            current.latestAction = "Dismissed before any work started"
            current.finishedAt = Date()
            current.pid = nil
            current.appendActivity(kind: .status, text: current.latestAction)
        }
        onRunsChanged?()
        onEvent?(runID, .finished(summary: "Dismissed"))
    }

    // MARK: - Running jobs

    func cancel(runID: UUID) {
        guard let run = store.run(id: runID), !run.status.isTerminal else { return }

        if run.detachedAttemptID != nil, sessions[runID] == nil {
            guard enqueueDetachedCommand(runID: runID, command: .cancel) else {
                _ = refreshDetachedRun(runID: runID, allowMissingStateWhileSpawned: true)
                return
            }
            _ = store.update(id: runID) { current in
                current.latestAction = "Stopping safely…"
                current.appendActivity(kind: .status, text: current.latestAction)
            }
            onRunsChanged?()
            return
        }

        guard pendingStops[runID] == nil else { return }

        guard let liveSession = sessions[runID] else {
            // Plan approval and pre-spawn queued states have no process tree.
            // A persisted PID without a live owned session is not safe to
            // signal, and must stay non-terminal for startup reconciliation.
            guard run.pid == nil else { return }
            finishCancellation(runID: runID)
            return
        }

        beginStop(
            runID: runID,
            liveSession: liveSession,
            reason: .cancellation
        )
    }

    private func finishCancellation(runID: UUID) {
        _ = store.update(id: runID) { current in
            guard !current.status.isTerminal else { return }
            current.status = .cancelled
            current.latestAction = "Cancelled"
            current.finishedAt = Date()
            current.pid = nil
            current.pendingApprovalID = ""
            current.error = ""
            if !current.queuedFollowUpInstructions.isEmpty {
                current.queuedFollowUpInstructions.removeAll()
                current.appendActivity(kind: .status, text: "Queued follow-ups discarded")
            }
            current.appendActivity(kind: .status, text: current.latestAction)
        }
        onRunsChanged?()
        onEvent?(runID, .finished(summary: "Cancelled"))
    }

    /// Hand a job to the user in a real terminal.
    ///
    /// HeyMate's own process is stopped first. Two clients on one CLI session
    /// race over the same transcript, and the losing turn is the one nobody
    /// can see — so a takeover is a handover, not a second driver. The run
    /// stays in the list with its transcript intact; it is simply no longer
    /// HeyMate's to continue.
    ///
    /// Returns the command that was handed to Terminal so the caller can show
    /// it, or the reason there was nothing to hand over.
    @discardableResult
    func beginTerminalTakeover(runID: UUID) async -> Result<String, AgentTerminalTakeover.Unavailability> {
        guard let run = store.run(id: runID) else { return .failure(.runNotFound) }
        guard pendingStops[runID] == nil else { return .failure(.processWouldNotStop) }
        guard let command = AgentTerminalTakeover.shellCommand(for: run) else {
            return .failure(.sessionNotStartedYet)
        }

        if !run.status.isTerminal,
           run.detachedAttemptID != nil,
           sessions[runID] == nil {
            guard enqueueDetachedCommand(runID: runID, command: .takeOverInTerminal) else {
                _ = refreshDetachedRun(runID: runID, allowMissingStateWhileSpawned: true)
                return .failure(.processWouldNotStop)
            }
            _ = store.update(id: runID) { current in
                current.latestAction = "Stopping safely before Terminal handoff…"
                current.appendActivity(kind: .status, text: current.latestAction)
            }
            onRunsChanged?()

            guard await waitForDetachedTerminalHandoff(runID: runID) else {
                return .failure(.processWouldNotStop)
            }
            return .success(command)
        }

        // A job that already finished has no process to stop — its session is
        // just as resumable, so the handover is only the store update.
        if !run.status.isTerminal {
            _ = store.update(id: runID) { current in
                current.latestAction = "Stopping safely before Terminal handoff…"
                current.appendActivity(kind: .status, text: current.latestAction)
            }
            onRunsChanged?()

            // Remove callback ownership before waiting. Otherwise the SIGTERM
            // exit callback marks the run failed while takeover is still in
            // progress and emits a false failure notification.
            if let liveSession = sessions.removeValue(forKey: runID) {
                liveSession.timeoutTask?.cancel()
                guard await liveSession.process.terminateAndWait() else {
                    _ = store.update(id: runID) { current in
                        current.status = .failed
                        current.latestAction = AgentTerminalTakeover.Unavailability
                            .processWouldNotStop.explanation
                        current.error = current.latestAction
                        current.finishedAt = Date()
                        current.appendActivity(kind: .status, text: current.latestAction)
                    }
                    onRunsChanged?()
                    return .failure(.processWouldNotStop)
                }
                if !liveSession.leg.isReadOnly {
                    markUndoReady(runID: runID)
                    scheduleReceiptScanForRun(runID: runID)
                }
            }
        }

        _ = store.update(id: runID) { current in
            current.status = .cancelled
            current.latestAction = "Handed off to Terminal — you are driving this session now"
            current.finishedAt = Date()
            current.pid = nil
            current.pendingApprovalID = ""
            // Session now belongs exclusively to Terminal. Keeping this value
            // would make `canSendFollowUp` offer a second driver for it.
            current.sessionIdentifier = ""
            if !current.queuedFollowUpInstructions.isEmpty {
                current.queuedFollowUpInstructions.removeAll()
                current.appendActivity(kind: .status, text: "Queued follow-ups discarded")
            }
            current.appendActivity(kind: .status, text: current.latestAction)
        }
        onRunsChanged?()
        onEvent?(runID, .finished(summary: "Handed off to Terminal"))
        return .success(command)
    }

    func latestUndoEntry() -> AgentUndoEntry? {
        undoLedger.latestReadyEntry()
    }

    @discardableResult
    func undoLastAgentWork() throws -> AgentUndoEntry {
        guard let entry = undoLedger.latestReadyEntry() else {
            throw AgentUndoLedgerError.snapshotMissing
        }
        let restoredEntry = try undoLedger.undo(entryID: entry.id)
        _ = store.update(id: entry.runID) { current in
            current.latestAction = "Undone — previous workspace restored"
            current.summary = "Previous workspace restored. Post-agent version kept in Undo Ledger recovery."
            current.appendActivity(kind: .status, text: current.summary)
        }
        onRunsChanged?()
        onUndoLedgerChanged?()
        return restoredEntry
    }

    /// Per-tool approval inside leg two, which only attached folders ask for.
    func resolveApproval(runID: UUID, approve: Bool) {
        guard pendingStops[runID] == nil,
              let run = store.run(id: runID),
              run.status == .waitingForApproval else { return }

        if run.detachedAttemptID != nil, sessions[runID] == nil {
            guard let tokenID = UUID(uuidString: run.pendingApprovalID) else { return }
            let command = DetachedAgentRuntimeCommand.respondToApproval(
                token: DetachedAgentApprovalToken(rawValue: tokenID),
                decision: approve ? .approve : .deny
            )
            guard enqueueDetachedCommand(runID: runID, command: command) else {
                _ = refreshDetachedRun(runID: runID, allowMissingStateWhileSpawned: true)
                return
            }
            _ = store.update(id: runID) { current in
                current.latestAction = approve
                    ? "Approval sent — continuing…"
                    : "Declined — stopping safely…"
                current.appendActivity(
                    kind: .user,
                    text: approve ? "Approved requested action" : "Declined requested action"
                )
                current.appendActivity(kind: .status, text: current.latestAction)
            }
            onRunsChanged?()
            return
        }

        guard let session = sessions[runID] else { return }

        if !approve {
            // OpenCode has no stable stdin deny; Claude gets a control_response.
            if let payload = session.adapter.stdinPayloadForApproval(id: run.pendingApprovalID, approve: false) {
                session.process.writeToStandardInput(payload)
            }
            cancel(runID: runID)
            return
        }

        if let payload = session.adapter.stdinPayloadForApproval(id: run.pendingApprovalID, approve: true) {
            session.process.writeToStandardInput(payload)
        }
        _ = store.update(id: runID) { current in
            current.status = .running
            current.latestAction = "Approved — continuing"
            current.pendingApprovalID = ""
            current.appendActivity(kind: .user, text: "Approved requested action")
            current.appendActivity(kind: .status, text: current.latestAction)
        }
        onRunsChanged?()
        onEvent?(runID, .started)
    }

    func revealWorkspace(runID: UUID) -> Bool {
        guard let run = store.run(id: runID) else { return false }
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: run.workspacePath, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    // MARK: - Preparation

    private func beginRun(
        runID: UUID,
        prompt: String,
        executor: HeadlessExecutor,
        origin: AgentRunOrigin,
        workspaceURL: URL,
        screenContext: AgentScreenContext,
        createWorkspace: Bool
    ) -> UUID {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = Self.title(from: trimmedPrompt)
        let createdAt = Date()
        let adapter = HeadlessCLIAdapterFactory.adapter(
            for: executor,
            openCodeModelIdentifier: openCodeModelIdentifier(),
            claudeModelIdentifier: claudeModelIdentifier(),
            codexModelIdentifier: codexModelIdentifier(),
            codexReasoningEffort: codexReasoningEffort()
        )
        // Claude Code takes a session id of our choosing; OpenCode assigns its
        // own, which arrives on the first event of leg one.
        let sessionIdentifier = adapter.preassignsSessionIdentifier
            ? UUID().uuidString.lowercased()
            : ""

        let run = AgentRun.queued(
            id: runID,
            title: title,
            prompt: trimmedPrompt,
            workspaceURL: workspaceURL,
            executor: executor,
            origin: origin,
            createdAt: createdAt,
            sessionIdentifier: sessionIdentifier
        )

        if trimmedPrompt.isEmpty {
            return fail(run, reason: "Say what you want the agent to do.")
        }

        // Sign-in is checked before anything is written to disk, so a job that
        // never had a chance does not leave an empty folder behind.
        let readiness = readinessForExecutor(executor)
        if !readiness.allowsLaunch {
            return fail(run, reason: readiness.remedy.isEmpty ? readiness.detail : readiness.remedy)
        }

        guard resolveExecutable(executor.executableName) != nil else {
            return fail(
                run,
                reason: "\(executor.executableName) is not on PATH. Install \(executor.displayName) and try again."
            )
        }

        if createWorkspace {
            do {
                try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
            } catch {
                return fail(run, reason: "Could not create \(workspaceURL.path)")
            }
        }

        if AgentTaskMarkdown.shouldPersist(in: origin) {
            do {
                try AgentTaskMarkdown.write(
                    to: workspaceURL,
                    title: title,
                    prompt: trimmedPrompt,
                    executor: executor,
                    createdAt: createdAt,
                    screenContext: screenContext,
                    fileManager: fileManager
                )
            } catch {
                return fail(run, reason: "Could not write TASK.md")
            }
        }

        store.upsert(run)
        onRunsChanged?()
        spawn(runID: runID, leg: .plan(prompt: trimmedPrompt))
        return runID
    }

    // MARK: - Spawning one leg

    private func spawn(runID: UUID, leg: AgentRunLeg) {
        guard let run = store.run(id: runID) else { return }
        let shouldDetachExecution = detachedExecutionEnabled && leg == .execute

        guard let executableURL = resolveExecutable(run.executor.executableName) else {
            if !leg.isReadOnly {
                // Approval already prepared the snapshot. No child was
                // started, so the snapshot can become undoable immediately.
                markUndoReady(runID: runID)
            }
            apply(
                .failed(message: "\(run.executor.executableName) is no longer on PATH."),
                to: runID
            )
            return
        }

        let adapter = HeadlessCLIAdapterFactory.adapter(
            for: run.executor,
            openCodeModelIdentifier: openCodeModelIdentifier(),
            claudeModelIdentifier: claudeModelIdentifier(),
            codexModelIdentifier: codexModelIdentifier(),
            codexReasoningEffort: codexReasoningEffort(),
            openCodeMCPConfigurationJSON: leg.isReadOnly || shouldDetachExecution
                ? nil
                : openCodeMCPConfigurationJSON(),
            codexMCPConfigurationArguments: leg.isReadOnly || shouldDetachExecution
                ? []
                : codexMCPConfigurationArguments(),
            mcpChildEnvironment: leg.isReadOnly || shouldDetachExecution
                ? [:]
                : mcpChildEnvironment(run.executor)
        )
        let spec = adapter.launchSpec(
            workspaceURL: run.workspaceURL,
            leg: leg,
            origin: run.origin,
            title: run.title,
            sessionIdentifier: run.sessionIdentifier
        )

        if shouldDetachExecution {
            spawnDetachedExecute(
                run: run,
                executableURL: executableURL,
                launchSpec: spec
            )
            return
        }

        let process = HeadlessCLIProcess()

        do {
            try process.start(
                executableURL: executableURL,
                arguments: spec.arguments,
                currentDirectoryURL: spec.currentDirectoryURL,
                environmentKeysToRemove: spec.environmentKeysToRemove,
                environmentOverrides: spec.environmentOverrides,
                temporaryDirectoriesToRemove: spec.temporaryDirectoriesToRemove,
                usesDuplexStandardInput: spec.usesDuplexStandardInput,
                onLine: { [weak self] line in
                    Task { @MainActor in
                        self?.handleStdout(runID: runID, line: line)
                    }
                },
                onExit: { [weak self] status in
                    Task { @MainActor in
                        self?.handleExit(runID: runID, status: status, process: process)
                    }
                }
            )
        } catch {
            apply(.failed(message: error.localizedDescription), to: runID)
            return
        }

        _ = store.update(id: runID) { current in
            current.status = leg.isReadOnly ? .planning : .running
            current.latestAction = leg.isReadOnly
                ? "Planning with \(run.executor.displayName)…"
                : "Working with \(run.executor.displayName)…"
            current.startedAt = current.startedAt ?? Date()
            current.pid = process.processIdentifier
            current.pendingApprovalID = ""
            current.appendActivity(kind: .status, text: current.latestAction)
        }

        // A read-only leg is cheap and should not be able to sit for a quarter
        // of an hour; only real work gets the long rope.
        let runtimeLimit = runtimeLimitForLeg(leg)
        let waitForRuntimeLimit = waitForRuntimeLimit
        let timeoutTask = Task { [weak self] in
            await waitForRuntimeLimit(runtimeLimit)
            guard !Task.isCancelled else { return }
            self?.failTimeout(runID: runID)
        }

        sessions[runID] = LiveSession(
            process: process,
            adapter: adapter,
            leg: leg,
            timeoutTask: timeoutTask
        )
        onRunsChanged?()
        onEvent?(runID, .started)
    }

    // MARK: - Detached execute runtime

    private enum DetachedRefreshOutcome {
        case activeVerified
        case pending
        case terminal
        case failed
    }

    private func spawnDetachedExecute(
        run: AgentRun,
        executableURL: URL,
        launchSpec: HeadlessCLILaunchSpec
    ) {
        guard let runnerExecutableURL = detachedRunnerExecutableURL() else {
            markUndoReady(runID: run.id)
            apply(.failed(message: "Could not locate HeyMate's agent runner."), to: run.id)
            return
        }

        let attemptID = UUID()
        let request = DetachedAgentLaunchRequest(
            runID: run.id,
            attemptID: attemptID,
            executor: run.executor,
            leg: .execute,
            spec: DetachedAgentLaunchSpec(
                executableURL: executableURL,
                arguments: launchSpec.arguments,
                currentDirectoryURL: launchSpec.currentDirectoryURL,
                environmentKeysToRemove: launchSpec.environmentKeysToRemove,
                environmentOverrides: launchSpec.environmentOverrides,
                temporaryDirectoriesToRemove: launchSpec.temporaryDirectoriesToRemove,
                usesDuplexStandardInput: launchSpec.usesDuplexStandardInput,
                runtimeLimit: runtimeLimitForLeg(.execute)
            )
        )

        cleanupDetachedTracking(runID: run.id)
        do {
            guard try store.updateDurably(id: run.id, mutate: { current in
                current.detachedAttemptIdentifier = attemptID.uuidString.lowercased()
                current.lastDetachedJournalSequence = 0
                current.status = .running
                current.latestAction = "Starting background agent…"
                current.startedAt = current.startedAt ?? Date()
                current.finishedAt = nil
                current.pid = nil
                current.pendingApprovalID = ""
                current.error = ""
                current.appendActivity(kind: .status, text: current.latestAction)
            }) != nil else { return }
        } catch {
            markUndoReady(runID: run.id)
            apply(
                .failed(message: "Could not save background agent ownership safely."),
                to: run.id
            )
            return
        }
        pendingDetachedRunIDs.insert(run.id)
        onRunsChanged?()

        do {
            let runnerPID = try spawnDetachedRunner(runnerExecutableURL, request)
            detachedExpectedRunnerPIDs[run.id] = runnerPID
            if let identity = inspectProcessIdentity(runnerPID) {
                detachedExpectedRunnerIdentities[run.id] = identity
            }
            _ = store.update(id: run.id) { current in
                current.pid = runnerPID
            }
            beginDetachedMonitoring(runID: run.id)
            _ = refreshDetachedRun(runID: run.id, allowMissingStateWhileSpawned: true)
            onRunsChanged?()
            onEvent?(run.id, .started)
        } catch {
            cleanupDetachedTracking(runID: run.id)
            markUndoReady(runID: run.id)
            apply(.failed(message: error.localizedDescription), to: run.id)
        }
    }

    private func beginDetachedMonitoring(runID: UUID) {
        detachedMonitorTasks[runID]?.cancel()
        detachedMonitorTasks[runID] = Task { [weak self] in
            let clock = SuspendingClock()
            while !Task.isCancelled {
                guard let (outcome, interval) = self.map({ launcher in
                    (
                        launcher.refreshDetachedRun(
                            runID: runID,
                            allowMissingStateWhileSpawned: true
                        ),
                        launcher.detachedMonitorInterval
                    )
                }) else { return }
                switch outcome {
                case .activeVerified, .pending:
                    break
                case .terminal, .failed:
                    return
                }
                try? await clock.sleep(for: interval)
            }
        }
    }

    private func refreshDetachedRun(
        runID: UUID,
        allowMissingStateWhileSpawned: Bool
    ) -> DetachedRefreshOutcome {
        guard let run = store.run(id: runID),
              !run.status.isTerminal,
              let attemptID = run.detachedAttemptID else {
            cleanupDetachedTracking(runID: runID)
            return .terminal
        }

        let state: DetachedAgentDurableState
        do {
            guard let loadedState = try DetachedAgentDurableStateStore.loadReadOnly(
                rootDirectoryURL: detachedRuntimeRootURL,
                runID: runID,
                attemptID: attemptID
            ) else {
                if (allowMissingStateWhileSpawned && expectedSpawnIsStillLive(runID: runID))
                    || recordedRunnerMayStillBeLive(run)
                    || detachedSafetyGraceIsActive(
                        runID: runID,
                        duration: detachedPersistenceRecoveryGracePeriod
                    ) {
                    holdDetachedVerification(runID: runID)
                    return .pending
                }
                failDetachedRun(
                    runID: runID,
                    message: "Detached agent state is missing."
                )
                return .failed
            }
            state = loadedState
        } catch {
            if (allowMissingStateWhileSpawned && expectedSpawnIsStillLive(runID: runID))
                || recordedRunnerMayStillBeLive(run)
                || detachedSafetyGraceIsActive(
                    runID: runID,
                    duration: detachedPersistenceRecoveryGracePeriod
                ) {
                holdDetachedVerification(runID: runID)
                return .pending
            }
            failDetachedRun(
                runID: runID,
                message: "Detached agent state could not be verified."
            )
            return .failed
        }

        let reduced: AgentRun
        do {
            // Always inspect journal while snapshot is nonterminal. Runner may
            // durably append its terminal record and then fail before replacing
            // state.json; terminal journal is still authoritative and safe to
            // import after runner exits.
            let journalByteCount = detachedJournalByteCount(
                runID: runID,
                attemptID: attemptID
            )
            let shouldReloadJournal = state.lastJournalSequence > run.lastDetachedJournalSequence
                || detachedJournalByteCounts[runID] != journalByteCount
            let journal = shouldReloadJournal
                ? try DetachedAgentRuntimeJournal.loadReadOnly(
                    rootDirectoryURL: detachedRuntimeRootURL,
                    runID: runID,
                    attemptID: attemptID
                )
                : []
            detachedJournalByteCounts[runID] = journalByteCount
            reduced = try DetachedAgentRunReducer.reduce(
                run: run,
                state: state,
                journal: journal
            )
        } catch {
            // A terminal snapshot is independently durable and is written only
            // after process-tree exit. Let it close a run even when journal
            // bytes are unreadable, provided it is not behind app checkpoint.
            if state.phase.isTerminal,
               state.lastJournalSequence >= run.lastDetachedJournalSequence,
               let terminal = try? DetachedAgentRunReducer.reduce(
                   run: run,
                   state: state,
                   journal: []
               ) {
                projectDetachedRun(previous: run, reduced: terminal)
                cleanupDetachedTracking(runID: runID)
                return .terminal
            }
            // Journal append is intentionally durable before state replacement.
            // A poll may observe that normal gap and then see stale state on its
            // next pass. Corrupt persistence has the same safety rule: never
            // release undo while a verified owner or child group may still write.
            if persistedRunnerIsVerifiedLive(runID: runID, state: state) {
                holdDetachedVerification(runID: runID)
                return .pending
            }
            if detachedChildCleanupStillInFlight(state: state, runID: runID) {
                holdDetachedCleanup(runID: runID)
                return .pending
            }
            failDetachedRun(
                runID: runID,
                message: "Detached agent progress could not be verified."
            )
            return .failed
        }

        if reduced.status.isTerminal {
            projectDetachedRun(previous: run, reduced: reduced)
            cleanupDetachedTracking(runID: runID)
            return .terminal
        }

        guard persistedRunnerIsVerifiedLive(runID: runID, state: state),
              let runnerIdentity = state.runnerIdentity else {
            if detachedChildCleanupStillInFlight(state: state, runID: runID) {
                holdDetachedCleanup(runID: runID)
                return .pending
            }
            failDetachedRun(
                runID: runID,
                message: "Detached agent runner stopped unexpectedly."
            )
            return .failed
        }
        detachedExpectedRunnerPIDs[runID] = runnerIdentity.pid
        detachedExpectedRunnerIdentities[runID] = runnerIdentity

        projectDetachedRun(previous: run, reduced: reduced)

        pendingDetachedRunIDs.remove(runID)
        verifiedDetachedRunIDs.insert(runID)
        detachedSafetyHoldStartedAt.removeValue(forKey: runID)
        return .activeVerified
    }

    private func projectDetachedRun(
        previous: AgentRun,
        reduced: AgentRun
    ) {
        var projected = reduced
        let statusChanged = previous.status != projected.status
        let actionChanged = previous.latestAction != projected.latestAction
        if (statusChanged || actionChanged), !projected.latestAction.isEmpty {
            let kind: AgentActivityEntry.Kind = projected.status == .succeeded
                ? .agent
                : (statusChanged ? .status : .progress)
            projected.appendActivity(kind: kind, text: projected.latestAction)
        }
        store.upsert(projected)
        onRunsChanged?()

        guard statusChanged else { return }
        switch projected.status {
        case .running:
            onEvent?(projected.id, .started)
        case .waitingForApproval:
            onEvent?(
                projected.id,
                .approvalRequested(
                    id: projected.pendingApprovalID,
                    summary: projected.latestAction
                )
            )
        case .succeeded:
            markUndoReady(runID: projected.id)
            scheduleReceiptScanForRun(runID: projected.id)
            onEvent?(
                projected.id,
                .finished(summary: projected.summary.isEmpty ? "Done" : projected.summary)
            )
            startNextQueuedFollowUp(runID: projected.id)
        case .failed:
            markUndoReady(runID: projected.id)
            scheduleReceiptScanForRun(runID: projected.id)
            onEvent?(projected.id, .failed(message: projected.error))
        case .cancelled:
            markUndoReady(runID: projected.id)
            scheduleReceiptScanForRun(runID: projected.id)
            onEvent?(
                projected.id,
                .finished(
                    summary: projected.sessionIdentifier.isEmpty
                        ? "Handed off to Terminal"
                        : "Cancelled"
                )
            )
        case .queued, .planning, .awaitingPlanApproval:
            break
        }
    }

    private func persistedRunnerIsVerifiedLive(
        runID: UUID,
        state: DetachedAgentDurableState
    ) -> Bool {
        guard let runnerIdentity = state.runnerIdentity,
              detachedExpectedRunnerPIDs[runID].map({ $0 == runnerIdentity.pid }) ?? true,
              detachedExpectedRunnerIdentities[runID].map({ $0 == runnerIdentity }) ?? true else {
            return false
        }
        return matchesLiveProcessIdentity(runnerIdentity)
    }

    /// PID without persisted generation never authorizes signaling or quit.
    /// Exact executable match is useful only as a conservative reason to keep
    /// recovery pending while a missing/corrupt state snapshot repairs itself.
    private func recordedRunnerMayStillBeLive(_ run: AgentRun) -> Bool {
        guard let recordedPID = run.pid,
              recordedPID > 1,
              let identity = inspectProcessIdentity(recordedPID),
              AgentProcessIdentityInspector.isTrustworthy(identity),
              let runnerExecutableURL = detachedRunnerExecutableURL() else { return false }
        let livePath = URL(fileURLWithPath: identity.executablePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let expectedPath = runnerExecutableURL
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        return livePath == expectedPath
    }

    private func detachedSafetyGraceIsActive(
        runID: UUID,
        duration: TimeInterval
    ) -> Bool {
        guard duration > 0 else { return false }
        let now = detachedCurrentDate()
        let startedAt = detachedSafetyHoldStartedAt[runID] ?? now
        detachedSafetyHoldStartedAt[runID] = startedAt
        return now.timeIntervalSince(startedAt) < duration
    }

    private func detachedChildCleanupStillInFlight(
        state: DetachedAgentDurableState,
        runID: UUID
    ) -> Bool {
        if let childIdentity = state.childIdentity,
           let processGroupID = state.childProcessGroupID {
            if matchesLiveChildProcessGroup(childIdentity, processGroupID) {
                return true
            }
            // Leader may already be gone while descendants and lifetime monitor
            // remain during TERM/KILL grace. Group existence is hold-only; full
            // leader identity remains mandatory for every signal operation.
            return detachedProcessGroupExists(processGroupID)
        }
        return detachedSafetyGraceIsActive(
            runID: runID,
            duration: detachedCleanupGracePeriod
        )
    }

    private func holdDetachedCleanup(runID: UUID) {
        holdDetachedRun(
            runID: runID,
            action: "Stopping orphaned agent process…"
        )
    }

    private func holdDetachedVerification(runID: UUID) {
        holdDetachedRun(
            runID: runID,
            action: "Verifying background agent safety…"
        )
    }

    private func holdDetachedRun(runID: UUID, action: String) {
        verifiedDetachedRunIDs.remove(runID)
        pendingDetachedRunIDs.insert(runID)
        guard let current = store.run(id: runID),
              !current.status.isTerminal,
              current.latestAction != action else { return }
        _ = store.update(id: runID) { current in
            guard !current.status.isTerminal else { return }
            current.latestAction = action
            current.appendActivity(kind: .status, text: current.latestAction)
        }
        onRunsChanged?()
    }

    private func expectedSpawnIsStillLive(runID: UUID) -> Bool {
        if let expectedIdentity = detachedExpectedRunnerIdentities[runID] {
            return matchesLiveProcessIdentity(expectedIdentity)
        }
        guard let expectedPID = detachedExpectedRunnerPIDs[runID],
              let identity = inspectProcessIdentity(expectedPID),
              matchesLiveProcessIdentity(identity) else { return false }
        detachedExpectedRunnerIdentities[runID] = identity
        return true
    }

    private func detachedJournalByteCount(runID: UUID, attemptID: UUID) -> UInt64 {
        let journalURL = DetachedAgentRuntimePaths.attemptDirectoryURL(
            rootDirectoryURL: detachedRuntimeRootURL,
            runID: runID,
            attemptID: attemptID
        ).appendingPathComponent("events.jsonl", isDirectory: false)
        let attributes = try? fileManager.attributesOfItem(atPath: journalURL.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func detachedRunCanSurviveAppTermination(_ run: AgentRun) -> Bool {
        guard let attemptID = run.detachedAttemptID,
              !pendingDetachedRunIDs.contains(run.id) else { return false }
        do {
            guard let state = try DetachedAgentDurableStateStore.loadReadOnly(
                rootDirectoryURL: detachedRuntimeRootURL,
                runID: run.id,
                attemptID: attemptID
            ) else { return false }
            if state.phase.isTerminal { return true }
            guard verifiedDetachedRunIDs.contains(run.id),
                  let identity = state.runnerIdentity,
                  detachedExpectedRunnerPIDs[run.id].map({ $0 == identity.pid }) ?? true,
                  detachedExpectedRunnerIdentities[run.id].map({ $0 == identity }) ?? true else {
                return false
            }
            return matchesLiveProcessIdentity(identity)
        } catch {
            return false
        }
    }

    @discardableResult
    private func enqueueDetachedCommand(
        runID: UUID,
        command: DetachedAgentRuntimeCommand
    ) -> Bool {
        guard let run = store.run(id: runID),
              !run.status.isTerminal,
              let attemptID = run.detachedAttemptID else { return false }

        do {
            let commandSchemaVersion: Int
            if let state = try DetachedAgentDurableStateStore.loadReadOnly(
                rootDirectoryURL: detachedRuntimeRootURL,
                runID: runID,
                attemptID: attemptID
            ) {
                guard !state.phase.isTerminal,
                      let identity = state.runnerIdentity,
                      detachedExpectedRunnerPIDs[runID].map({ $0 == identity.pid }) ?? true,
                      detachedExpectedRunnerIdentities[runID].map({ $0 == identity }) ?? true,
                      matchesLiveProcessIdentity(identity) else { return false }
                commandSchemaVersion = state.schemaVersion
            } else {
                guard pendingDetachedRunIDs.contains(runID),
                      expectedSpawnIsStillLive(runID: runID) else { return false }
                commandSchemaVersion = DetachedAgentRuntimeProtocol.currentSchemaVersion
            }

            let mailbox = try DetachedAgentCommandMailbox(
                rootDirectoryURL: detachedRuntimeRootURL,
                runID: runID,
                attemptID: attemptID
            )
            _ = try mailbox.enqueue(
                DetachedAgentCommandEnvelope(
                    schemaVersion: commandSchemaVersion,
                    runID: runID,
                    attemptID: attemptID,
                    command: command
                )
            )
            return true
        } catch {
            return false
        }
    }

    private func waitForDetachedTerminalHandoff(runID: UUID) async -> Bool {
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while clock.now < deadline {
            _ = refreshDetachedRun(runID: runID, allowMissingStateWhileSpawned: true)
            if let run = store.run(id: runID), run.status.isTerminal {
                return run.status == .cancelled && run.sessionIdentifier.isEmpty
            }
            try? await clock.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func failDetachedRun(runID: UUID, message: String) {
        cleanupDetachedTracking(runID: runID)
        _ = store.update(id: runID) { current in
            guard !current.status.isTerminal else { return }
            current.status = .failed
            current.error = message
            current.latestAction = message
            current.finishedAt = Date()
            current.pid = nil
            current.pendingApprovalID = ""
            if !current.queuedFollowUpInstructions.isEmpty {
                current.queuedFollowUpInstructions.removeAll()
                current.appendActivity(kind: .status, text: "Queued follow-ups stopped")
            }
            current.appendActivity(kind: .status, text: message)
        }
        markUndoReady(runID: runID)
        scheduleReceiptScanForRun(runID: runID)
        onRunsChanged?()
        onEvent?(runID, .failed(message: message))
    }

    private func cleanupDetachedTracking(runID: UUID) {
        detachedMonitorTasks.removeValue(forKey: runID)?.cancel()
        detachedExpectedRunnerPIDs.removeValue(forKey: runID)
        detachedExpectedRunnerIdentities.removeValue(forKey: runID)
        detachedJournalByteCounts.removeValue(forKey: runID)
        detachedSafetyHoldStartedAt.removeValue(forKey: runID)
        pendingDetachedRunIDs.remove(runID)
        verifiedDetachedRunIDs.remove(runID)
    }

    /// Records a job that never started, and returns its id — so `beginRun`
    /// can bail out of any preparation stage in one line.
    private func fail(_ run: AgentRun, reason: String) -> UUID {
        var failedRun = run
        failedRun.status = .failed
        failedRun.error = reason
        failedRun.latestAction = reason
        failedRun.finishedAt = Date()
        failedRun.appendActivity(kind: .status, text: reason)
        store.upsert(failedRun)
        onRunsChanged?()
        onEvent?(failedRun.id, .failed(message: reason))
        return failedRun.id
    }

    // MARK: - Stream handling

    private func handleStdout(runID: UUID, line: String) {
        guard pendingStops[runID] == nil,
              let session = sessions[runID],
              let run = store.run(id: runID),
              !run.status.isTerminal else { return }

        for event in session.adapter.events(fromStdoutLine: line) {
            guard session.leg.isReadOnly else {
                apply(event, to: runID)
                continue
            }

            // A read-only leg produces a plan, never an outcome. Its closing
            // summary is the last paragraph of that plan, so it is collected
            // rather than allowed to mark the job succeeded — the job has not
            // done anything yet.
            switch event {
            case .text(let text), .finished(let text):
                let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedText.isEmpty else { continue }
                sessions[runID]?.planFragments.append(trimmedText)
                _ = store.update(id: runID) { current in
                    current.latestAction = "Planning…"
                }
            case .approvalRequested:
                // Nothing read-only can need write permission.
                continue
            case .sessionIdentified, .tool, .failed, .planReady, .started:
                apply(event, to: runID)
            }
        }
    }

    private func handleExit(runID: UUID, status: Int32, process: HeadlessCLIProcess) {
        // Cancellation and timeout own this exit. Their waiter finalizes only
        // after the complete process group is gone, so the root exit callback
        // must not race the run into a different terminal state.
        if pendingStops[runID]?.process === process { return }

        // A finished process may report its exit after a follow-up has already
        // occupied this run's session slot. Never let that stale callback tear
        // down the newer turn.
        guard sessions[runID]?.process === process else { return }

        // Read the session's leg and stderr tail before it is dropped — they
        // are the only record of what was running and why it died.
        let finishedLeg = sessions[runID]?.leg
        let planFragments = sessions[runID]?.planFragments ?? []
        let standardErrorSummary = sessions[runID]?.process.recentStandardErrorSummary ?? ""
        sessions[runID]?.timeoutTask?.cancel()
        sessions[runID] = nil

        if finishedLeg?.isReadOnly == false {
            markUndoReady(runID: runID)
            scheduleReceiptScanForRun(runID: runID)
        }

        guard let run = store.run(id: runID) else { return }
        if run.status.isTerminal {
            if run.status == .succeeded {
                startNextQueuedFollowUp(runID: runID)
            }
            return
        }

        guard status == 0 else {
            // An exit code on its own tells the user nothing. Whatever the CLI
            // wrote to stderr is almost always the real explanation — a
            // signed-out session, an unknown flag, a network failure.
            let message = standardErrorSummary.isEmpty
                ? "Exited with status \(status)"
                : standardErrorSummary
            apply(.failed(message: message), to: runID)
            return
        }

        if finishedLeg?.isReadOnly == true {
            let planText = Self.presentablePlanText(from: planFragments)
            guard !planText.isEmpty else {
                apply(.failed(message: "The agent finished without producing a plan."), to: runID)
                return
            }
            apply(.planReady(text: planText), to: runID)
            return
        }

        apply(.finished(summary: run.summary.isEmpty ? "Done" : run.summary), to: runID)
        startNextQueuedFollowUp(runID: runID)
    }

    private func failTimeout(runID: UUID) {
        guard let run = store.run(id: runID),
              !run.status.isTerminal,
              pendingStops[runID] == nil,
              let liveSession = sessions[runID] else { return }
        beginStop(
            runID: runID,
            liveSession: liveSession,
            reason: .timeout(
                standardErrorSummary: liveSession.process.recentStandardErrorSummary
            )
        )
    }

    private func beginStop(
        runID: UUID,
        liveSession: LiveSession,
        reason: PendingStopReason
    ) {
        guard pendingStops[runID] == nil else { return }

        liveSession.timeoutTask?.cancel()
        let pendingStop = PendingStop(
            identifier: UUID(),
            process: liveSession.process,
            leg: liveSession.leg,
            reason: reason
        )
        pendingStops[runID] = pendingStop

        _ = store.update(id: runID) { current in
            guard !current.status.isTerminal else { return }
            current.latestAction = reason.stoppingAction
            current.appendActivity(kind: .status, text: current.latestAction)
        }
        onRunsChanged?()

        Task { [weak self, process = liveSession.process] in
            let didStop = await process.terminateAndWait()
            guard let self else { return }
            self.finishStop(
                runID: runID,
                identifier: pendingStop.identifier,
                process: process,
                didStop: didStop
            )
        }
    }

    private func finishStop(
        runID: UUID,
        identifier: UUID,
        process: HeadlessCLIProcess,
        didStop: Bool
    ) {
        guard let pendingStop = pendingStops[runID],
              pendingStop.identifier == identifier,
              pendingStop.process === process else { return }

        if didStop {
            if sessions[runID]?.process === process {
                sessions[runID] = nil
            }
            pendingStops[runID] = nil

            if !pendingStop.leg.isReadOnly {
                markUndoReady(runID: runID)
                scheduleReceiptScanForRun(runID: runID)
            }

            switch pendingStop.reason {
            case .cancellation:
                finishCancellation(runID: runID)
            case .timeout(let standardErrorSummary):
                let message = standardErrorSummary.isEmpty
                    ? "Timed out"
                    : "Timed out · \(standardErrorSummary)"
                apply(.failed(message: message), to: runID)
            }
            return
        }

        // Keep run non-terminal and retain session ownership. User may retry
        // Cancel; safe quit continues to block while process cannot be proven
        // dead.
        pendingStops[runID] = nil
        _ = store.update(id: runID) { current in
            guard !current.status.isTerminal else { return }
            current.latestAction = pendingStop.reason.couldNotStopAction
            current.error = current.latestAction
            current.appendActivity(kind: .status, text: current.latestAction)
        }
        onRunsChanged?()
    }

    private func apply(_ event: AgentEvent, to runID: UUID) {
        guard store.run(id: runID) != nil else { return }

        switch event {
        case .started:
            break
        case .sessionIdentified(let sessionIdentifier):
            _ = store.update(id: runID) { current in
                // First writer wins. Claude echoes back the id HeyMate chose;
                // OpenCode supplies the only one that exists.
                if current.sessionIdentifier.isEmpty {
                    current.sessionIdentifier = sessionIdentifier
                }
            }
            return
        case .tool(let summary):
            _ = store.update(id: runID) { current in
                guard !current.status.isTerminal else { return }
                current.latestAction = summary
                current.appendActivity(kind: .progress, text: summary)
            }
        case .text(let text):
            _ = store.update(id: runID) { current in
                guard !current.status.isTerminal else { return }
                current.summary = text
                if current.latestAction.isEmpty || current.latestAction.hasPrefix("Working") {
                    current.latestAction = String(text.prefix(80))
                }
                current.appendActivity(kind: .agent, text: text)
            }
        case .planReady(let planText):
            _ = store.update(id: runID) { current in
                guard !current.status.isTerminal else { return }
                current.status = .awaitingPlanApproval
                current.planText = planText
                current.latestAction = "Plan ready — needs your approval"
                current.pid = nil
                current.appendActivity(kind: .agent, text: planText)
                current.appendActivity(kind: .status, text: current.latestAction)
            }
        case .approvalRequested(let approvalID, let summary):
            _ = store.update(id: runID) { current in
                guard !current.status.isTerminal else { return }
                current.status = .waitingForApproval
                current.pendingApprovalID = approvalID
                current.latestAction = summary
                current.appendActivity(kind: .status, text: summary)
            }
        case .finished(let summary):
            markCurrentWriteLegUndoReady(runID: runID)
            sessions[runID]?.timeoutTask?.cancel()
            sessions[runID]?.process.terminateThenKill()
            _ = store.update(id: runID) { current in
                guard !current.status.isTerminal else { return }
                current.status = .succeeded
                current.summary = summary
                current.latestAction = summary.isEmpty ? "Done" : summary
                current.finishedAt = Date()
                current.pid = nil
                current.pendingApprovalID = ""
                current.appendActivity(kind: .agent, text: current.summary)
            }
        case .failed(let message):
            markCurrentWriteLegUndoReady(runID: runID)
            sessions[runID]?.timeoutTask?.cancel()
            sessions[runID]?.process.terminateThenKill()
            sessions[runID] = nil
            _ = store.update(id: runID) { current in
                guard !current.status.isTerminal else { return }
                current.status = .failed
                current.error = message
                current.latestAction = message
                current.finishedAt = Date()
                current.pid = nil
                current.pendingApprovalID = ""
                if !current.queuedFollowUpInstructions.isEmpty {
                    current.queuedFollowUpInstructions.removeAll()
                    current.appendActivity(kind: .status, text: "Queued follow-ups stopped")
                }
                current.appendActivity(kind: .status, text: message)
            }
        }

        onRunsChanged?()
        onEvent?(runID, event)
    }

    private func startNextQueuedFollowUp(runID: UUID) {
        guard store.run(id: runID)?.queuedFollowUpInstructions.isEmpty == false else { return }
        guard let run = store.run(id: runID),
              run.status == .succeeded,
              !run.sessionIdentifier.isEmpty,
              let instruction = run.queuedFollowUpInstructions.first else { return }

        _ = store.update(id: runID) { current in
            current.queuedFollowUpInstructions.removeFirst()
            current.status = .planning
            current.planText = ""
            current.summary = ""
            current.error = ""
            current.finishedAt = nil
            current.undoEntryIdentifier = ""
            current.workspaceChangeSummary = nil
            current.detachedAttemptIdentifier = ""
            current.lastDetachedJournalSequence = 0
            current.latestAction = "Planning queued follow-up…"
            current.appendActivity(kind: .status, text: current.latestAction)
        }
        onRunsChanged?()
        spawn(runID: runID, leg: .followUp(instruction: instruction))
    }

    private func markCurrentWriteLegUndoReady(runID: UUID) {
        guard sessions[runID]?.leg.isReadOnly == false else { return }
        markUndoReady(runID: runID)
    }

    private func markUndoReady(runID: UUID) {
        guard let run = store.run(id: runID),
              let entryID = UUID(uuidString: run.undoEntryIdentifier),
              undoLedger.entry(id: entryID) != nil else { return }
        undoLedger.markReady(entryID: entryID)
        onUndoLedgerChanged?()
    }

    private func scheduleReceiptScanForRun(runID: UUID) {
        guard let run = store.run(id: runID),
              let entryID = UUID(uuidString: run.undoEntryIdentifier),
              let entry = undoLedger.entry(id: entryID) else { return }
        scheduleReceiptScan(runID: runID, entry: entry)
    }

    private func scheduleReceiptScan(runID: UUID, entry: AgentUndoEntry) {
        guard store.run(id: runID)?.workspaceChangeSummary == nil,
              receiptScansInFlight.insert(entry.id).inserted else { return }

        let snapshotURL = URL(fileURLWithPath: entry.snapshotPath, isDirectory: true)
        let workspaceURL = URL(fileURLWithPath: entry.workspacePath, isDirectory: true)
        Task { [weak self] in
            let changes = await Task.detached(priority: .utility) {
                try? AgentWorkspaceChangeScanner.scan(
                    beforeSnapshotURL: snapshotURL,
                    currentWorkspaceURL: workspaceURL
                )
            }.value

            guard let self else { return }
            self.receiptScansInFlight.remove(entry.id)
            guard let changes,
                  self.store.run(id: runID)?.undoEntryIdentifier == entry.id.uuidString else {
                return
            }
            _ = self.store.update(id: runID) { current in
                current.workspaceChangeSummary = changes
            }
            self.onRunsChanged?()
        }
    }

    // MARK: - Plan text

    /// Joins a read-only leg's prose into the plan the user reads.
    ///
    /// `claude -p` disables `ExitPlanMode` and then narrates that fact, which
    /// is true and is not the user's problem. Anything that is about the tool
    /// rather than about the work is dropped here rather than in the parser,
    /// because it is a presentation concern.
    nonisolated static func presentablePlanText(from fragments: [String]) -> String {
        let plumbingMarkers = ["ExitPlanMode", "exit plan mode", "plan mode is disabled"]
        var seenFragments = Set<String>()
        var keptFragments: [String] = []

        for fragment in fragments {
            let keptLines = fragment
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { line in
                    !plumbingMarkers.contains { line.localizedCaseInsensitiveContains($0) }
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !keptLines.isEmpty, seenFragments.insert(keptLines).inserted else { continue }
            keptFragments.append(keptLines)
        }

        return keptFragments.joined(separator: "\n\n")
    }

    static func title(from prompt: String) -> String {
        let firstLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Agent" }
        if trimmed.count <= 60 { return trimmed }
        return String(trimmed.prefix(57)) + "…"
    }
}
