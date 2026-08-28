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

    private let store: FileAgentRunStore
    private let undoLedger: FileAgentUndoLedger
    private let fileManager: FileManager
    private var sessions: [UUID: LiveSession] = [:]

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

    /// Inline MCP config giving a working leg HeyMate's own tools. Resolved
    /// per spawn because it depends on the bridge port and on a script that is
    /// seeded lazily; nil is a normal answer and simply means no HeyMate tools.
    var mcpConfigurationJSON: () -> String? = { nil }
    var openCodeMCPConfigurationJSON: () -> String? = { nil }
    var codexMCPConfigurationArguments: () -> [String] = { [] }
    var mcpChildEnvironment: () -> [String: String] = { [:] }

    init(
        store: FileAgentRunStore,
        undoLedger: FileAgentUndoLedger,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.undoLedger = undoLedger
        self.fileManager = fileManager
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
        do {
            let undoEntry = try undoLedger.prepareSnapshot(for: run)
            _ = store.update(id: runID) { current in
                current.undoEntryIdentifier = undoEntry.id.uuidString
            }
        } catch {
            _ = store.update(id: runID) { current in
                current.latestAction = "Could not prepare undo"
                current.error = error.localizedDescription
            }
            onRunsChanged?()
            return
        }

        _ = store.update(id: runID) { current in
            current.status = .running
            current.latestAction = "Approved — starting work"
            current.error = ""
            current.appendActivity(kind: .user, text: "Approved plan")
            current.appendActivity(kind: .status, text: current.latestAction)
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
        markCurrentWriteLegUndoReady(runID: runID)
        sessions[runID]?.timeoutTask?.cancel()
        sessions[runID]?.process.terminateThenKill()
        sessions[runID] = nil
        _ = store.update(id: runID) { current in
            current.status = .cancelled
            current.latestAction = "Cancelled"
            current.finishedAt = Date()
            current.pid = nil
            current.pendingApprovalID = ""
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
    func beginTerminalTakeover(runID: UUID) -> Result<String, AgentTerminalTakeover.Unavailability> {
        guard let run = store.run(id: runID) else { return .failure(.runNotFound) }
        guard let command = AgentTerminalTakeover.shellCommand(for: run) else {
            return .failure(.sessionNotStartedYet)
        }

        // A job that already finished has no process to stop — its session is
        // just as resumable, so the handover is only the store update.
        if !run.status.isTerminal {
            markCurrentWriteLegUndoReady(runID: runID)
            sessions[runID]?.timeoutTask?.cancel()
            sessions[runID]?.process.terminateThenKill()
            sessions[runID] = nil
        }

        _ = store.update(id: runID) { current in
            current.status = .cancelled
            current.latestAction = "Handed off to Terminal — you are driving this session now"
            current.finishedAt = Date()
            current.pid = nil
            current.pendingApprovalID = ""
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
        guard let session = sessions[runID],
              let run = store.run(id: runID),
              run.status == .waitingForApproval else { return }

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

        store.upsert(run)
        onRunsChanged?()
        spawn(runID: runID, leg: .plan(prompt: trimmedPrompt))
        return runID
    }

    // MARK: - Spawning one leg

    private func spawn(runID: UUID, leg: AgentRunLeg) {
        guard let run = store.run(id: runID) else { return }

        guard let executableURL = resolveExecutable(run.executor.executableName) else {
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
            mcpConfigurationJSON: leg.isReadOnly ? nil : mcpConfigurationJSON(),
            openCodeMCPConfigurationJSON: leg.isReadOnly ? nil : openCodeMCPConfigurationJSON(),
            codexMCPConfigurationArguments: leg.isReadOnly ? [] : codexMCPConfigurationArguments(),
            mcpChildEnvironment: leg.isReadOnly ? [:] : mcpChildEnvironment()
        )
        let spec = adapter.launchSpec(
            workspaceURL: run.workspaceURL,
            leg: leg,
            origin: run.origin,
            title: run.title,
            sessionIdentifier: run.sessionIdentifier
        )
        let process = HeadlessCLIProcess()

        do {
            try process.start(
                executableURL: executableURL,
                arguments: spec.arguments,
                currentDirectoryURL: spec.currentDirectoryURL,
                environmentKeysToRemove: spec.environmentKeysToRemove,
                environmentOverrides: spec.environmentOverrides,
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
        let runtimeLimit = leg.isReadOnly
            ? HeadlessCLIProcess.maximumPlanningRuntime
            : HeadlessCLIProcess.maximumRuntime
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(runtimeLimit * 1_000_000_000))
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
        guard let session = sessions[runID],
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
        guard let run = store.run(id: runID), !run.status.isTerminal else { return }
        markCurrentWriteLegUndoReady(runID: runID)
        let standardErrorSummary = sessions[runID]?.process.recentStandardErrorSummary ?? ""
        sessions[runID]?.process.terminateThenKill()
        sessions[runID]?.timeoutTask?.cancel()
        sessions[runID] = nil
        let message = standardErrorSummary.isEmpty
            ? "Timed out"
            : "Timed out · \(standardErrorSummary)"
        apply(.failed(message: message), to: runID)
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
              let entryID = UUID(uuidString: run.undoEntryIdentifier) else { return }
        undoLedger.markReady(entryID: entryID)
        onUndoLedgerChanged?()
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
