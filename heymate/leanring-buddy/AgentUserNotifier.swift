//
//  AgentUserNotifier.swift
//  leanring-buddy
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
    }

    let kind: Kind
    let title: String
    let body: String

    static func make(for event: AgentEvent, runTitle: String) -> AgentNotificationPayload? {
        let normalizedTitle = runTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskName = normalizedTitle.isEmpty ? "Your job" : normalizedTitle

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
                title: "Job needs approval",
                body: conciseBody(summary, fallback: taskName)
            )
        case .finished(let summary):
            return AgentNotificationPayload(
                kind: .finished,
                title: "Job finished",
                body: conciseBody(summary, fallback: taskName)
            )
        case .failed(let message):
            return AgentNotificationPayload(
                kind: .failed,
                title: "Job stopped",
                body: conciseBody(message, fallback: taskName)
            )
        case .started, .sessionIdentified, .tool, .text:
            return nil
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
    private var hasRequestedAuthorization = false

    init(
        notificationCenter: UNUserNotificationCenter,
        isAppActive: @escaping () -> Bool
    ) {
        self.notificationCenter = notificationCenter
        self.isAppActive = isAppActive
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

        Task {
            let settings = await notificationCenter.notificationSettings()
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = payload.title
            content.body = payload.body
            content.sound = .default
            content.threadIdentifier = run.id.uuidString
            content.userInfo = ["runID": run.id.uuidString]

            let identifier = "agent-\(run.id.uuidString)-\(payload.kind.rawValue)"
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
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
