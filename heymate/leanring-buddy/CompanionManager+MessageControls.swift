//
//  CompanionManager+MessageControls.swift
//  leanring-buddy
//
//  Edit, delete, and regenerate for one transcript message. Stopping a
//  reply stays on CompanionManager because playback and dispatch are private.
//

import SwiftUI

extension CompanionManager {

    /// User text immediately before an assistant message. Nil when regenerate should no-op.
    func precedingUserText(for messageID: UUID) -> String? {
        guard let index = currentChat.messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        guard currentChat.messages[index].role == .assistant else { return nil }
        guard let text = currentChat.messages[..<index].last(where: { $0.role == .user })?.text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func deleteMessage(id: UUID) {
        guard currentChat.messages.contains(where: { $0.id == id }) else { return }
        stopReplyIfNeeded()
        var session = currentChat
        session.messages.removeAll { $0.id == id }
        session.updatedAt = Date()
        if session.messages.isEmpty {
            session.title = ChatSession.defaultTitle
        }
        currentChat = session
        persistChatTranscriptChange()
    }

    /// Drops this user message and everything after it, then returns the text for the composer.
    func editMessageInComposer(id: UUID) -> String? {
        guard let index = currentChat.messages.firstIndex(where: { $0.id == id }) else { return nil }
        let message = currentChat.messages[index]
        guard message.role == .user else { return nil }
        stopReplyIfNeeded()
        var session = currentChat
        guard let liveIndex = session.messages.firstIndex(where: { $0.id == id }) else { return message.text }
        session.messages.removeSubrange(liveIndex...)
        session.updatedAt = Date()
        if session.messages.isEmpty {
            session.title = ChatSession.defaultTitle
        }
        currentChat = session
        persistChatTranscriptChange()
        return message.text
    }

    /// Removes that assistant reply and sends the user message that preceded it.
    func regenerateAssistantMessage(id: UUID) {
        guard let userText = precedingUserText(for: id) else { return }
        let snapshot = currentChat
        stopReplyIfNeeded()
        var session = currentChat
        guard let index = session.messages.firstIndex(where: { $0.id == id }),
              session.messages[index].role == .assistant else { return }
        session.messages.remove(at: index)
        session.updatedAt = Date()
        if session.messages.isEmpty {
            session.title = ChatSession.defaultTitle
        }
        currentChat = session
        persistChatTranscriptChange()
        if !sendTypedMessage(userText) {
            currentChat = snapshot
            persistChatTranscriptChange()
        }
    }

    private func stopReplyIfNeeded() {
        guard isComposerStopVisible else { return }
        cancelInFlightChatTurn()
    }

    /// Upsert skips an empty session, so an emptied chat is removed from the store.
    /// The open session object stays, including its id.
    private func persistChatTranscriptChange() {
        let draft = currentChat.draftText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if currentChat.messages.isEmpty && draft.isEmpty {
            chatHistoryStore.delete(id: currentChat.id)
            if rememberConversationsEnabled {
                savedChats = chatHistoryStore.loadAll()
            }
            return
        }
        persistCurrentChatIfNeeded()
    }
}

struct ChatMessageActionButton: View {
    let title: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DS.Fonts.caption.weight(.medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
    }
}
