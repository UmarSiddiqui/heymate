import ActivityKit
import Foundation

@MainActor
enum PhoneLiveActivity {
    static let enabledKey = "phoneShowsChatLiveActivities"

    static var current: Activity<CompanionActivity>? {
        Activity<CompanionActivity>.activities.first {
            $0.activityState == .active || $0.activityState == .stale
        }
    }

    static func start(_ chat: PhoneChat, remoteUpdates: Bool) -> Activity<CompanionActivity>? {
        let enabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
        let previous = Activity<CompanionActivity>.activities
        let attributes = CompanionActivity(mateID: chat.mateID, chatID: chat.id)
        let activity = (remoteUpdates ? try? Activity.request(attributes: attributes, content: content(.queued),
                                                              pushType: .token) : nil)
            ?? (try? Activity.request(attributes: attributes, content: content(.queued), pushType: nil))
        if activity != nil {
            Task {
                for old in previous { await old.end(nil, dismissalPolicy: .immediate) }
            }
        }
        return activity
    }

    static func pushTarget(for activity: Activity<CompanionActivity>?) async -> PhoneLiveActivityTarget? {
        guard let activity else { return nil }
        #if HEYMATE_APNS_SANDBOX
        let environment: PhoneLiveActivityTarget.Environment = .sandbox
        #else
        let environment: PhoneLiveActivityTarget.Environment = .production
        #endif

        let readToken = Task { () -> Data? in
            if let current = activity.pushToken { return current }
            for await next in activity.pushTokenUpdates { return next }
            return nil
        }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            readToken.cancel()
        }
        defer { timeout.cancel() }
        guard let token = await readToken.value else { return nil }
        let target = PhoneLiveActivityTarget(token: token, environment: environment, supportsStoppedStage: true)
        return target.hasValidToken ? target : nil
    }

    static func discard(_ activity: Activity<CompanionActivity>?) {
        guard let activity else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    static func update(chatID: UUID, stage: CompanionActivity.ContentState.Stage) {
        guard let activity = current, activity.attributes.chatID == chatID else { return }
        Task {
            switch stage {
            case .queued, .working: await activity.update(content(stage))
            case .ready, .failed, .stopped:
                await activity.end(content(stage), dismissalPolicy: .after(.now.addingTimeInterval(300)))
            }
        }
    }

    static func clear() {
        let activities = Activity<CompanionActivity>.activities
        Task {
            for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private static func content(_ stage: CompanionActivity.ContentState.Stage) -> ActivityContent<CompanionActivity.ContentState> {
        .init(state: .init(stage: stage), staleDate: .now.addingTimeInterval(90))
    }
}
