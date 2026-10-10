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

/// One icon action under a transcript message. The whole square is the
/// target, and the label doubles as the tooltip and the VoiceOver name.
struct ChatMessageActionButton: View {
    let systemImage: String
    let label: String
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(DS.Glyph.small)
        }
        .dsToolbarIconButtonStyle(size: DS.ControlSize.small, isDestructiveOnHover: isDestructive)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Copy, edit or regenerate, and delete for one message. Quiet until the
/// row is hovered so a long transcript doesn't read as a wall of links;
/// the latest message keeps them showing so they're easy to find.
struct ChatMessageActionBar: View {
    let text: String
    let isUser: Bool
    let isRevealed: Bool
    var onEdit: (() -> Void)?
    var onRegenerate: (() -> Void)?
    let onDelete: () -> Void

    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 2) {
            ChatMessageActionButton(
                systemImage: didCopy ? "checkmark" : "doc.on.doc",
                label: didCopy ? "Copied" : "Copy"
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                didCopy = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    didCopy = false
                }
            }
            if let onEdit {
                ChatMessageActionButton(systemImage: "pencil", label: "Edit message", action: onEdit)
            }
            if let onRegenerate {
                ChatMessageActionButton(systemImage: "arrow.clockwise", label: "Regenerate reply", action: onRegenerate)
            }
            ChatMessageActionButton(systemImage: "trash", label: "Delete message", isDestructive: true, action: onDelete)
        }
        // Nudge the first glyph onto the text's edge on the side it sits.
        .padding(isUser ? .trailing : .leading, -4)
        .opacity(isRevealed ? 1 : 0)
        .allowsHitTesting(isRevealed)
        .animation(.easeOut(duration: DS.Animation.fast), value: isRevealed)
    }
}

/// Tracks the pointer over one transcript row so its actions can appear.
struct ChatMessageHoverRow<Content: View>: View {
    @ViewBuilder var content: (_ isHovered: Bool) -> Content
    @State private var isHovered = false

    var body: some View {
        content(isHovered)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}
