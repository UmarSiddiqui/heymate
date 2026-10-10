//
//  CompanionManager+ChatLibrary.swift
//  HeyMate
//
//  Lists, deletes, and trim notices for saved chats. Opening and deleting
//  one chat, and deleting every chat, stay on CompanionManager.
//

import Foundation

extension CompanionManager {

    /// Saved sessions for the active mate, newest first.
    /// A nil `mateID` belongs to the default mate.
    func chatsForActiveMate() -> [ChatSession] {
        let activeID = activeMateID ?? mateDirectory.defaultMateID
        return chatHistoryStore.loadAll().filter { session in
            (session.mateID ?? mateDirectory.defaultMateID) == activeID
        }
    }

    /// Deletes persisted sessions for one mate.
    ///
    /// Nil `mateID` sessions belong to the default mate, so they are removed
    /// only when `id` is that default. The store itself deletes exact `mateID`
    /// matches only, because it does not know the default mate id.
    func clearChats(forMateID id: UUID) {
        let defaultID = mateDirectory.defaultMateID
        chatHistoryStore.deleteSessions(mateID: id)
        if id == defaultID {
            let nilSessionIDs = chatHistoryStore.loadAll().compactMap { session -> UUID? in
                session.mateID == nil ? session.id : nil
            }
            for sessionID in nilSessionIDs {
                chatHistoryStore.delete(id: sessionID)
            }
        }
        savedChats = rememberConversationsEnabled ? chatHistoryStore.loadAll() : []
        let owner = currentChat.mateID ?? defaultID
        if owner == id {
            var session = ChatSession.empty()
            session.mateID = activeMateID ?? defaultID
            currentChat = session
            streamingAssistantText = ""
        }
    }

    /// Sentence after the last persist dropped older chats, or nil. Clears the store counter.
    func chatTrimNotice() -> String? {
        guard chatHistoryStore.consumeTrimNotice() > 0 else { return nil }
        return "Older chats were dropped. HeyMate keeps the latest 40."
    }
}
