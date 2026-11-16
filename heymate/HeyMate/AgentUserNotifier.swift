//
//  AgentUserNotifier.swift
//  HeyMate
//
//  Local notifications for agent milestones that need attention while the
//  user is in another app. Agent output stays local; only concise run-card
//  text is copied into the notification.
//

import AppKit
import Foundation
import UserNotifications

nonisolated struct AgentNotificationPayload: Equatable {
    enum Kind: String, Equatable {
        case planReady
        case approvalRequired
        case finished
        case failed
        case proposal
    }

    let kind: Kind
    let title: String
    let body: String

    static func make(for event: AgentEvent, runTitle: String) -> AgentNotificationPayload? {
        let normalizedTitle = runTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskName = normalizedTitle.isEmpty ? "Your agent" : normalizedTitle

        switch event {
        case .planReady:
            return AgentNotificationPayload(
                kind: .planReady,
                title: "Plan ready",
                body: "\(taskName) is waiting for your approval."
            )
        case .approvalRequested(_, let summary):
            return AgentNotificationPayload(
                kind: .approvalRequired,
                title: "Agent needs approval",
                body: conciseBody(summary, fallback: taskName)
            )
        case .finished(let summary):
            return AgentNotificationPayload(
                kind: .finished,
                title: "Agent finished",
                body: conciseBody(summary, fallback: taskName)
            )
        case .failed(let message):
            return AgentNotificationPayload(
                kind: .failed,
                title: "Agent stopped",
                body: conciseBody(message, fallback: taskName)
            )
        case .started, .sessionIdentified, .tool, .text:
            return nil
        }
    }

    /// One notification per heartbeat: the mate's name and its first proposal.
    static func proposals(mateName: String, firstTitle: String, count: Int) -> AgentNotificationPayload? {
        let title = firstTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard count > 0, !title.isEmpty else { return nil }
        let name = mateName.trimmingCharacters(in: .whitespacesAndNewlines)
        let more = count > 1 ? " (+\(count - 1) more)" : ""
        return AgentNotificationPayload(
            kind: .proposal,
            title: "\(name.isEmpty ? "Your agent" : name) has an idea",
            body: conciseBody(title + more, fallback: title)
        )
    }

    /// One notification when a routine stops for good (not when it will retry).
    static func routineFailed(mateName: String, task: String, message: String) -> AgentNotificationPayload {
        let name = mateName.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentNotificationPayload(
            kind: .failed,
            title: "\(name.isEmpty ? "Your agent" : name)'s routine stopped",
            body: conciseBody(message, fallback: task)
        )
    }

    /// Which per-mate notification switch covers this payload.
    var mateKind: MateNotificationKind {
        switch kind {
        case .planReady, .approvalRequired: return .needsInput
        case .finished: return .finishedWork
        case .failed: return .failed
        case .proposal: return .proposal
        }
    }

    private static func conciseBody(_ text: String, fallback: String) -> String {
        let singleLine = text
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = singleLine.isEmpty ? fallback : singleLine
        guard resolved.count > 180 else { return resolved }
        return String(resolved.prefix(177)) + "…"
    }
}

@MainActor
final class AgentUserNotifier {
    private let notificationCenter: UNUserNotificationCenter
    private let isAppActive: () -> Bool
    /// A mate's notification switches and quiet hours (agent settings).
    private let mateSettings: @MainActor (UUID) -> MateAgentSettings
    private let now: () -> Date
    private var hasRequestedAuthorization = false

    init(
        notificationCenter: UNUserNotificationCenter,
        isAppActive: @escaping () -> Bool,
        mateSettings: @escaping @MainActor (UUID) -> MateAgentSettings = { MateAgentSettingsStore.shared.settings(for: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.notificationCenter = notificationCenter
        self.isAppActive = isAppActive
        self.mateSettings = mateSettings
        self.now = now
    }

    convenience init() {
        self.init(
            notificationCenter: .current(),
            isAppActive: { NSApp.isActive }
        )
    }

    func handle(run: AgentRun, event: AgentEvent) {
        if case .started = event {
            requestAuthorizationIfNeeded()
            return
        }

        guard !isAppActive(),
              let payload = AgentNotificationPayload.make(for: event, runTitle: run.title) else {
            return
        }
        let decision = gate(payload, mateID: run.chatOwner?.mateID, isUnattended: false)
        post(payload, identifier: "agent-\(run.id.uuidString)-\(payload.kind.rawValue)",
             thread: run.id.uuidString, userInfo: ["runID": run.id.uuidString], decision: decision)
    }

    /// Posts a heartbeat's proposal notice while the person is in another app.
    func notifyProposals(mateID: UUID, mateName: String, firstTitle: String, count: Int) {
        guard !isAppActive(),
              let payload = AgentNotificationPayload.proposals(mateName: mateName, firstTitle: firstTitle, count: count) else { return }
        post(payload, identifier: "heartbeat-\(mateID.uuidString)", thread: "heartbeat-\(mateID.uuidString)",
             userInfo: ["mateID": mateID.uuidString], decision: gate(payload, mateID: mateID, isUnattended: true))
    }

    /// A routine that stopped and will not retry on its own.
    func notifyRoutineFailed(mateID: UUID, mateName: String, task: String, message: String, routineID: UUID) {
        let payload = AgentNotificationPayload.routineFailed(mateName: mateName, task: task, message: message)
        let decision = gate(payload, mateID: mateID, isUnattended: true)
        // Held notices go out later even if HeyMate is in front now.
        if case .deliver = decision, isAppActive() { return }
        post(payload, identifier: "routine-\(routineID.uuidString)-failed", thread: "routine-\(mateID.uuidString)",
             userInfo: ["mateID": mateID.uuidString], decision: decision)
    }

    private func gate(_ payload: AgentNotificationPayload, mateID: UUID?, isUnattended: Bool) -> MateNotificationGate.Decision {
        guard let mateID else { return .deliver }
        let settings = mateSettings(mateID)
        return MateNotificationGate.decide(
            payload.mateKind, preferences: settings.notifications, quietHours: settings.quietHours,
            isWatching: isAppActive(), isUnattended: isUnattended, now: now()
        )
    }

    private func post(_ payload: AgentNotificationPayload, identifier: String, thread: String,
                      userInfo: [String: String], decision: MateNotificationGate.Decision) {
        let trigger: UNNotificationTrigger?
        switch decision {
        case .drop: return
        case .deliver: trigger = nil
        case .deliverAt(let date):
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSince(now())), repeats: false)
        }
        Task {
            let settings = await notificationCenter.notificationSettings()
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = payload.title
            content.body = payload.body
            content.sound = .default
            content.threadIdentifier = thread
            content.userInfo = userInfo
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            try? await notificationCenter.add(request)
        }
    }

    private func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true

        Task {
            let settings = await notificationCenter.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await notificationCenter.requestAuthorization(options: [.alert, .sound])
        }
    }
}
