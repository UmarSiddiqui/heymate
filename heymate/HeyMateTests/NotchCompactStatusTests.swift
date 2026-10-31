import Foundation
import Testing
@testable import HeyMate

struct NotchCompactStatusTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func snapshot(_ id: UUID, _ phase: NotchCompactStatus.Phase, action: String = "",
                          createdAt: Date = Date(timeIntervalSince1970: 900)) -> NotchCompactStatus.Snapshot {
        .init(id: id, title: "Research", action: action, phase: phase, hue: 0.4, createdAt: createdAt)
    }

    @Test func approvalOutranksRunningAndQueuedTasks() {
        var state = NotchCompactStatus()
        let waiting = snapshot(UUID(), .needsUser, action: "Reading files")
        state.update([snapshot(UUID(), .working), snapshot(UUID(), .queued), waiting], now: now)
        #expect(state.selected == waiting)
        #expect(state.selected?.displayText == "Approval needed")
        #expect(state.activeCount == 3)
    }

    @Test func realProgressUpdatesWithoutChangingRunIdentity() {
        var state = NotchCompactStatus()
        let id = UUID()
        state.update([snapshot(id, .working, action: "Reading\n  files")], now: now)
        #expect(state.selected?.displayText == "Reading files")
        state.update([snapshot(id, .working, action: "Running tests")], now: now)
        #expect(state.selected?.displayText == "Running tests")
        #expect(state.expiresAt == nil)
    }

    @Test func savedTerminalRunsNeverReplayOnLaunch() {
        var state = NotchCompactStatus()
        state.update([snapshot(UUID(), .succeeded), snapshot(UUID(), .failed)], now: now)
        #expect(state.selected == nil)
        #expect(state.expiresAt == nil)
    }

    @Test func completionExpiresOnceAndDoesNotReplayFromLaterUpdates() {
        var state = NotchCompactStatus()
        let id = UUID()
        state.update([snapshot(id, .working)], now: now)
        state.update([snapshot(id, .succeeded, action: "Running tests")], now: now)
        #expect(state.selected?.displayText == "Done")
        #expect(state.expiresAt == now.addingTimeInterval(6))
        state.update([snapshot(id, .succeeded)], now: now.addingTimeInterval(3))
        #expect(state.expiresAt == now.addingTimeInterval(6))
        state.update([snapshot(id, .succeeded)], now: now.addingTimeInterval(6))
        #expect(state.selected == nil)
        state.update([snapshot(id, .succeeded)], now: now.addingTimeInterval(20))
        #expect(state.selected == nil)
    }

    @Test func completionDoesNotHideLiveWorkOrStealApproval() {
        var state = NotchCompactStatus()
        let id = UUID()
        let waiting = snapshot(UUID(), .needsUser)
        state.update([snapshot(id, .working), waiting], now: now)
        state.update([snapshot(id, .succeeded), waiting], now: now)
        #expect(state.selected == waiting)
        state.update([snapshot(id, .succeeded)], now: now.addingTimeInterval(7))
        #expect(state.selected == nil)
    }

    @Test func failureAndCancellationNeverKeepPreviousActionText() {
        for phase in [NotchCompactStatus.Phase.failed, .cancelled] {
            var state = NotchCompactStatus()
            let id = UUID()
            state.update([snapshot(id, .working)], now: now)
            state.update([snapshot(id, phase, action: "Editing files")], now: now)
            #expect(state.selected?.displayText == phase.label)
        }
    }

    @Test func liveSelectionStaysStableWhenInputOrderingChanges() {
        var state = NotchCompactStatus()
        let first = snapshot(UUID(), .working, createdAt: now.addingTimeInterval(-2))
        let second = snapshot(UUID(), .working, createdAt: now.addingTimeInterval(-1))
        state.update([first, second], now: now)
        state.update([second, first], now: now)
        #expect(state.selected == first)
    }
}
