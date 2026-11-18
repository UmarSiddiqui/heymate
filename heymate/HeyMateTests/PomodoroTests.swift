//
//  PomodoroTests.swift
//  HeyMateTests
//
//  Phase rules for the notch pomodoro, stepped with an explicit clock so
//  nothing waits on the real one-second ticker.
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct PomodoroTests {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func standardSessionRunsFourRoundsAndEndsAfterTheLongBreak() {
        let plan = PomodoroPlan.standard
        var phases: [PomodoroPhase] = [.focus(round: 1)]
        while let next = phases.last?.next(in: plan) { phases.append(next) }
        #expect(phases == [
            .focus(round: 1), .shortBreak(afterRound: 1),
            .focus(round: 2), .shortBreak(afterRound: 2),
            .focus(round: 3), .shortBreak(afterRound: 3),
            .focus(round: 4), .longBreak(afterRound: 4)
        ])
    }

    @Test func longBreakRepeatsEveryFourRoundsInLongerSessions() {
        var plan = PomodoroPlan.standard
        plan.rounds = 6
        #expect(PomodoroPhase.focus(round: 4).next(in: plan) == .longBreak(afterRound: 4))
        #expect(PomodoroPhase.longBreak(afterRound: 4).next(in: plan) == .focus(round: 5))
        #expect(PomodoroPhase.focus(round: 6).next(in: plan) == .longBreak(afterRound: 6))
        #expect(PomodoroPhase.longBreak(afterRound: 6).next(in: plan) == nil)
    }

    @Test func modelSuppliedPlansAreClamped() {
        let plan = PomodoroPlan(focus: 1, shortBreak: 99_999, longBreak: 0, rounds: 500, roundsBeforeLongBreak: 0).sanitized()
        #expect(plan.focus == 60)
        #expect(plan.shortBreak == 3600)
        #expect(plan.longBreak == 60)
        #expect(plan.rounds == 12)
        #expect(plan.roundsBeforeLongBreak == 2)
    }

    @Test func storeAdvancesPhasesAndAnnouncesWithoutCompleting() {
        let store = NotchTimerStore()
        defer { store.cancel() }
        var announcements: [String] = []
        var completions: [String] = []
        store.onPomodoroPhaseChanged = { announcements.append($0) }
        store.onTimerCompleted = { completions.append($0) }

        let opening = store.startPomodoro(now: start)
        #expect(opening.contains("Round 1 of 4"))
        #expect(store.activity?.trailingText == "25:00")
        #expect(store.activity?.symbolName == "brain.head.profile")
        #expect(store.activity?.tintHex == nil)

        // Focus ends on time: the break is armed from the old deadline.
        store.refreshActivity(asOf: start.addingTimeInterval(25 * 60 + 1))
        #expect(store.runningTimer?.pomodoro?.phase == .shortBreak(afterRound: 1))
        #expect(store.runningTimer?.startedAt == start.addingTimeInterval(25 * 60))
        #expect(store.activity?.tintHex == NotchTimerStore.breakTintHex)
        #expect(announcements.count == 1)
        #expect(completions.isEmpty)
    }

    @Test func longGapStartsTheNextPhaseNowInsteadOfRacing() {
        let store = NotchTimerStore()
        defer { store.cancel() }
        store.startPomodoro(now: start)
        let wake = start.addingTimeInterval(3 * 3600)
        store.refreshActivity(asOf: wake)
        #expect(store.runningTimer?.pomodoro?.phase == .shortBreak(afterRound: 1))
        #expect(store.runningTimer?.startedAt == wake)
    }

    @Test func sessionCompletesOnceAfterTheFinalBreak() {
        let store = NotchTimerStore()
        defer { store.cancel() }
        var completions: [String] = []
        store.onTimerCompleted = { completions.append($0) }
        var plan = PomodoroPlan.standard
        plan.rounds = 1
        store.startPomodoro(plan: plan, now: start)
        store.refreshActivity(asOf: start.addingTimeInterval(25 * 60))
        #expect(store.runningTimer?.pomodoro?.phase == .longBreak(afterRound: 1))
        store.refreshActivity(asOf: start.addingTimeInterval(40 * 60))
        #expect(store.runningTimer == nil)
        #expect(completions.count == 1)
    }

    @Test func plainTimerStillCompletesNormally() {
        let store = NotchTimerStore()
        defer { store.cancel() }
        var completions: [String] = []
        store.onTimerCompleted = { completions.append($0) }
        store.start(duration: 0.01, label: "pasta")
        store.refreshActivity(asOf: Date().addingTimeInterval(5))
        #expect(completions == ["pasta"])
        #expect(store.runningTimer?.pomodoro == nil)
    }
}
