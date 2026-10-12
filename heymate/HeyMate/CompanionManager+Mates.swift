//
//  CompanionManager+Mates.swift
//  HeyMate
//
//  Mates and routines share the one chat send path. A routine never speaks
//  and never writes files unless that path escalates through plan approval.
//

import Foundation

@MainActor
private enum MatePreferenceWriteBack {
    static var isApplying = false
}

extension CompanionManager: MateRoutineRunning {

    func syncMatePublications() {
        mates = mateDirectory.mates
        routines = mateDirectory.routines
        activeMateID = mateDirectory.activeMateID
    }

    func finishMateLaunch() {
        let defaultID = mateDirectory.defaultMateID
        let loaded = chatHistoryStore.loadAll()
        savedChats = rememberConversationsEnabled ? loaded : []
        if rememberConversationsEnabled,
           let newest = loaded.first(where: { ($0.mateID ?? defaultID) == defaultID && !$0.messages.isEmpty }) {
            currentChat = newest
            mateDirectory.markRead(id: defaultID)
        } else {
            var session = ChatSession.empty()
            session.mateID = defaultID
            currentChat = session
        }
        mateDirectory.activeMateID = defaultID
        syncMatePublications()
        if let mate = mateDirectory.mates.first(where: { $0.id == defaultID }) {
            applyStoredPreferences(of: mate)
        }
    }

    func updateCurrentDraft(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        guard currentChat.draftText != normalized else { return }
        var session = currentChat
        session.draftText = normalized
        currentChat = session
        persistCurrentChatIfNeeded()
    }

    func openMate(id: UUID) {
        guard let mate = mateDirectory.mates.first(where: { $0.id == id }) else { return }
        cancelForegroundChatTurnForNavigation()
        persistCurrentChatIfNeeded()
        mateDirectory.activeMateID = id
        activeMateID = id
        mateDirectory.markRead(id: id)
        applyStoredPreferences(of: mate)
        if let newest = chatHistoryStore.loadAll().first(where: {
            ($0.mateID ?? mateDirectory.defaultMateID) == id && !$0.messages.isEmpty
        }) {
            currentChat = newest
        } else {
            var session = ChatSession.empty()
            session.mateID = id
            currentChat = session
        }
        streamingAssistantText = ""
        savedChats = rememberConversationsEnabled ? chatHistoryStore.loadAll() : []
        syncMatePublications()
    }

    /// A blank conversation with main HeyMate, leaving any open mate chat.
    func startNewMainChat() {
        let defaultID = mateDirectory.defaultMateID
        if (activeMateID ?? defaultID) != defaultID {
            openMate(id: defaultID)
        }
        startNewChat()
    }

    @discardableResult
    func createMate(
        name: String,
        job: String,
        soul: String = "",
        opensChat: Bool = true,
        faceAssetName: String? = nil,
        starter: MateStarterSuggestion? = nil
    ) -> Mate? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedJob = job.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedJob.isEmpty else { return nil }
        guard !mateDirectory.mateStore.isNameTaken(trimmedName) else { return nil }
        let now = Date()
        let mate = Mate(
            id: UUID(),
            name: trimmedName,
            job: trimmedJob,
            pinned: false,
            archived: false,
            unreadCount: 0,
            createdAt: now,
            updatedAt: now,
            memoryNote: "",
            folderPath: nil,
            soul: soul
        )
        var created = mate
        created.faceAssetName = faceAssetName
        guard mateDirectory.upsertMate(created) else { return nil }
        ensureMateFolder(id: mate.id)
        let saved = mateDirectory.mates.first { $0.id == mate.id } ?? created
        var firstChat = MateFirstMoment.chat(for: saved)
        if let starter { firstChat.firstMoment?.starter = starter }
        if rememberConversationsEnabled { chatHistoryStore.upsert(firstChat) }
        syncMatePublications()
        if opensChat {
            openMate(id: mate.id)
            currentChat = firstChat
        }
        return saved
    }

    /// Starts the approval-gated agent run a mate asked for with `[WORK: ...]`.
    /// A specialist works in its own folder; First Mate has none, so it uses
    /// the sandbox run. Either way the run plans first and waits for approval.
    func startMateWork(_ tasks: [String], mate: Mate?, brain: AgentBrain? = nil) {
        guard !tasks.isEmpty else { return }
        var workspaceURL: URL?
        if let mate, !mate.conductsOthers {
            ensureMateFolder(id: mate.id)
            if let path = mateDirectory.mates.first(where: { $0.id == mate.id })?.folderPath {
                workspaceURL = URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        let ownerID = mate?.id ?? mateDirectory.defaultMateID
        let source = backgroundRoutineSession ?? currentChat
        let chatOwner = AgentChatOwner(mateID: ownerID, chatID: source.id)
        if let pending = MateWorkGate.runAwaitingUser(ownedBy: ownerID, owners: mateRunOwners, runs: agentRuns) {
            postMateMessage(mateID: ownerID, text: MateWorkGate.reminder(for: pending))
            return
        }
        for task in tasks {
            if let workspaceURL {
                startAttachedAgent(prompt: task, workspaceURL: workspaceURL, brain: brain, chatOwner: chatOwner)
            } else {
                startSandboxAgent(prompt: task, brain: brain, chatOwner: chatOwner)
            }
        }
    }

    /// Reports a run's milestones in the chat that asked for it, so the mate
    /// comes back with results instead of waiting to be asked.
    func postMateRunUpdate(runID: UUID, event: AgentEvent) {
        guard let run = agentRunStore.run(id: runID), let owner = run.chatOwner else { return }
        if run.status.isTerminal, run.chatResultDeliveryKey == run.resultDeliveryKey { return }
        let text: String
        switch event {
        case .planReady:
            guard run.status == .awaitingPlanApproval else { return }
            let plan = run.planText.trimmingCharacters(in: .whitespacesAndNewlines)
            text = MateRunReport.planReady(plan: plan)
        case .finished:
            guard run.status == .succeeded || run.status == .cancelled else { return }
            text = run.status == .cancelled ? MateRunReport.cancelled(summary: run.latestAction) : MateRunReport.finished(
                summary: run.finalAnswer ?? AgentFinalResult.missingMessage,
                changedFileCount: run.workspaceChangeSummary?.totalCount
            )
        case .failed:
            guard run.status == .failed else { return }
            text = MateRunReport.failed(message: run.privateFinalResult ?? run.error)
        default:
            return
        }
        postAgentMessage(owner: owner, text: text)
        if run.status.isTerminal {
            _ = agentRunStore.update(id: runID) { $0.chatResultDeliveryKey = run.resultDeliveryKey }
            agentRuns = agentRunStore.loadAll()
        }
    }

    /// Direct agent invocations also need a saved initiating question. Mates
    /// that already appended their conversation pass an explicit owner instead.
    func prepareAgentChatOwner(prompt: String) -> AgentChatOwner {
        appendUserMessage(prompt)
        let source = backgroundRoutineSession ?? currentChat
        return AgentChatOwner(mateID: source.mateID ?? mateDirectory.defaultMateID, chatID: source.id)
    }

    func deliverPendingAgentResults() {
        for run in agentRunStore.loadAll() where run.status.isTerminal && run.chatOwner != nil {
            let event: AgentEvent = run.status == .failed
                ? .failed(message: run.error) : .finished(summary: run.summary)
            postMateRunUpdate(runID: run.id, event: event)
        }
    }

    /// A deleted chat stays deleted. Never redirect to the newest chat of a
    /// mate, and never save hidden history when conversation storage is off.
    private func postAgentMessage(owner: AgentChatOwner, text: String) {
        guard mateDirectory.mates.contains(where: { $0.id == owner.mateID }) else { return }
        let isVisible = currentChat.id == owner.chatID
        let isBackground = backgroundRoutineSession?.id == owner.chatID
        let source: ChatSession?
        if isBackground { source = backgroundRoutineSession }
        else if isVisible { source = currentChat }
        else if rememberConversationsEnabled { source = chatHistoryStore.loadAll().first { $0.id == owner.chatID } }
        else { source = nil }
        guard var session = source,
              (session.mateID ?? mateDirectory.defaultMateID) == owner.mateID else { return }
        session.messages.append(ChatMessage(id: UUID(), role: .assistant, text: text, createdAt: Date()))
        session.updatedAt = Date()
        if isVisible { currentChat = session }
        if isBackground { backgroundRoutineSession = session }
        if rememberConversationsEnabled {
            chatHistoryStore.upsert(session)
            savedChats = chatHistoryStore.loadAll()
        }
        if !isVisible { mateDirectory.incrementUnread(id: owner.mateID) }
        syncMatePublications()
    }

    func postMateMessage(mateID: UUID, text: String) {
        let openMateID = currentChat.mateID ?? mateDirectory.defaultMateID
        if openMateID == mateID, backgroundRoutineSession == nil, activeRoutineTurn == nil {
            appendAssistantMessage(text)
            return
        }
        var session = sessionForRoutineAppend(mateID: mateID)
        session.messages.append(ChatMessage(id: UUID(), role: .assistant, text: text, createdAt: Date()))
        session.updatedAt = Date()
        chatHistoryStore.upsert(session)
        mateDirectory.incrementUnread(id: mateID)
        savedChats = rememberConversationsEnabled ? chatHistoryStore.loadAll() : []
        syncMatePublications()
    }

    func ensureMateFolder(id: UUID) {
        guard let mate = mateDirectory.mates.first(where: { $0.id == id }) else { return }
        if mate.folderPath == nil || !FileManager.default.fileExists(atPath: mate.folderPath ?? "") {
            guard let folder = try? MateWorkspace.ensureFolder(
                for: mate,
                projectsRoot: MateWorkspace.projectsRoot()
            ) else { return }
            mateDirectory.updateFolderPath(id: id, path: folder.path)
        }
        refreshMateWorkspaceMemory(id: id)
        syncMatePublications()
    }

    func forgetMateFolder(id: UUID) {
        mateDirectory.clearFolderPath(id: id)
        syncMatePublications()
    }

    @discardableResult
    func trashMateFolder(id: UUID) -> Bool {
        guard let path = mateDirectory.mates.first(where: { $0.id == id })?.folderPath else { return false }
        do {
            try MateWorkspace.moveToTrash(path: path)
        } catch {
            return false
        }
        mateDirectory.clearFolderPath(id: id)
        syncMatePublications()
        return true
    }

    func toggleMatePinned(id: UUID) {
        guard let mate = mates.first(where: { $0.id == id }) else { return }
        mateDirectory.setPinned(id: id, pinned: !mate.pinned)
        syncMatePublications()
    }

    func archiveMate(id: UUID) {
        mateDirectory.archiveMate(id: id)
        syncMatePublications()
        guard activeMateID == id else { return }
        if let fallback = mates.first(where: { !$0.archived }) {
            openMate(id: fallback.id)
        }
    }

    func unarchiveMate(id: UUID) {
        mateDirectory.unarchiveMate(id: id)
        syncMatePublications()
    }

    @discardableResult
    func deleteMate(id: UUID) -> Bool {
        guard mateDirectory.mates.contains(where: { $0.id == id }) else { return false }
        guard id != mateDirectory.defaultMateID else { return false }
        let openChatBelongs = (currentChat.mateID ?? mateDirectory.defaultMateID) == id
        let viewingDeletedMate = openChatBelongs || activeMateID == id
        let routineBelongs = activeRoutineTurn?.mateID == id
        if routineBelongs || activeHandoffMateID == id {
            cancelInFlightChatTurn()
        } else if openChatBelongs {
            cancelForegroundChatTurnForNavigation()
        }
        if routineBelongs {
            clearRoutineDelivery()
        }
        if viewingDeletedMate {
            currentChat = ChatSession.empty()
            streamingAssistantText = ""
        }
        let defaultID = mateDirectory.defaultMateID
        for session in chatHistoryStore.loadAll() where (session.mateID ?? defaultID) == id {
            chatHistoryStore.delete(id: session.id)
        }
        mateDirectory.routineStore.deleteAll(mateID: id)
        for item in memoryRepository.loadAll() where item.mateID == id {
            memoryRepository.delete(id: item.id)
        }
        memoryItems = memoryRepository.loadAll()
        if let face = mateDirectory.mates.first(where: { $0.id == id })?.faceAssetName {
            MateFaceStore.deleteIfCustom(face)
        }
        guard mateDirectory.deleteMate(id: id) else { return false }
        savedChats = rememberConversationsEnabled ? chatHistoryStore.loadAll() : []
        syncMatePublications()
        if viewingDeletedMate {
            openMate(id: mateDirectory.defaultMateID)
        }
        return true
    }

    func persistBrainOnActiveMate() {
        guard !MatePreferenceWriteBack.isApplying else { return }
        let id = mateDirectory.activeMateID
        guard var mate = mateDirectory.mates.first(where: { $0.id == id }) else { return }
        let raw = selectedBrain.rawValue
        guard mate.brainRawValue != raw else { return }
        mate.brainRawValue = raw
        mate.updatedAt = Date()
        guard mateDirectory.upsertMate(mate) else { return }
        syncMatePublications()
    }

    func applyStoredPreferences(of mate: Mate) {
        MatePreferenceWriteBack.isApplying = true
        defer { MatePreferenceWriteBack.isApplying = false }
        if let raw = mate.brainRawValue, let brain = AgentBrain(rawValue: raw), selectedBrain != brain {
            setSelectedBrain(brain)
        }
    }

    func markMateUnread(id: UUID) {
        mateDirectory.markUnread(id: id)
        syncMatePublications()
    }

    func markMateRead(id: UUID) {
        mateDirectory.markRead(id: id)
        syncMatePublications()
    }

    func updateMateMemory(id: UUID, note: String) {
        guard let mate = mateDirectory.mates.first(where: { $0.id == id }) else { return }
        let stored: String
        if let path = mate.folderPath, FileManager.default.fileExists(atPath: path) {
            stored = MateWorkspaceMemory.replaceNotes(
                note,
                for: mate,
                in: URL(fileURLWithPath: path, isDirectory: true)
            )
        } else {
            stored = note
        }
        mateDirectory.updateMemoryNote(id: id, note: stored)
        syncMatePublications()
    }

    /// Nil means the profile was saved. A string is the reason it was not.
    func updateMateProfile(
        id: UUID,
        name: String,
        job: String,
        soul: String,
        faceAssetName: String?
    ) -> String? {
        guard let mate = mateDirectory.mates.first(where: { $0.id == id }) else {
            return "That agent is gone."
        }
        let previousFace = mate.faceAssetName
        let edited = MateProfileEdit.applying(
            MateProfileEdit.Draft(
                name: name,
                job: job,
                soul: soul,
                faceAssetName: faceAssetName
            ),
            to: mate,
            now: Date(),
            nameTaken: { mateDirectory.mateStore.isNameTaken($0, excluding: id) }
        )
        switch edited {
        case .failure(.missingNameOrJob):
            return "An agent needs a name and what it does."
        case .failure(.nameTaken):
            return "That name is already taken."
        case .success(let updated):
            guard mateDirectory.upsertMate(updated) else { return "That name is already taken." }
            if previousFace != updated.faceAssetName {
                MateFaceStore.deleteIfCustom(previousFace)
            }
            refreshMateWorkspaceMemory(id: updated.id)
            syncMatePublications()
            return nil
        }
    }

    /// Rewrites AGENTS.md from the mate when their folder already exists.
    private func refreshMateWorkspaceMemory(id: UUID) {
        guard let mate = mateDirectory.mates.first(where: { $0.id == id }),
              let path = mate.folderPath,
              FileManager.default.fileExists(atPath: path) else { return }
        let body = MateWorkspaceMemory.sync(mate: mate, folder: URL(fileURLWithPath: path, isDirectory: true))
        if mate.memoryNote != body {
            mateDirectory.updateMemoryNote(id: id, note: body)
        }
    }

    func addRoutine(_ routine: MateRoutine) {
        mateDirectory.addRoutine(routine)
        syncMatePublications()
    }

    func pauseRoutine(id: UUID) {
        mateDirectory.pauseRoutine(id: id)
        syncMatePublications()
    }

    func resumeRoutine(id: UUID) {
        mateDirectory.resumeRoutine(id: id, now: Date(), calendar: .current)
        syncMatePublications()
    }

    func deleteRoutine(id: UUID) {
        mateDirectory.deleteRoutine(id: id)
        syncMatePublications()
    }

    func runRoutineNow(id: UUID) {
        guard let routine = routines.first(where: { $0.id == id }) else { return }
        mateRoutineScheduler.run(routine)
    }

    var isChatTurnBusy: Bool {
        if isResponseInFlight || activeRoutineTurn != nil || activeHandoffMateID != nil { return true }
        switch state {
        case .idle, .error:
            return false
        default:
            return true
        }
    }

    func dueRoutines(now: Date) -> [MateRoutine] {
        routines.filter { MateRoutineAccounting.isDue($0, now: now) }
    }

    func markRoutineWaiting(id: UUID) {
        guard let routine = routines.first(where: { $0.id == id }) else { return }
        mateDirectory.apply(MateRoutineAccounting.markWaitingForNetwork(routine))
        syncMatePublications()
    }

    func noteRoutineFailure(id: UUID, message: String, now: Date) {
        guard let routine = routines.first(where: { $0.id == id }) else { return }
        mateDirectory.apply(MateRoutineAccounting.recordFailure(
            routine,
            now: now,
            calendar: .current,
            status: message
        ))
        syncMatePublications()
    }

    func kickoffRoutine(_ routine: MateRoutine) -> MateRoutineKickoff {
        kickoffRoutine(routine, deliverySession: nil)
    }

    func kickoffRoutine(_ routine: MateRoutine, deliverySession: ChatSession?) -> MateRoutineKickoff {
        if isChatTurnBusy || openCodeTrainingNotice != nil { return .busy }
        let openMateID = currentChat.mateID ?? mateDirectory.defaultMateID
        let session = deliverySession ?? (openMateID == routine.mateID
            ? currentChat : sessionForRoutineAppend(mateID: routine.mateID))
        let visible = session.id == currentChat.id
        if !visible { backgroundRoutineSession = session }
        activeRoutineTurn = ActiveRoutineTurn(
            routineID: routine.id,
            mateID: routine.mateID,
            task: routine.task,
            writesIntoOpenChat: visible
        )
        if typedMessageBusyReason != nil {
            clearRoutineDelivery()
            return .busy
        }
        let accepted = sendTypedMessage(routine.task)
        if !accepted {
            clearRoutineDelivery()
            if openCodeTrainingNotice != nil { return .busy }
            return .failed("Couldn't send that routine.")
        }
        if !isResponseInFlight {
            completeActiveRoutineTurn(.success("Started."))
        }
        return .started
    }

    func completeActiveRoutineTurn(_ outcome: MateRoutineTurnOutcome) {
        guard let turn = activeRoutineTurn else { return }
        let visible = turn.writesIntoOpenChat
        let mateID = turn.mateID
        let routineID = turn.routineID
        if rememberConversationsEnabled, let background = backgroundRoutineSession {
            chatHistoryStore.upsert(background)
        }
        clearRoutineDelivery()
        streamingAssistantText = ""
        guard var routine = mateDirectory.routines.first(where: { $0.id == routineID }) else {
            savedChats = rememberConversationsEnabled ? chatHistoryStore.loadAll() : []
            syncMatePublications()
            return
        }
        switch outcome {
        case .success(let status):
            routine = MateRoutineAccounting.recordSuccess(
                routine,
                now: Date(),
                calendar: .current,
                status: status
            )
        case .failure(let message):
            routine = MateRoutineAccounting.recordFailure(
                routine,
                now: Date(),
                calendar: .current,
                status: message
            )
        case .cancelled:
            routine = MateRoutineAccounting.recordInterrupted(routine, now: Date(), calendar: .current)
        }
        mateDirectory.apply(routine)
        if visible {
            mateDirectory.markRead(id: mateID)
        } else if outcome != .cancelled {
            mateDirectory.incrementUnread(id: mateID)
        }
        savedChats = rememberConversationsEnabled ? chatHistoryStore.loadAll() : []
        syncMatePublications()
    }

    func publishStreamingAssistantText(_ text: String) {
        guard backgroundRoutineSession == nil else { return }
        streamingAssistantText = text
    }

    /// Mate and routine commands stay on this Mac. They do not call the model.
    func acceptLocalMateCommand(_ text: String) -> Bool {
        guard activeRoutineTurn == nil else { return false }
        if acceptMateCreation(text) { return true }
        if acceptRoutinePhrase(text) { return true }
        if acceptMeetingCommand(text) { return true }
        if acceptImagePlayground(text) { return true }
        return false
    }

    func beginHandoff(_ handoff: MateHandoff, deliverySession: ChatSession? = nil) {
        guard mateDirectory.mates.contains(where: { $0.id == handoff.mateID && !$0.archived }) else {
            scheduleNextHandoffIfNeeded()
            return
        }
        let openMateID = currentChat.mateID ?? mateDirectory.defaultMateID
        let session = deliverySession ?? (openMateID == handoff.mateID
            ? currentChat : sessionForRoutineAppend(mateID: handoff.mateID))
        if holdForOpenCodeTrainingConsent(
            handoff.instruction, imageAttachments: [], handoff: handoff, deliverySession: session,
            explicitExecutor: HeadlessExecutor.explicitlyRequested(in: handoff.instruction)
        ) { return }
        activeHandoffMateID = handoff.mateID
        activeHandoffHops = handoff.hops
        if session.id != currentChat.id { backgroundRoutineSession = session }
        let accepted = sendTypedMessage(handoff.deliveredInstruction)
        let startedModelTurn = accepted && isResponseInFlight
        if !startedModelTurn {
            activeHandoffMateID = nil
            activeHandoffHops = 0
            backgroundRoutineSession = nil
            scheduleNextHandoffIfNeeded()
        }
    }

    func completeActiveHandoff(succeeded: Bool) {
        guard let mateID = activeHandoffMateID else { return }
        let visible = backgroundRoutineSession == nil
        if rememberConversationsEnabled, let background = backgroundRoutineSession {
            chatHistoryStore.upsert(background)
        }
        activeHandoffMateID = nil
        activeHandoffHops = 0
        backgroundRoutineSession = nil
        streamingAssistantText = ""
        if !visible {
            mateDirectory.incrementUnread(id: mateID)
        }
        if !succeeded {
            pendingHandoffs.removeAll()
        }
        savedChats = rememberConversationsEnabled ? chatHistoryStore.loadAll() : []
        syncMatePublications()
    }

    private func acceptMeetingCommand(_ text: String) -> Bool {
        guard let command = MeetingCommand.parse(text) else { return false }
        switch command {
        case .start:
            if meetingNotes.isRecording {
                appendUserMessage(text)
                appendAssistantMessage("Meeting notes are already on. Say stop meeting notes when you're done. I keep the words, not the audio.")
                return true
            }
            let title = "Meeting \(Self.meetingTitleClock.string(from: Date()))"
            meetingNotes.start(title: title)
            isRecordingMeeting = true
            appendUserMessage(text)
            appendAssistantMessage("Meeting notes are on. I'll keep what we say in this chat until you say stop meeting notes. The audio stays on this Mac and is not saved.")
        case .stop:
            appendUserMessage(text)
            if let note = meetingNotes.stop() {
                isRecordingMeeting = false
                appendAssistantMessage("Meeting notes stopped. \(note.lines.count) lines are saved in \(note.title).")
            } else {
                appendAssistantMessage("Meeting notes weren't on.")
            }
        }
        return true
    }

    private func acceptImagePlayground(_ text: String) -> Bool {
        guard let concept = ImagePlaygroundRequest.concept(in: text) else { return false }
        appendUserMessage(text)
        guard OnDeviceLanguageAvailability.imagePlaygroundIsAvailable else {
            appendAssistantMessage("Image Playground isn't available on this Mac. Turn it on in System Settings if Apple Intelligence offers it.")
            return true
        }
        imagePlaygroundConcept = concept
        appendAssistantMessage("Opening Image Playground for \(concept).")
        return true
    }

    func adoptImagePlaygroundFile(at url: URL) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("heymate/playground", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            appendAssistantMessage("Image Playground saved a picture at \(destination.path).")
        } catch {
            appendAssistantMessage("Image Playground finished, and I couldn't copy the picture. It is still at \(url.path).")
        }
    }

    private static let meetingTitleClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()

    private func acceptMateCreation(_ text: String) -> Bool {
        guard let requests = MateCreationParser.parseRequests(text), !requests.isEmpty else { return false }
        if let takenName = requests.compactMap(\.name).first(where: { mateDirectory.mateStore.isNameTaken($0) }) {
            appendUserMessage(text)
            appendAssistantMessage("An agent named \(takenName) already exists. Choose a different name or edit that agent.")
            return true
        }
        var existingNames = mateDirectory.mates.filter { !$0.archived }.map(\.name)
        var created: [Mate] = []
        for request in requests {
            let name = request.name ?? MateNameGenerator.name(for: request.job, existingNames: existingNames)
            guard let mate = createMate(name: name, job: request.job, soul: request.soul, opensChat: false) else { continue }
            existingNames.append(name)
            created.append(mate)
        }
        guard let first = created.first else {
            appendUserMessage(text)
            appendAssistantMessage("I couldn't save that agent. Try creating it again from New agent.")
            return true
        }
        syncMatePublications()
        openMate(id: first.id)
        // With history off, keep the first moment only in this open chat.
        if currentChat.messages.isEmpty { currentChat = MateFirstMoment.chat(for: first) }
        return true
    }

    private func acceptRoutinePhrase(_ text: String) -> Bool {
        let mateID = activeMateID ?? mateDirectory.defaultMateID
        guard let routine = RoutinePhraseParser.parse(
            text,
            mateID: mateID,
            now: Date(),
            calendar: .current
        ) else { return false }
        mateDirectory.addRoutine(routine)
        syncMatePublications()
        appendUserMessage(text)
        let mateName = mates.first(where: { $0.id == mateID })?.name ?? Mate.defaultName
        appendAssistantMessage("Saved a routine for \(mateName): \(routine.task). \(routine.schedule.summary).")
        return true
    }

    func sessionForRoutineAppend(mateID: UUID) -> ChatSession {
        if let existing = chatHistoryStore.loadAll().first(where: {
            $0.mateID == mateID && !$0.messages.isEmpty
        }) {
            return existing
        }
        var session = ChatSession.empty()
        session.mateID = mateID
        return session
    }

    private func clearRoutineDelivery() {
        activeRoutineTurn = nil
        backgroundRoutineSession = nil
    }
}
