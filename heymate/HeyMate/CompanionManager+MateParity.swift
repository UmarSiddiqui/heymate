//
//  CompanionManager+MateParity.swift
//  HeyMate
//
//  Mate features that keep agents working without the person minding them:
//  a backup brain when the main one is at its usage limit, routine time
//  limits, a mate scheduling its own routines from chat, and copying a mate.
//

import Foundation

/// Lets the scheduler stop routine runs that went past their time limit
/// without widening `MateRoutineRunning`, which tests fake.
/// The one usage-limit switch in flight, and the Brain to go back to.
@MainActor
enum BrainFailover {
    struct Choice: Equatable { let provider, model, effort, speed: String }
    static var task: Task<Void, Never>?
    /// Kept for the app session only: after a relaunch the saved Brain is
    /// the backup, which the person can switch back by hand.
    static var previous: Choice?
}

/// HeyMate's Brain names and the agent harness's provider ids.
nonisolated enum BrainProviderMapping {
    static func provider(for brain: AgentBrain) -> String? {
        switch brain {
        case .claudeCode: return "anthropic"
        case .codex: return "openai-codex"
        case .customAPI: return "heymate-custom"
        case .openCode, .onDevice: return nil
        }
    }

    static func brain(forProvider provider: String) -> AgentBrain? {
        AgentBrain.allCases.first { self.provider(for: $0) == provider }
    }
}

extension CompanionManager: MateRoutineRunLimiting {

    // MARK: Per-mate brain, effort, and usage-limit failover

    var brainLimitLedger: BrainLimitLedger { BrainLimitLedger() }

    /// App-wide fallback backup brain kept on the default mate.
    var appBackupBrain: AgentBrain? {
        mateDirectory.mates.first { $0.id == mateDirectory.defaultMateID }?
            .backupBrainRawValue.flatMap(AgentBrain.init(rawValue:))
    }

    /// The Brain the HeyMate agent is set to globally right now.
    var currentAgentBrain: AgentBrain? {
        BrainProviderMapping.brain(forProvider: MateAgentSetupController.shared.currentProvider)
    }

    /// The primary brain chosen for `mateID`, falling back to the app Brain.
    func matePrimaryBrain(mateID: UUID?) -> AgentBrain? {
        if let mateID,
           let raw = mateDirectory.mates.first(where: { $0.id == mateID })?.brainRawValue,
           let brain = AgentBrain(rawValue: raw),
           BrainProviderMapping.provider(for: brain) != nil {
            return brain
        }
        return currentAgentBrain
    }

    /// The backup brain chosen for `mateID`, falling back to the app backup.
    func mateBackupBrain(mateID: UUID?) -> AgentBrain? {
        if let mateID,
           let raw = mateDirectory.mates.first(where: { $0.id == mateID })?.backupBrainRawValue,
           let brain = AgentBrain(rawValue: raw),
           BrainProviderMapping.provider(for: brain) != nil {
            return brain
        }
        return appBackupBrain
    }

    /// Resolves the exact per-chat brain override for `mateID`, automatically
    /// routing around a usage-limited primary brain without touching global
    /// `model.json` or interrupting other running chats.
    func resolvedSessionBrain(forMateID mateID: UUID?, now: Date = Date()) -> MateAgentServeSession.BrainOverride? {
        let mate = mateID.flatMap { id in mateDirectory.mates.first(where: { $0.id == id }) }
        guard let primary = matePrimaryBrain(mateID: mateID) else { return nil }
        let backup = mateBackupBrain(mateID: mateID)
        let effective = brainLimitLedger.effectiveBrain(primary: primary, backup: backup, now: now)
        guard let provider = BrainProviderMapping.provider(for: effective) else { return nil }
        let usesOwnPrimary = effective == primary && mate?.brainRawValue != nil
        // Only send an override when the mate customized brain/model/effort or
        // when usage-limit failover routed away from the global provider.
        let globalProvider = MateAgentSetupController.shared.currentProvider
        if provider == globalProvider, mate?.modelID == nil, mate?.effortRawValue == nil, !usesOwnPrimary {
            return nil
        }
        return MateAgentServeSession.BrainOverride(
            provider: provider,
            model: effective == primary ? mate?.modelID : nil,
            effort: mate?.effortRawValue
        )
    }

    /// Per-mate skill allowlist (`nil` = inherit HeyMate's enabled skills).
    func resolvedMateSkillNames(forMateID mateID: UUID?) -> [String]? {
        guard let mateID else { return nil }
        return mateDirectory.mates.first(where: { $0.id == mateID })?.enabledSkillNames
    }

    /// A backup that can take the next turn right now.
    func hasUsableBackupBrain(mateID: UUID, now: Date = Date()) -> Bool {
        guard let primary = matePrimaryBrain(mateID: mateID),
              let backup = mateBackupBrain(mateID: mateID),
              backup != primary,
              BrainProviderMapping.provider(for: backup) != nil else { return false }
        return !brainLimitLedger.isLimited(backup, now: now)
    }

    func setMatePrimaryBrain(id: UUID, brain: AgentBrain?) {
        guard var mate = mateDirectory.mates.first(where: { $0.id == id }) else { return }
        let raw = brain?.rawValue
        guard mate.brainRawValue != raw else { return }
        mate.brainRawValue = raw
        if brain == nil { mate.modelID = nil }
        mate.updatedAt = Date()
        guard mateDirectory.upsertMate(mate) else { return }
        syncMatePublications()
    }

    func setMateEffort(id: UUID, effort: String?) {
        guard var mate = mateDirectory.mates.first(where: { $0.id == id }) else { return }
        let cleaned = effort?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = (cleaned?.isEmpty == false) ? cleaned : nil
        guard mate.effortRawValue != next else { return }
        mate.effortRawValue = next
        mate.updatedAt = Date()
        guard mateDirectory.upsertMate(mate) else { return }
        syncMatePublications()
    }

    func setMateBackupBrain(id: UUID, brain: AgentBrain?) {
        guard var mate = mateDirectory.mates.first(where: { $0.id == id }) else { return }
        let raw = brain?.rawValue
        guard mate.backupBrainRawValue != raw else { return }
        mate.backupBrainRawValue = raw
        mate.updatedAt = Date()
        guard mateDirectory.upsertMate(mate) else { return }
        syncMatePublications()
    }

    /// Called with every failed chat turn. A usage-limit failure holds that
    /// Brain in `brainLimitLedger` until reset so every chat using it routes
    /// straight to its backup on the very next turn — no global session reset
    /// needed. Retries a person's foreground message immediately on the backup.
    func noteChatTurnFailureForBackupBrain(message: String, mateID: UUID?, transcript: String? = nil) {
        let ownerID = mateID ?? mateDirectory.defaultMateID
        let activeBrain = resolvedSessionBrain(forMateID: ownerID).flatMap { BrainProviderMapping.brain(forProvider: $0.provider) }
            ?? matePrimaryBrain(mateID: ownerID)
        guard BrainUsageLimit.isLimit(message), let failedBrain = activeBrain else { return }
        let now = Date()
        var until = BrainUsageLimit.resetDate(from: message, now: now)
        if until == now.addingTimeInterval(BrainUsageLimit.defaultWait), let fromUsage = usageReset(for: failedBrain, now: now) {
            until = fromUsage
        }
        brainLimitLedger.markLimited(failedBrain, until: until)
        guard let backup = mateBackupBrain(mateID: ownerID), backup != failedBrain,
              let backupProvider = BrainProviderMapping.provider(for: backup),
              !brainLimitLedger.isLimited(backup, now: now) else { return }
        let setup = MateAgentSetupController.shared
        let backupAuthenticated = setup.providers.isEmpty || setup.providers.contains { $0.id == backupProvider && $0.authenticated }
        let clock = until.formatted(date: .omitted, time: .shortened)
        guard backupAuthenticated else {
            postMateMessage(mateID: ownerID, text: "\(failedBrain.displayName) is at its usage limit until about \(clock), and \(backup.displayName) is not signed in under Brain.")
            return
        }
        let isPersonTurn = activeRoutineTurn == nil && activeHandoffMateID == nil
        let retry = isPersonTurn ? (transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : ""
        let chatID = currentChat.id
        HeyMateLog.log("🔋 \(failedBrain.displayName) at its usage limit; routing turns to \(backup.displayName)")
        postMateMessage(
            mateID: ownerID,
            text: "\(failedBrain.displayName) hit its usage limit (resets about \(clock)), so \(backup.displayName) took over."
                + (retry.isEmpty ? "" : " Trying that again now.")
        )
        guard !retry.isEmpty, currentChat.id == chatID else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, self.currentChat.id == chatID else { return }
            _ = self.sendTypedMessage(retry, internalMateTurn: true)
        }
    }

    /// When the Brain's plan says its limit resets, from the notch usage
    /// meter: the latest reset among windows at their limit, else the
    /// fullest window's reset. Nil when the meter has nothing fresh.
    func usageReset(for brain: AgentBrain, now: Date) -> Date? {
        guard let provider = brain.usageProvider,
              let reading = NotchUsageStore.shared.readings[provider],
              now.timeIntervalSince(reading.fetchedAt) < 30 * 60 else { return nil }
        let future = reading.windows.filter { ($0.resetsAt ?? .distantPast) > now }
        let full = future.filter { ($0.usedPercent ?? 0) >= 99.5 }
        let reset = full.isEmpty
            ? future.max(by: { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) })?.resetsAt
            : full.compactMap(\.resetsAt).max()
        guard let reset, reset.timeIntervalSince(now) <= BrainUsageLimit.longestWait else { return nil }
        return reset
    }

    /// Goes back to the Brain the person chose once its limit is over and
    /// nothing is running.
    func restorePrimaryBrainIfLimitEnded(now: Date = Date()) {
        guard let previous = BrainFailover.previous, BrainFailover.task == nil,
              let own = BrainProviderMapping.brain(forProvider: previous.provider),
              !brainLimitLedger.isLimited(own, now: now),
              !isChatTurnBusy else { return }
        let setup = MateAgentSetupController.shared
        guard setup.currentProvider != previous.provider else { BrainFailover.previous = nil; return }
        BrainFailover.task = Task { @MainActor [weak self] in
            defer { BrainFailover.task = nil }
            await setup.connect(MateAgentEngineConfiguration.load(), provider: previous.provider, model: previous.model,
                                key: "", effort: previous.effort, speed: previous.speed == "default" ? "" : previous.speed)
            guard let self, setup.currentProvider == previous.provider else { return }
            BrainFailover.previous = nil
            HeyMateLog.log("🔋 Back on \(own.displayName)")
            self.postMateMessage(mateID: self.mateDirectory.activeMateID,
                                 text: "\(own.displayName)'s limit has reset, so HeyMate is back on \(own.displayName).")
        }
    }

    // MARK: Routine time limits

    func setRoutineRunLimit(id: UUID, minutes: Int?) {
        guard var routine = routines.first(where: { $0.id == id }) else { return }
        let cleaned = minutes.flatMap { $0 > 0 ? min($0, 24 * 60) : nil }
        guard routine.maxRunMinutes != cleaned else { return }
        routine.maxRunMinutes = cleaned
        mateDirectory.apply(routine)
        syncMatePublications()
    }

    func enforceRoutineRunLimits(now: Date) {
        restorePrimaryBrainIfLimitEnded(now: now)
        for routine in routines where isParallelRoutineRunning(routine.id)
            && MateRoutineAccounting.isOverRunLimit(routine, now: now) {
            HeyMateLog.log("⏱️ Routine \(routine.id) passed its \(routine.maxRunMinutes ?? 0) min limit; stopping it")
            Self.timedOutParallelRoutines.insert(routine.id)
            cancelParallelRoutine(routine.id)
        }
        guard let turn = activeRoutineTurn,
              let routine = routines.first(where: { $0.id == turn.routineID }),
              MateRoutineAccounting.isOverRunLimit(routine, now: now) else { return }
        HeyMateLog.log("⏱️ Routine \(routine.id) passed its \(routine.maxRunMinutes ?? 0) min limit; stopping it")
        // Stopping records the run as interrupted; relabel that run so the
        // history says why it stopped.
        cancelInFlightChatTurn()
        guard var stopped = routines.first(where: { $0.id == routine.id }) else { return }
        let status = MateRoutineAccounting.timedOutStatus(minutes: routine.maxRunMinutes ?? 0)
        stopped.lastStatusMessage = status
        if var history = stopped.history, !history.isEmpty, history[0].outcome == .interrupted {
            history[0].outcome = .timedOut
            history[0].summary = status
            stopped.history = history
        } else {
            stopped = MateRoutineAccounting.recordTimedOut(stopped, now: now, calendar: .current)
        }
        mateDirectory.apply(stopped)
        syncMatePublications()
    }

    // MARK: A mate schedules its own routines

    /// manage_routines from a chat turn. Every change is scoped to the mate
    /// whose chat called it, so one mate cannot rewrite another's schedule.
    func manageRoutinesFromTalkTool(arguments: [String: Any], mateID: UUID) -> (text: String, isError: Bool) {
        func text(_ key: String) -> String {
            ((arguments[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let mate = mateDirectory.mates.first(where: { $0.id == mateID && !$0.archived }) else {
            return ("This agent can't keep routines right now.", true)
        }
        let mine = routines.filter { $0.mateID == mateID }
        func describe(_ routine: MateRoutine) -> String {
            let state = routine.pausedReason == nil ? "on" : "paused"
            return "- id \(routine.id.uuidString.prefix(8)): \(routine.task) (\(routine.schedule.summary), \(state))"
        }
        func find(_ reference: String) -> MateRoutine? {
            let lowered = reference.lowercased()
            guard !lowered.isEmpty else { return nil }
            return mine.first { $0.id.uuidString.lowercased().hasPrefix(lowered) }
                ?? mine.first { $0.task.lowercased() == lowered }
                ?? mine.first { $0.task.lowercased().contains(lowered) }
        }
        let action = text("action").lowercased()
        switch action {
        case "", "list":
            guard !mine.isEmpty else { return ("\(mate.name) has no routines.", false) }
            return ("\(mate.name)'s routines:\n" + mine.map(describe).joined(separator: "\n"), false)
        case "add", "create":
            let task = text("task")
            let when = text("when")
            guard !task.isEmpty else { return ("Missing task: what should run.", true) }
            guard !when.isEmpty else { return ("Missing when. \(RoutinePhraseParser.invalidScheduleMessage)", true) }
            guard mine.count < Self.routineLimitPerMate else {
                return ("\(mate.name) already has \(Self.routineLimitPerMate) routines. Remove one first.", true)
            }
            guard var routine = RoutinePhraseParser.parse(when.replacingOccurrences(of: "?", with: ""), mateID: mateID, now: Date(), calendar: .current) else {
                return ("Couldn't read when. \(RoutinePhraseParser.invalidScheduleMessage) Nothing was saved.", true)
            }
            routine.task = task
            if let minutes = (arguments["time_limit_minutes"] as? NSNumber)?.intValue, minutes > 0 {
                routine.maxRunMinutes = min(minutes, 24 * 60)
            }
            addRoutine(routine)
            return ("Saved routine \(routine.id.uuidString.prefix(8)) for \(mate.name): \(routine.task). \(routine.schedule.summary). The person can pause or delete it in this agent's settings.", false)
        case "pause", "resume", "delete", "remove":
            guard let routine = find(text("routine")) else {
                return ("No routine of \(mate.name) matches that. Use action list to see ids.", true)
            }
            switch action {
            case "pause": pauseRoutine(id: routine.id)
            case "resume": resumeRoutine(id: routine.id)
            default: deleteRoutine(id: routine.id)
            }
            let verb = action == "remove" ? "delete" : action
            return ("Done: \(verb)d \(routine.task).", false)
        default:
            return ("Unknown action \(action). Use list, add, pause, resume or delete.", true)
        }
    }

    static let routineLimitPerMate = 12

    // MARK: Duplicate

    /// A copy with the same character, brain, habits, memory, integrations
    /// and wake. Its routines come over paused so nothing runs twice.
    @discardableResult
    func duplicateMate(id: UUID) -> Mate? {
        guard let source = mateDirectory.mates.first(where: { $0.id == id }), !source.conductsOthers else { return nil }
        let taken = Set(mateDirectory.mates.map { FileMateStore.normalized($0.name) })
        var name = "\(source.name) copy"
        var counter = 2
        while taken.contains(FileMateStore.normalized(name)) {
            name = "\(source.name) copy \(counter)"
            counter += 1
        }
        guard var copy = createMate(name: name, job: source.job, soul: source.soul, opensChat: false,
                                    faceAssetName: source.faceAssetName) else { return nil }
        copy.brainRawValue = source.brainRawValue
        copy.backupBrainRawValue = source.backupBrainRawValue
        copy.modelID = source.modelID
        copy.effortRawValue = source.effortRawValue
        copy.enabledSkillNames = source.enabledSkillNames
        copy.browserProfileID = source.browserProfileID
        copy.connectorOverrides = source.connectorOverrides
        copy.updatedAt = Date()
        _ = mateDirectory.upsertMate(copy)
        let habits = agentHabits(for: source)
        if !habits.howItWorks.isEmpty || !habits.asksFirst.isEmpty {
            saveAgentHabits(id: copy.id, howItWorks: habits.howItWorks, asksFirst: habits.asksFirst)
        }
        let note = MateWorkspaceMemory.displayNote(for: source)
        if !note.isEmpty { updateMateMemory(id: copy.id, note: note) }
        if let wake = wake(for: source.id) {
            setMateWake(mateID: copy.id, kind: wake.kind, match: wake.match, task: wake.task)
        }
        let now = Date()
        for routine in routines where routine.mateID == source.id {
            var cloned = MateRoutine.scheduled(mateID: copy.id, task: routine.task, schedule: routine.schedule,
                                               now: now, calendar: .current)
            cloned.maxRunMinutes = routine.maxRunMinutes
            cloned.pausedReason = "Copied paused so it doesn't run twice. Resume when ready."
            addRoutine(cloned)
        }
        syncMatePublications()
        return mateDirectory.mates.first { $0.id == copy.id } ?? copy
    }
}

// MARK: Share a mate as Markdown

extension CompanionManager {
    func mateMarkdown(id: UUID) -> String? {
        guard let mate = mateDirectory.mates.first(where: { $0.id == id }) else { return nil }
        let habits = agentHabits(for: mate)
        let wake = wake(for: mate.id)
        let document = MateMarkdownDocument(
            name: mate.name,
            job: mate.job,
            soul: mate.soul,
            brainRawValue: mate.brainRawValue,
            backupBrainRawValue: mate.backupBrainRawValue,
            howItWorks: habits.howItWorks,
            asksFirst: habits.asksFirst,
            memory: MateWorkspaceMemory.displayNote(for: mate),
            routines: routines.filter { $0.mateID == mate.id }.map {
                MateMarkdownRoutine(when: $0.schedule.instructionPhrase, task: $0.task, maxRunMinutes: $0.maxRunMinutes)
            },
            wakeKind: wake?.kind,
            wakeMatch: wake?.match ?? ""
        )
        return MateMarkdown.render(document)
    }

    /// Adds the agent a file describes. Its routines arrive paused, so an
    /// imported file never starts work on its own. Returns the new agent or
    /// a line to show.
    func importMate(_ document: MateMarkdownDocument) -> Result<Mate, MateImportError> {
        let taken = Set(mateDirectory.mates.map { FileMateStore.normalized($0.name) })
        var name = document.name
        var counter = 2
        while taken.contains(FileMateStore.normalized(name)) {
            name = "\(document.name) \(counter)"
            counter += 1
        }
        guard var mate = createMate(name: name, job: document.job, soul: document.soul, opensChat: false) else {
            return .failure(MateImportError(message: "Couldn't save the agent \(name)."))
        }
        mate.brainRawValue = document.brainRawValue
        mate.backupBrainRawValue = document.backupBrainRawValue
        mate.updatedAt = Date()
        _ = mateDirectory.upsertMate(mate)
        if !document.howItWorks.isEmpty || !document.asksFirst.isEmpty {
            saveAgentHabits(id: mate.id, howItWorks: document.howItWorks, asksFirst: document.asksFirst)
        }
        if !document.memory.isEmpty { updateMateMemory(id: mate.id, note: document.memory) }
        if let kind = document.wakeKind {
            setMateWake(mateID: mate.id, kind: kind, match: document.wakeMatch)
        }
        for item in document.routines {
            guard var routine = RoutinePhraseParser.parse(
                item.when.replacingOccurrences(of: "?", with: ""), mateID: mate.id, now: Date(), calendar: .current
            ) else { continue }
            routine.task = item.task
            routine.maxRunMinutes = item.maxRunMinutes
            routine.pausedReason = "Imported paused. Resume when you've read it."
            addRoutine(routine)
        }
        syncMatePublications()
        return .success(mateDirectory.mates.first { $0.id == mate.id } ?? mate)
    }
}

nonisolated struct MateImportError: Error, Equatable {
    let message: String
}
