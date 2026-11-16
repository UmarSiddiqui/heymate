//
//  MateInbox.swift
//  HeyMate
//
//  Everything across all mates that needs the person's attention or lets them
//  undo an autonomous change: NEEDS INPUT questions, browser sign-in requests,
//  failed routine alerts, and applied setup/profile receipts. Answering a
//  paused item resumes that mate's exact conversation in the background.
//

import Combine
import Foundation

nonisolated struct MateChangeUndo: Codable, Equatable, Sendable {
    enum Target: String, Codable, Sendable {
        case profile
        case memory
        case skills
    }
    var target: Target
    var mateID: UUID
    var previousName: String?
    var previousJob: String?
    var previousSoul: String?
    var previousHowItWorks: [String]?
    var previousAsksFirst: [String]?
    var previousFolderPath: String?
    var previousMemoryNote: String?
    var previousSkillNames: [String]?
}

nonisolated struct MateInboxItem: Codable, Equatable, Identifiable, Sendable {
    enum Kind: Codable, Equatable, Sendable {
        case question(prompt: String, defaultAnswer: String?, choices: [String])
        case signIn(site: String, urlString: String?, reason: String, profileID: String?)
        case routineFailed(routineID: UUID, summary: String)
        case appliedChange(summary: String, undo: MateChangeUndo?)
        /// Work a mate proposed on its own heartbeat (MateHeartbeat.swift). Expires after a day.
        case proposal(MateHeartbeatProposal)
    }

    let id: UUID
    let mateID: UUID
    var mateName: String
    let chatID: UUID
    let createdAt: Date
    var resolvedAt: Date?
    var resolutionSummary: String?
    var kind: Kind
    /// Context of the paused task so answering resumes the mate cleanly.
    var resumeTaskContext: String?
    var workID: UUID? = nil

    var isPendingAttention: Bool {
        guard resolvedAt == nil else { return false }
        switch kind {
        case .question, .signIn, .routineFailed:
            return true
        case .appliedChange:
            return false
        case .proposal(let proposal):
            return !proposal.isExpired()
        }
    }

    var proposal: MateHeartbeatProposal? {
        if case .proposal(let proposal) = kind { return proposal }
        return nil
    }

    var canUndo: Bool {
        guard resolvedAt == nil, case .appliedChange(_, let undo) = kind else { return false }
        return undo != nil
    }
}

nonisolated enum MateNeedsInputParser {
    struct Extracted: Equatable {
        let question: String
        let defaultAnswer: String?
        let choices: [String]
    }

    /// Parses trailing `NEEDS INPUT: ...` (and optional `Default: ...` /
    /// `Options: a | b`) from an unattended routine or hand-off reply.
    static func extract(from text: String) -> Extracted? {
        let lines = text.components(separatedBy: .newlines)
        var question: String?
        var defaultAnswer: String?
        var choices: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let value = strippedPrefix("NEEDS INPUT:", in: line) {
                if !value.isEmpty { question = value }
            } else if question != nil, let value = strippedPrefix("Default:", in: line) {
                if !value.isEmpty { defaultAnswer = value }
            } else if question != nil, let value = strippedPrefix("Choices:", in: line) ?? strippedPrefix("Options:", in: line) {
                choices = value
                    .split(separator: "|")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        }
        guard let question, !question.isEmpty else { return nil }
        return Extracted(
            question: String(question.prefix(600)),
            defaultAnswer: defaultAnswer.map { String($0.prefix(300)) },
            choices: Array(choices.prefix(6))
        )
    }

    private static func strippedPrefix(_ prefix: String, in line: String) -> String? {
        let cleaned = line.replacingOccurrences(of: "`", with: "")
        guard cleaned.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil else { return nil }
        return String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class MateInboxStore: ObservableObject {
    static let shared = MateInboxStore()
    static let maximumKeptItems = 120

    @Published private(set) var items: [MateInboxItem] = []
    @Published private(set) var work: [MateInboxWork] = []
    private let fileURL: URL
    private let workURL: URL
    private var transientWork = Set<UUID>()

    init(fileURL: URL = HeyMateDataDirectory.url.appendingPathComponent("mate-inbox.json")) {
        self.fileURL = fileURL
        workURL = fileURL.deletingPathExtension().appendingPathExtension("work.json")
        load()
        if let data = try? Data(contentsOf: workURL),
           let decoded = try? JSONDecoder().decode([MateInboxWork].self, from: data) {
            work = decoded.map {
                var entry = $0
                if entry.state == .running { entry.finish(.stopped, result: "HeyMate closed before this turn finished.") }
                return entry
            }
        }
    }

    var pendingItems: [MateInboxItem] {
        items.filter(\.isPendingAttention).sorted { $0.createdAt > $1.createdAt }
    }

    var recentUndoableChanges: [MateInboxItem] {
        items.filter(\.canUndo).sorted { $0.createdAt > $1.createdAt }
    }

    var pendingCount: Int { pendingItems.count }

    func pendingItems(forMate mateID: UUID) -> [MateInboxItem] {
        pendingItems.filter { $0.mateID == mateID }
    }

    @discardableResult
    func record(_ item: MateInboxItem) -> MateInboxItem {
        if case .question(let prompt, _, _) = item.kind,
           let existing = pendingItems.first(where: {
               guard $0.mateID == item.mateID, $0.chatID == item.chatID,
                     $0.workID == item.workID, case .question(let previous, _, _) = $0.kind else { return false }
               return previous.caseInsensitiveCompare(prompt) == .orderedSame
           }) { return existing }
        // Deduplicate identical open sign-in or routine failure items per mate.
        if case .signIn(let site, _, _, _) = item.kind {
            items.removeAll {
                guard $0.resolvedAt == nil, $0.mateID == item.mateID, $0.chatID == item.chatID,
                      case .signIn(let existingSite, _, _, _) = $0.kind else { return false }
                return existingSite.caseInsensitiveCompare(site) == .orderedSame
            }
        }
        if case .routineFailed(let routineID, _) = item.kind {
            items.removeAll {
                guard $0.resolvedAt == nil, case .routineFailed(let existingID, _) = $0.kind else { return false }
                return existingID == routineID
            }
        }
        items.insert(item, at: 0)
        if items.count > Self.maximumKeptItems {
            items = Array(items.prefix(Self.maximumKeptItems))
        }
        save()
        return item
    }

    func beginWork(id: UUID, owner: AgentChatOwner, mateName: String, title: String, background: Bool, remember: Bool,
                   originalWorkID: UUID? = nil) {
        if !remember { transientWork.insert(id) }
        work.insert(MateInboxWork(id: id, mateID: owner.mateID, chatID: owner.chatID, mateName: mateName,
            title: MateInboxWork.safeText(title.components(separatedBy: .newlines).first ?? title, limit: 130),
            background: background, originalWorkID: originalWorkID), at: 0)
        if background { saveWork() }
    }

    func activeWorkID(for owner: AgentChatOwner) -> UUID? {
        work.first { $0.mateID == owner.mateID && $0.chatID == owner.chatID && $0.state == .running }?.id
    }

    func markResumed(_ id: UUID) {
        guard let index = work.firstIndex(where: { $0.id == id }) else { return }
        work[index].state = .resumed
        saveWork()
    }

    func recordWorkEvent(_ id: UUID, type: String, payload: JSONValue?) {
        guard let index = work.firstIndex(where: { $0.id == id && $0.state == .running }) else { return }
        var entry = work[index]
        entry.record(event: type, payload: payload)
        guard entry != work[index] else { return }
        work[index] = entry
        saveWork()
    }

    func recordWorkStep(_ id: UUID, stepID: String, title: String, state: MateInboxWork.Step.State,
                        failure: MateInboxWork.Step.Failure? = nil) {
        guard let index = work.firstIndex(where: { $0.id == id && $0.state == .running }) else { return }
        work[index].recordStep(id: stepID, title: MateInboxWork.safeText(title, limit: 160), state: state, failure: failure)
        saveWork()
    }

    func finishWork(_ id: UUID, state: MateInboxWork.State, result: String? = nil, resultKey: String? = nil) {
        guard let index = work.firstIndex(where: { $0.id == id && $0.state == .running }) else { return }
        let state = pendingItems.contains { $0.workID == id } ? .needsInput : state
        work[index].finish(state, result: result.map { MateInboxWork.safeText($0, limit: 1_600) })
        work[index].resultKey = resultKey
        if !work[index].isVisible {
            work.remove(at: index)
            transientWork.remove(id)
        }
        let retained = Set(work.filter { $0.state == .running || $0.state == .needsInput }.map(\.id)
            + work.filter { $0.state != .running && $0.state != .needsInput }.prefix(60).map(\.id))
        work.removeAll { !retained.contains($0.id) }
        transientWork.formIntersection(retained)
        saveWork()
    }

    func resolve(id: UUID, summary: String? = nil, resumed: Bool = false, now: Date = Date()) -> MateInboxItem? {
        guard let index = items.firstIndex(where: { $0.id == id && $0.resolvedAt == nil }) else { return nil }
        items[index].resolvedAt = now
        items[index].resolutionSummary = summary
        let updated = items[index]
        if let workID = updated.workID,
           !pendingItems.contains(where: { $0.workID == workID }),
           let workIndex = work.firstIndex(where: { $0.id == workID && $0.state == .needsInput }) {
            work[workIndex].state = resumed ? .resumed : .stopped
            saveWork()
        }
        save()
        return updated
    }

    func dismissAllResolved() {
        items.removeAll { $0.resolvedAt != nil }
        save()
    }

    func removeItems(forMate mateID: UUID) {
        items.removeAll { $0.mateID == mateID }
        work.removeAll { $0.mateID == mateID }
        save()
        saveWork()
    }

    func removeItems(forChat chatID: UUID) {
        items.removeAll { $0.chatID == chatID }
        work.removeAll { $0.chatID == chatID }
        save()
        saveWork()
    }

    func removeAll() {
        items.removeAll()
        work.removeAll()
        transientWork.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: workURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([MateInboxItem].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items.filter { item in
            item.workID.map { !transientWork.contains($0) } ?? true
        }) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private func saveWork() {
        let durable = work.filter { $0.isVisible && !transientWork.contains($0.id) }
        guard let data = try? JSONEncoder().encode(durable) else { return }
        try? FileManager.default.createDirectory(at: workURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? DetachedAgentSecureFiles.atomicDurableWrite(data, to: workURL)
    }
}

extension CompanionManager {
    var mateInbox: MateInboxStore { MateInboxStore.shared }

    func finishMateInboxWork(
        id: UUID, owner: AgentChatOwner, reply: String, task: String, resultKey: String?, allowTextQuestion: Bool
    ) {
        if allowTextQuestion, !mateInbox.pendingItems.contains(where: { $0.workID == id }),
           let question = MateNeedsInputParser.extract(from: reply) {
            let mateName = mateDirectory.mates.first(where: { $0.id == owner.mateID })?.name ?? "Mate"
            mateInbox.record(MateInboxItem(id: UUID(), mateID: owner.mateID, mateName: mateName, chatID: owner.chatID,
                createdAt: Date(), resolvedAt: nil, resolutionSummary: nil,
                kind: .question(prompt: question.question, defaultAnswer: question.defaultAnswer, choices: question.choices),
                resumeTaskContext: String(task.prefix(2_000)), workID: id))
        }
        let preview = AgentReplyBlocks.extract(from: reply).spokenText
        mateInbox.finishWork(id, state: .resultReady, result: preview, resultKey: resultKey)
    }

    func presentMateWorkRequest(
        _ request: MateAgentServeSession.ServerRequest, owner: AgentChatOwner, workID: UUID, task: String
    ) async -> JSONValue? {
        guard !Task.isCancelled, case .object(let params) = request.params else { return nil }
        if request.method == "clarify", case .array(let questions) = params["questions"],
           questions.count == 1, case .object(let fields) = questions[0],
           case .string(let question) = fields["question"] {
            if !mateInbox.pendingItems.contains(where: { $0.workID == workID }) {
                let choices: [String]
                if case .array(let values) = fields["choices"] {
                    choices = values.compactMap { if case .string(let text) = $0 { text } else { nil } }
                } else { choices = [] }
                let result = askPersonFromTalkTool(arguments: ["question": question, "choices": choices, "task_context": task], owner: owner)
                guard !result.isError else { return nil }
            }
            return .object(["deferred": .bool(true)])
        }
        guard request.method == "approval",
              let tool = MateAgentApprovalPolicy.toolName(params) else {
            return await MateAgentServeRequestPresenter.shared.respond(to: request)
        }
        if MateAgentApprovalPolicy.autoAllows(params, mode: ApprovalMode.current(forMateID: owner.mateID)) {
            return .object(["choice": .string("once"), "all": .bool(false)])
        }
        guard !mateInbox.pendingItems.contains(where: { $0.workID == workID }) else { return nil }
        let details = ["subject", "description"].compactMap { key -> String? in
            if case .string(let text) = params[key], !text.isEmpty { return text }
            return nil
        }.joined(separator: "\n\n")
        guard !details.isEmpty else { return await MateAgentServeRequestPresenter.shared.respond(to: request) }
        let mateName = mateDirectory.mates.first(where: { $0.id == owner.mateID })?.name ?? "Mate"
        let approval = ConnectorToolApprovalRequest(connectorDisplayName: mateName, toolName: tool,
            argumentsSummary: AgentReceiptPrivacy.privateToolDetails(details),
            risk: ["write", "edit"].contains(tool) ? .reversibleWrite : .externalSideEffect,
            actions: [MateInboxWork.toolTitle(tool)], owner: owner)
        if case .string(let rule) = params[MateApprovalRuleGate.offerKey], !rule.isEmpty {
            MateApprovalRuleGate.offerOnCard(approval.id, summary: rule)
        }
        let outcome = await requestMateWorkApproval(approval)
        let remember = MateApprovalRuleGate.finishCard(approval.id)
        guard outcome == .approved, !Task.isCancelled else { return nil }
        return MateApprovalRuleGate.allowOnce(remember: remember)
    }

    func requestMateWorkApproval(_ request: ConnectorToolApprovalRequest) async -> ConnectorToolCoordinator.Outcome {
        let workID = request.owner.flatMap { mateInbox.activeWorkID(for: $0) }
        if let workID {
            mateInbox.recordWorkStep(workID, stepID: request.id.uuidString, title: "Waiting for permission", state: .running)
        }
        let outcome = await connectorToolCoordinator.requestApprovalOutcome(for: request)
        if let workID {
            let title = switch outcome {
            case .approved: "Permission granted"
            case .denied: "Permission not granted"
            case .expired: "Permission request expired"
            }
            mateInbox.recordWorkStep(workID, stepID: request.id.uuidString, title: title,
                state: outcome == .approved ? .finished : .failed)
        }
        return outcome
    }

    /// Tool `ask_person`: files a question in the cross-mate Inbox and tells
    /// the mate to pause this step until the person answers.
    func askPersonFromTalkTool(arguments: [String: Any], owner: AgentChatOwner) -> (text: String, isError: Bool) {
        let rawQuestion = (arguments["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawQuestion.isEmpty else {
            return ("Provide a plain one-sentence question in `question`.", true)
        }
        let defaultChoice = (arguments["default_choice"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let choices = (arguments["choices"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let context = (arguments["task_context"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let mateName = mateDirectory.mates.first(where: { $0.id == owner.mateID })?.name ?? "Agent"
        let item = MateInboxItem(
            id: UUID(),
            mateID: owner.mateID,
            mateName: mateName,
            chatID: owner.chatID,
            createdAt: Date(),
            resolvedAt: nil,
            resolutionSummary: nil,
            kind: .question(
                prompt: String(rawQuestion.prefix(600)),
                defaultAnswer: defaultChoice?.isEmpty == false ? String(defaultChoice!.prefix(300)) : nil,
                choices: Array(choices.prefix(6))
            ),
            resumeTaskContext: context?.isEmpty == false ? String(context!.prefix(2_000)) : nil,
            workID: mateInbox.activeWorkID(for: owner)
        )
        mateInbox.record(item)
        if currentChat.id != owner.chatID {
            mateDirectory.incrementUnread(id: owner.mateID)
            syncMatePublications()
        }
        return ("Added your question to Waiting on You (id \(item.id.uuidString)). Stop here and summarize what is done so far; HeyMate will automatically resume this chat as soon as the person answers.", false)
    }

    /// Answers a paused Inbox question or sign-in request and immediately
    /// resumes that mate's conversation in the background with the answer.
    @discardableResult
    func answerMateInboxItem(id: UUID, answer: String) -> Bool {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let resolved = mateInbox.pendingItems.first(where: { $0.id == id }) else { return false }
        let prompt: String
        switch resolved.kind {
        case .question(let question, _, _):
            let contextLine = resolved.resumeTaskContext.map { "Paused task context: \($0)\n\n" } ?? ""
            prompt = "\(contextLine)Answer to your question (\"\(question)\"): \(trimmed)\n\nContinue and finish the task now."
        case .signIn(let site, _, _, _):
            let contextLine = resolved.resumeTaskContext.map { "Paused task context: \($0)\n\n" } ?? ""
            prompt = "\(contextLine)I signed in to \(site) (\(trimmed)). Check the open browser session and continue the task now."
        case .routineFailed(_, let summary):
            let task = resolved.resumeTaskContext.map { "Original task: \($0)\n" } ?? ""
            prompt = "\(task)Previous blocker: \(summary)\n\nUser's instruction: \(trimmed)"
        case .appliedChange, .proposal:
            return false
        }
        let work = mateInbox.work.first { $0.id == resolved.workID && $0.mateID == resolved.mateID && $0.chatID == resolved.chatID }
        guard resumeMateChatInBackground(mateID: resolved.mateID, chatID: resolved.chatID,
            userMessage: trimmed, modelPrompt: work?.checkpointPrompt(instruction: prompt) ?? prompt,
            previousWork: work) else { return false }
        mateInbox.resolve(id: id, summary: "Answered", resumed: true)
        return true
    }

    func actOnMateInboxWork(id: UUID, action: MateInboxWork.Action, message: String) -> Bool {
        guard let work = mateInbox.work.first(where: { $0.id == id }),
              mateInbox.work.first(where: { $0.taskID == work.taskID })?.id == id,
              work.actions.contains(action),
              !mateInbox.pendingItems.contains(where: { $0.workID == id }) else { return false }
        let userMessage: String
        let instruction: String
        switch action {
        case .resume:
            userMessage = "Continue this task."
            instruction = "Continue from the last verified step and finish the remaining work."
        case .retry:
            guard let step = work.lastFailedStep else { return false }
            userMessage = "Retry failed step: \(step.displayTitle)"
            instruction = "Retry the failed step (\(step.displayTitle), tool call \(step.id)) using its previous inputs. Recover only what this step blocked."
        case .followUp:
            userMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !userMessage.isEmpty else { return false }
            instruction = "Address this follow-up using the work already done: \(userMessage)"
        }
        guard resumeMateChatInBackground(mateID: work.mateID, chatID: work.chatID, userMessage: userMessage,
            modelPrompt: work.checkpointPrompt(instruction: instruction), previousWork: work) else { return false }
        if action != .followUp { mateInbox.markResumed(id) }
        return true
    }
}
