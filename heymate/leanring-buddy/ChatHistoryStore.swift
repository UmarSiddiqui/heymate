//
//  ChatHistoryStore.swift
//  leanring-buddy
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
}

nonisolated struct ChatSession: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]

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

    func upsert(_ session: ChatSession) {
        guard !session.messages.isEmpty else { return }
        sessions.removeAll { $0.id == session.id }
        sessions.append(session)
        trimExcessSessions()
        persist()
    }

    func delete(id: UUID) {
        sessions.removeAll { $0.id == id }
        persist()
    }

    func deleteAll() {
        sessions.removeAll()
        persist()
    }

    nonisolated static func appSupportFileURL() -> URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let heymateDirectory = applicationSupportDirectory.appendingPathComponent("heymate", isDirectory: true)
        try? FileManager.default.createDirectory(at: heymateDirectory, withIntermediateDirectories: true)
        return heymateDirectory.appendingPathComponent("chats.json")
    }

    private func trimExcessSessions() {
        let sortedOldestFirst = sessions.sorted { $0.updatedAt < $1.updatedAt }
        let overflow = sortedOldestFirst.count - maxSessions
        guard overflow > 0 else { return }
        let idsToRemove = Set(sortedOldestFirst.prefix(overflow).map(\.id))
        sessions.removeAll { idsToRemove.contains($0.id) }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let fileData = try encoder.encode(sessions)
            try fileData.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort: an unwritable volume should not crash the app.
        }
    }
}
