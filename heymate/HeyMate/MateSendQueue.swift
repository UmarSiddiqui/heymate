//
//  MateSendQueue.swift
//  HeyMate
//
//  A message typed while its chat cannot take it yet (a routine or hand-off
//  is running, or this mate is still finishing a turn) waits here and is sent
//  as soon as the chat is free, instead of being refused. Messages only
//  leave from the chat they were typed in.
//

import Combine
import Foundation

@MainActor
final class MateSendQueue: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let chatID: UUID
        let text: String
        let imageAttachments: [ChatImageAttachment]
        let queuedAt: Date
    }

    static let shared = MateSendQueue()
    static let maximumItems = 20
    static let pollInterval: TimeInterval = 0.5

    @Published private(set) var items: [Item] = []
    private var timer: Timer?
    private weak var owner: CompanionManager?

    func count(chatID: UUID) -> Int { items.filter { $0.chatID == chatID }.count }

    /// False when the queue is full.
    func enqueue(_ item: Item, owner: CompanionManager) -> Bool {
        guard items.count < Self.maximumItems else { return false }
        self.owner = owner
        items.append(item)
        startDraining()
        return true
    }

    func clear(chatID: UUID) {
        items.removeAll { $0.chatID == chatID }
        if items.isEmpty { stopDraining() }
    }

    private func startDraining() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drain() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopDraining() {
        timer?.invalidate()
        timer = nil
    }

    private func drain() {
        guard let owner else { stopDraining(); return }
        guard !items.isEmpty else { stopDraining(); return }
        let chatID = owner.currentChat.id
        guard let index = items.firstIndex(where: { $0.chatID == chatID }),
              owner.canSendQueuedMessage else { return }
        // The entry leaves before it runs, so a second tick cannot send it twice.
        let item = items.remove(at: index)
        if !owner.sendTypedMessage(item.text, imageAttachments: item.imageAttachments) {
            HeyMateLog.log("📨 Queued message for chat \(chatID) could not be sent: \(owner.commandBarFeedback ?? "")")
        }
        if items.isEmpty { stopDraining() }
    }
}

extension CompanionManager {
    /// Nothing in the open chat is running, so a queued message can go.
    var canSendQueuedMessage: Bool {
        !isChatTurnBusy && typedMessageBusyReason == nil && !isIndependentTurnRunningInOpenChat
    }

    /// Saves a message the chat cannot take yet. True when it was saved.
    func queueTypedMessage(_ text: String, imageAttachments: [ChatImageAttachment]) -> Bool {
        let item = MateSendQueue.Item(chatID: currentChat.id, text: text, imageAttachments: imageAttachments, queuedAt: Date())
        guard MateSendQueue.shared.enqueue(item, owner: self) else {
            commandBarFeedback = "Too many messages are waiting. Wait for this reply to finish."
            return false
        }
        let waiting = MateSendQueue.shared.count(chatID: currentChat.id)
        commandBarFeedback = waiting == 1
            ? "Queued. It sends as soon as this reply finishes."
            : "Queued (\(waiting) waiting). They send in order as replies finish."
        return true
    }
}
