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

    var isPendingAttention: Bool {
        guard resolvedAt == nil else { return false }
        switch kind {
        case .question, .signIn, .routineFailed:
            return true
        case .appliedChange:
            return false
        }
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
    private let fileURL: URL

    init(fileURL: URL = HeyMateDataDirectory.url.appendingPathComponent("mate-inbox.json")) {
        self.fileURL = fileURL
        load()
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
        // Deduplicate identical open sign-in or routine failure items per mate.
        if case .signIn(let site, _, _, _) = item.kind {
            items.removeAll {
                guard $0.resolvedAt == nil, $0.mateID == item.mateID,
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

    func resolve(id: UUID, summary: String? = nil, now: Date = Date()) -> MateInboxItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        items[index].resolvedAt = now
        items[index].resolutionSummary = summary
        let updated = items[index]
        save()
        return updated
    }

    func dismissAllResolved() {
        items.removeAll { $0.resolvedAt != nil }
        save()
    }

    func removeItems(forMate mateID: UUID) {
        items.removeAll { $0.mateID == mateID }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([MateInboxItem].self, from: data) else { return }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

extension CompanionManager {
    var mateInbox: MateInboxStore { MateInboxStore.shared }

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
            resumeTaskContext: context?.isEmpty == false ? String(context!.prefix(2_000)) : nil
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
    func answerMateInboxItem(id: UUID, answer: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let resolved = mateInbox.resolve(id: id, summary: trimmed) else { return }
        let prompt: String
        switch resolved.kind {
        case .question(let question, _, _):
            let contextLine = resolved.resumeTaskContext.map { "Paused task context: \($0)\n\n" } ?? ""
            prompt = "\(contextLine)Answer to your question (\"\(question)\"): \(trimmed)\n\nContinue and finish the task now."
        case .signIn(let site, _, _, _):
            let contextLine = resolved.resumeTaskContext.map { "Paused task context: \($0)\n\n" } ?? ""
            prompt = "\(contextLine)I signed in to \(site) (\(trimmed)). Check the open browser session and continue the task now."
        case .routineFailed(_, let summary):
            prompt = "Retry the failed routine task (\(summary)). Note from user: \(trimmed)"
        case .appliedChange:
            return
        }
        resumeMateChatInBackground(mateID: resolved.mateID, chatID: resolved.chatID, userMessage: trimmed, modelPrompt: prompt)
    }
}
