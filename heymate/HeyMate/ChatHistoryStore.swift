//
//  ChatHistoryStore.swift
//  HeyMate
//
//  Text-only chat sessions for the notch Chat tab. Screenshots and audio
//  are structurally impossible to store — ChatMessage has no binary field.
//  Sessions are inspectable and deletable; the store caps how many we keep.
//

import Foundation

nonisolated enum ChatRole: String, Codable, Equatable {
    case user
    case assistant
}

nonisolated struct ChatMessage: Codable, Equatable, Identifiable {
    let id: UUID
    let role: ChatRole
    var text: String
    let createdAt: Date
    /// Image bytes stay ephemeral; history remembers only what was attached.
    var attachmentNames: [String]? = nil
}

nonisolated struct ChatSession: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
    /// Nil on chats saved before mates existed. Migration assigns the default mate.
    var mateID: UUID? = nil
    /// Unsent composer text for this session. Nil when the field is empty.
    var draftText: String? = nil

    static let defaultTitle = "New chat"

    static func empty() -> ChatSession {
        let now = Date()
        return ChatSession(
            id: UUID(),
            title: defaultTitle,
            createdAt: now,
            updatedAt: now,
            messages: []
        )
    }

    static func title(from firstUserMessage: String) -> String {
        let collapsed = firstUserMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !collapsed.isEmpty else { return defaultTitle }
        if collapsed.count <= 42 { return collapsed }
        return String(collapsed.prefix(41)) + "…"
    }

    var previewText: String {
        messages.last?.text ?? ""
    }

    /// Clipboard and on-device `.txt` export. Title first, then each message as `role: text`.
    func exportPlainText() -> String {
        var lines = [title]
        for message in messages {
            lines.append("\(message.role.rawValue): \(message.text)")
        }
        return lines.joined(separator: "\n")
    }

    /// Consecutive user/assistant turns for the vision API. Unpaired trailing
    /// user messages (in-flight asks) are omitted so we never send an empty
    /// assistant placeholder.
    func apiHistoryPairs(limit: Int = 10) -> [(userTranscript: String, assistantResponse: String)] {
        var pairs: [(userTranscript: String, assistantResponse: String)] = []
        var pendingUser: String?
        for message in messages {
            switch message.role {
            case .user:
                pendingUser = message.text
            case .assistant:
                if let userTranscript = pendingUser {
                    pairs.append((userTranscript: userTranscript, assistantResponse: message.text))
                    pendingUser = nil
                }
            }
        }
        if pairs.count <= limit { return pairs }
        return Array(pairs.suffix(limit))
    }
}

@MainActor
final class FileChatHistoryStore {

    private let fileURL: URL
    private let maxSessions: Int
    private var sessions: [ChatSession]
    /// Sessions removed by the most recent persist that actually trimmed. Cleared by `consumeTrimNotice()`.
    private var trimmedByLastPersist = 0

    init(fileURL: URL, maxSessions: Int = 40) {
        self.fileURL = fileURL
        self.maxSessions = maxSessions

        if let fileData = try? Data(contentsOf: fileURL),
           let decodedSessions = try? JSONDecoder().decode([ChatSession].self, from: fileData) {
            self.sessions = decodedSessions
        } else {
            self.sessions = []
        }
    }

    /// Newest `updatedAt` first.
    func loadAll() -> [ChatSession] {
        sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    func session(id: UUID) -> ChatSession? {
        sessions.first { $0.id == id }
    }

    /// How many sessions the last trimming persist removed, then clears that count.
    /// A later persist that does not trim leaves the count until it is consumed.
    func consumeTrimNotice() -> Int {
        let dropped = trimmedByLastPersist
        trimmedByLastPersist = 0
        return dropped
    }

    func upsert(_ session: ChatSession) {
        let draft = session.draftText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !session.messages.isEmpty || !draft.isEmpty else { return }
        sessions.removeAll { $0.id == session.id }
        sessions.append(session)
        let dropped = trimExcessSessions()
        persist(droppedSessionCount: dropped)
    }

    /// Assigns the default mate to sessions saved before mates existed, once.
    func migrateNilMateIDs(to defaultMateID: UUID) {
        var changed = false
        for index in sessions.indices where sessions[index].mateID == nil {
            sessions[index].mateID = defaultMateID
            changed = true
        }
        if changed { persist() }
    }

    func delete(id: UUID) {
        sessions.removeAll { $0.id == id }
        persist()
    }

    func deleteAll() {
        sessions.removeAll()
        persist()
    }

    /// Removes sessions whose `mateID` equals `mateID`.
    ///
    /// Nil `mateID` sessions are left in place. Those belong to the default mate.
    /// The default mate id is not knowable here; `CompanionManager` treats nil as
    /// `defaultMateID` when listing and when deleting.
    func deleteSessions(mateID: UUID) {
        sessions.removeAll { $0.mateID == mateID }
        persist()
    }

    nonisolated static func appSupportFileURL() -> URL {
        let applicationSupportDirectory = HeyMateDataDirectory.applicationSupportURL
        let heymateDirectory = applicationSupportDirectory.appendingPathComponent("heymate", isDirectory: true)
        try? FileManager.default.createDirectory(at: heymateDirectory, withIntermediateDirectories: true)
        return heymateDirectory.appendingPathComponent("chats.json")
    }

    private func trimExcessSessions() -> Int {
        let sortedOldestFirst = sessions.sorted { $0.updatedAt < $1.updatedAt }
        let overflow = sortedOldestFirst.count - maxSessions
        guard overflow > 0 else { return 0 }
        let idsToRemove = Set(sortedOldestFirst.prefix(overflow).map(\.id))
        let countBefore = sessions.count
        sessions.removeAll { idsToRemove.contains($0.id) }
        return countBefore - sessions.count
    }

    private func persist(droppedSessionCount: Int = 0) {
        if droppedSessionCount > 0 {
            trimmedByLastPersist = droppedSessionCount
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let fileData = try encoder.encode(sessions)
            try fileData.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort: an unwritable volume should not crash the app.
            UserDefaults.standard.set(
                "Couldn't save chat history.",
                forKey: "heymate.lastPersistError"
            )
            NotificationCenter.default.post(
                name: Notification.Name("heymate.persistFailed"),
                object: nil
            )
        }
    }
}
