import Foundation

func phoneClip(_ value: String, bytes: Int) -> String {
    let clean = value.unicodeScalars.filter { scalar in
        !CharacterSet.controlCharacters.contains(scalar) || scalar == "\n" || scalar == "\t"
    }
    let text = String(String.UnicodeScalarView(clean))
    guard text.utf8.count > bytes else { return text }
    return String(decoding: text.utf8.prefix(bytes - 3), as: UTF8.self) + "…"
}

extension CompanionManager {
    struct PhoneWorkspaceResult {
        var reply: PhonePilotReply
        var success = true
        var createdMate: UUID? = nil

        static func failure(_ text: String) -> Self { .init(reply: .init(text: text), success: false) }
    }

    func phoneWorkspace(shared: Bool, mateIDs: Set<UUID>) -> PhoneWorkspace {
        let questions: [PhoneQuestion] = shared ? mateInbox.pendingItems.compactMap { item -> PhoneQuestion? in
            guard mateIDs.contains(item.mateID),
                  case .question(let prompt, _, let choices) = item.kind else { return nil }
            return PhoneQuestion(id: item.id, mateName: phoneClip(item.mateName, bytes: 75), chatID: item.chatID,
                text: phoneClip(prompt, bytes: 400), choices: choices.prefix(4).map { phoneClip($0, bytes: 70) })
        }.prefix(10).map { $0 } : []
        return .init(sharing: shared, mainMateID: shared ? mateDirectory.defaultMateID : nil, questions: questions,
                     theme: shared ? AppTheme.currentHex : nil,
                     brains: shared ? phoneBrainOptions() : nil, supportsAttachments: shared,
                     supportsActivityPush: shared && PhoneActivityPush.shared.isConfigured, supportsStopReply: shared)
    }

    func phoneBrainOptions() -> [PhoneBrainOption] {
        var options: [PhoneBrainOption] = []
        let encoder = JSONEncoder()
        var remaining = 4_500
        for provider in MateAgentSetupController.shared.providers where provider.authenticated {
            let row = PhoneBrainOption(id: provider.id, name: phoneClip(provider.name, bytes: 75),
                models: provider.models.prefix(16).map { model in
                    .init(id: model, name: phoneClip(provider.modelNames[model] ?? model, bytes: 85),
                          efforts: provider.efforts[model] ?? [])
                })
            guard let bytes = try? encoder.encode(row).count, bytes + 1 <= remaining else {
                options.append(.init(id: provider.id, name: row.name, models: []))
                continue
            }
            options.append(row)
            remaining -= bytes + 1
        }
        return options
    }

    func phoneBrainOverride(_ choice: PhoneBrainChoice) -> MateAgentServeSession.BrainOverride? {
        guard let provider = MateAgentSetupController.shared.providers.first(where: {
            $0.authenticated && $0.id == choice.provider
        }) else { return nil }
        if let model = choice.model, !provider.models.contains(model) { return nil }
        if let effort = choice.effort,
           !(choice.model.flatMap { provider.efforts[$0] } ?? []).contains(effort) { return nil }
        return .init(provider: provider.id, model: choice.model, effort: choice.effort)
    }

    func phoneProfile(_ id: UUID) -> PhoneMateProfile? {
        guard let mate = mates.first(where: { $0.id == id && !$0.archived }) else { return nil }
        return .init(name: phoneClip(mate.name, bytes: 160), job: phoneClip(mate.job, bytes: 800),
            personality: phoneClip(mate.soul, bytes: 1_400), face: mate.faceAssetName,
            brain: mate.brainRawValue, memory: phoneClip(mate.memoryNote, bytes: 1_000))
    }

    private func phoneChat(_ session: ChatSession, mateID: UUID) -> PhoneChat {
        .init(id: session.id, mateID: mateID, title: phoneClip(session.title, bytes: 160),
              updatedAt: session.updatedAt, busy: mateInboxChatIsBusy(session.id),
              turnID: phoneReplyTurnID(mateID: mateID, chatID: session.id))
    }

    func phoneThread(mateID: UUID, chatID: UUID, before: UUID?) -> PhoneThread? {
        guard let session = phoneCompanionChats(for: mateID).first(where: { $0.id == chatID }) else { return nil }
        let upper: Int
        if let before {
            guard let index = session.messages.firstIndex(where: { $0.id == before }) else { return nil }
            upper = index
        } else { upper = session.messages.count }
        let lower = max(0, upper - 10)
        let messages = session.messages[lower..<upper].map { message in
            let display = message.role == .user ? MateChatDocuments.display(message.visibleText) : (message.visibleText, [])
            let attachments = (message.attachmentNames ?? []) + display.1
            return PhoneChatMessage(id: message.id, user: message.role == .user,
                text: phoneClip(display.0, bytes: 1_060), time: message.createdAt,
                attachmentNames: attachments.isEmpty ? nil : attachments.prefix(6).map { phoneClip($0, bytes: 75) })
        }
        return .init(chat: phoneChat(session, mateID: mateID), messages: messages,
                     older: lower > 0, appendsOlder: before != nil)
    }

    private func phoneRoutines(_ mateIDs: Set<UUID>) -> [PhoneRoutine] {
        routines.filter { mateIDs.contains($0.mateID) }.prefix(32).map { routine in
            .init(id: routine.id, mateID: routine.mateID, task: phoneClip(routine.task, bytes: 400),
                  schedule: routine.schedule.instructionPhrase, scheduleLabel: routine.schedule.summary, next: routine.nextRunAt,
                  enabled: routine.enabled && routine.pausedReason == nil,
                  lastResult: routine.lastStatusMessage.map { phoneClip($0, bytes: 180) })
        }
    }

    func phoneWorkspaceRequest(_ request: PhonePilotRequest, mateIDs permitted: Set<UUID>,
                               allowsMessages: Bool) async -> PhoneWorkspaceResult {
        let activeIDs = Set(mates.filter { !$0.archived }.map(\.id)).intersection(permitted)
        let mateID = request.mateID.flatMap { activeIDs.contains($0) ? $0 : nil }
        switch request.kind {
        case .chats:
            guard let mateID else { return .failure("This mate isn’t shared.") }
            let chats = phoneCompanionChats(for: mateID).prefix(45).map { phoneChat($0, mateID: mateID) }
            return .init(reply: .init(text: "Chats updated", chats: chats))
        case .transcript:
            guard let mateID, let id = request.chatID, let thread = phoneThread(mateID: mateID, chatID: id, before: request.before) else {
                return .failure("This chat or message is no longer available.")
            }
            return .init(reply: .init(text: "Chat updated", thread: thread))
        case .stopReply:
            guard allowsMessages, let mateID, let chatID = request.chatID, let turnID = request.itemID else {
                return .failure("This reply can’t be stopped from iPhone.")
            }
            let task = stopPhoneReply(mateID: mateID, chatID: chatID, turnID: turnID)
            await task?.value
            let stopped = task != nil
            return .init(reply: .init(text: stopped ? "Reply stopped." : "That reply already ended.",
                                     thread: phoneThread(mateID: mateID, chatID: chatID, before: nil)), success: stopped)
        case .newChat:
            guard let mateID else { return .failure("This mate isn’t shared.") }
            let chat = newPhoneCompanionChat(for: mateID)
            let thread = PhoneThread(chat: phoneChat(chat, mateID: mateID), messages: [], older: false)
            return .init(reply: .init(text: "Chat created", thread: thread))
        case .continueOnMac:
            guard let mateID, let id = request.chatID,
                  openMateInboxChat(mateID: mateID, chatID: id) else { return .failure("This chat isn’t available on the Mac.") }
            return .init(reply: .init(text: "Opened this chat on the Mac."))
        case .answer:
            guard allowsMessages else { return .failure("Choose Enable workspace access in iPhone companion settings on your Mac.") }
            guard let id = request.itemID,
                  let answer = request.message?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !answer.isEmpty, answer.utf8.count <= 2_500,
                  let item = mateInbox.pendingItems.first(where: { $0.id == id }),
                  activeIDs.contains(item.mateID), case .question = item.kind,
                  answerMateInboxItem(id: id, answer: answer) else {
                return .failure("This question is no longer available.")
            }
            return .init(reply: .init(text: "Answer sent", workspace: phoneWorkspace(shared: true, mateIDs: activeIDs)))
        case .saveProfile, .createMate:
            guard let profile = request.profile,
                  profile.name.utf8.count <= 160, profile.job.utf8.count <= 900, profile.personality.utf8.count <= 1_500,
                  (profile.memory?.utf8.count ?? 0) <= 1_100,
                  profile.brain == nil || AgentBrain(rawValue: profile.brain ?? "") != nil else {
                return .failure("Check the mate’s name, instructions, and brain, then try again.")
            }
            let builtInFace = PhoneMateProfile.faces.contains { $0.id == profile.face } ? profile.face : nil
            let brain = profile.brain.flatMap(AgentBrain.init(rawValue:))
            if request.kind == .createMate {
                guard let created = createMate(name: profile.name, job: profile.job, soul: profile.personality,
                                               opensChat: false, faceAssetName: builtInFace) else {
                    return .failure("A mate needs a distinct name and a job.")
                }
                if let brain { setMateBrainChoice(id: created.id, brain: brain) }
                return .init(reply: .init(text: "Created \(created.name).", profile: phoneProfile(created.id)), createdMate: created.id)
            }
            guard let mateID, let original = mates.first(where: { $0.id == mateID }) else { return .failure("This mate isn’t shared.") }
            let face = profile.face == "automatic" ? BlobatarCharacter.automaticToken : (builtInFace ?? original.faceAssetName)
            if let error = updateMateProfile(id: mateID, name: profile.name, job: profile.job, soul: profile.personality, faceAssetName: face) {
                return .failure(error)
            }
            setMateBrainChoice(id: mateID, brain: brain)
            if profile.editsMemory { updateMateMemory(id: mateID, note: profile.memory ?? "") }
            return .init(reply: .init(text: "Profile saved", profile: phoneProfile(mateID)))
        case .routines:
            return .init(reply: .init(text: "Routines updated", routines: phoneRoutines(activeIDs)))
        case .saveRoutine:
            guard allowsMessages else { return .failure("Choose Enable workspace access in iPhone companion settings on your Mac.") }
            guard let mateID, let task = request.message?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !task.isEmpty, task.utf8.count <= 1_200, let schedule = request.schedule, schedule.utf8.count <= 160,
                  schedule.split(whereSeparator: { !$0.isNumber }).allSatisfy({ (Int($0) ?? .max) <= 10_080 }) else {
                return .failure("Enter a task and schedule.")
            }
            if let id = request.itemID {
                guard routines.contains(where: { $0.id == id && $0.mateID == mateID }) else { return .failure("This routine isn’t shared.") }
                if let error = updateRoutine(id: id, task: task, schedulePhrase: schedule) { return .failure(error) }
            } else {
                guard var routine = RoutinePhraseParser.parse(schedule, mateID: mateID, now: .now, calendar: .current) else {
                    return .failure(RoutinePhraseParser.invalidScheduleMessage)
                }
                routine.task = task
                addRoutine(routine)
            }
            return .init(reply: .init(text: "Routine saved", routines: phoneRoutines(activeIDs)))
        case .routineAction:
            guard allowsMessages else { return .failure("Choose Enable workspace access in iPhone companion settings on your Mac.") }
            guard let id = request.itemID, let action = request.action,
                  routines.contains(where: { $0.id == id && activeIDs.contains($0.mateID) }) else {
                return .failure("This routine isn’t available for iPhone control.")
            }
            switch action {
            case .pause: pauseRoutine(id: id)
            case .resume: resumeRoutine(id: id)
            case .run: runRoutineNow(id: id)
            }
            return .init(reply: .init(text: action == .run ? "Run requested on the Mac." : "Routine updated",
                routines: phoneRoutines(activeIDs)))
        default:
            return .failure("This request isn’t available.")
        }
    }
}
