//
//  NotchTimerStore.swift
//  HeyMate
//
//  Timers and focus sessions surfaced as a notch activity. One timer at a
//  time on purpose: the pill has room for one countdown, and a stack of
//  competing timers is a to-do app, not an ambient surface.
//
//  The countdown does NOT tick on a display-rate timer. The deadline is a
//  Date; the pill re-reads it once a second while the timer is the visible
//  activity, and not at all otherwise.
//
//  A pomodoro is the same single countdown, re-armed for the next phase
//  when one ends: focus, short break, focus … with a long break after every
//  `roundsBeforeLongBreak` focus rounds. The session ends after the break
//  that follows its last focus round.
//

import Combine
import Foundation

/// Lengths and round count for one pomodoro session. Pure value so the
/// phase rules are unit-testable without a clock.
struct PomodoroPlan: Equatable, Sendable {
    var focus: TimeInterval = 25 * 60
    var shortBreak: TimeInterval = 5 * 60
    var longBreak: TimeInterval = 15 * 60
    var rounds = 4
    var roundsBeforeLongBreak = 4

    static let standard = PomodoroPlan()

    /// Clamps model-supplied values to something a person would choose.
    func sanitized() -> PomodoroPlan {
        PomodoroPlan(
            focus: min(max(focus, 60), 3 * 3600),
            shortBreak: min(max(shortBreak, 60), 3600),
            longBreak: min(max(longBreak, 60), 2 * 3600),
            rounds: min(max(rounds, 1), 12),
            roundsBeforeLongBreak: min(max(roundsBeforeLongBreak, 2), 12)
        )
    }
}

enum PomodoroPhase: Equatable, Sendable {
    case focus(round: Int)
    case shortBreak(afterRound: Int)
    case longBreak(afterRound: Int)

    var isBreak: Bool {
        if case .focus = self { return false }
        return true
    }

    func duration(in plan: PomodoroPlan) -> TimeInterval {
        switch self {
        case .focus: return plan.focus
        case .shortBreak: return plan.shortBreak
        case .longBreak: return plan.longBreak
        }
    }

    /// The phase that follows this one, or nil when the session is over.
    func next(in plan: PomodoroPlan) -> PomodoroPhase? {
        switch self {
        case .focus(let round):
            return round % plan.roundsBeforeLongBreak == 0 || round == plan.rounds
                ? .longBreak(afterRound: round)
                : .shortBreak(afterRound: round)
        case .shortBreak(let round), .longBreak(let round):
            return round < plan.rounds ? .focus(round: round + 1) : nil
        }
    }

    /// What to say when this phase begins.
    func announcement(in plan: PomodoroPlan) -> String {
        let minutes = Int((duration(in: plan) / 60).rounded())
        switch self {
        case .focus(let round):
            return round == 1
                ? "Focus for \(minutes) minutes. Round 1 of \(plan.rounds)."
                : "Break's over. Focus round \(round) of \(plan.rounds), \(minutes) minutes."
        case .shortBreak:
            return "Nice work. Take a \(minutes) minute break."
        case .longBreak(let round):
            return round == plan.rounds
                ? "Last round done. Take a \(minutes) minute break, then you're finished."
                : "Good stretch. Take a longer \(minutes) minute break."
        }
    }
}

@MainActor
final class NotchTimerStore: ObservableObject {

    struct PomodoroState: Equatable {
        let plan: PomodoroPlan
        let phase: PomodoroPhase
    }

    struct RunningTimer: Equatable {
        let label: String
        let startedAt: Date
        let deadline: Date
        var pomodoro: PomodoroState? = nil

        var totalDuration: TimeInterval { deadline.timeIntervalSince(startedAt) }

        func remaining(asOf referenceDate: Date) -> TimeInterval {
            max(deadline.timeIntervalSince(referenceDate), 0)
        }

        func progress(asOf referenceDate: Date) -> Double {
            guard totalDuration > 0 else { return 1 }
            let elapsed = referenceDate.timeIntervalSince(startedAt)
            return min(max(elapsed / totalDuration, 0), 1)
        }
    }

    @Published private(set) var runningTimer: RunningTimer?
    @Published private(set) var activity: NotchActivity?

    /// Fires when a timer reaches zero so the companion can speak or chime.
    /// A pomodoro fires it once, when the whole session ends.
    var onTimerCompleted: ((String) -> Void)?

    /// Fires when a pomodoro moves into its next phase, with the line to
    /// speak. Separate from completion so the notch keeps the new countdown
    /// instead of flashing "done" over it.
    var onPomodoroPhaseChanged: ((String) -> Void)?

    var isPomodoroRunning: Bool { runningTimer?.pomodoro != nil }

    private var tickCancellable: AnyCancellable?

    // MARK: Control

    func start(duration: TimeInterval, label: String = "Timer") {
        guard duration > 0 else { return }
        let now = Date()
        runningTimer = RunningTimer(
            label: label,
            startedAt: now,
            deadline: now.addingTimeInterval(duration)
        )
        startTicking()
        refreshActivity(asOf: now)
    }

    /// Starts a pomodoro session, replacing any running timer. Returns the
    /// line announcing the first focus round.
    @discardableResult
    func startPomodoro(plan: PomodoroPlan = .standard, now: Date = Date()) -> String {
        let plan = plan.sanitized()
        let phase = PomodoroPhase.focus(round: 1)
        arm(phase: phase, plan: plan, at: now)
        return phase.announcement(in: plan)
    }

    func cancel() {
        stopTicking()
        runningTimer = nil
        activity = nil
    }

    private func arm(phase: PomodoroPhase, plan: PomodoroPlan, at now: Date) {
        runningTimer = RunningTimer(
            label: "Pomodoro",
            startedAt: now,
            deadline: now.addingTimeInterval(phase.duration(in: plan)),
            pomodoro: PomodoroState(plan: plan, phase: phase)
        )
        startTicking()
        refreshActivity(asOf: now)
    }

    /// One wakeup per second, alive only while a timer is running. The
    /// alternative — a permanently scheduled timer that mostly does
    /// nothing — is exactly the pattern that makes menu-bar apps show up
    /// in Activity Monitor's energy tab.
    private func startTicking() {
        stopTicking()
        tickCancellable = Timer.publish(every: 1, tolerance: 0.2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] tickDate in
                self?.refreshActivity(asOf: tickDate)
            }
    }

    private func stopTicking() {
        tickCancellable?.cancel()
        tickCancellable = nil
    }

    /// Internal so tests can step the clock without waiting on the ticker.
    func refreshActivity(asOf referenceDate: Date) {
        guard let runningTimer else {
            activity = nil
            return
        }
        let remaining = runningTimer.remaining(asOf: referenceDate)
        guard remaining > 0 else {
            if let pomodoro = runningTimer.pomodoro {
                advancePomodoro(pomodoro, at: referenceDate)
                return
            }
            let completedLabel = runningTimer.label
            cancel()
            onTimerCompleted?(completedLabel)
            return
        }
        let isBreak = runningTimer.pomodoro?.phase.isBreak ?? false
        activity = NotchActivity(
            kind: .timer,
            trailingText: Self.formatted(remainingSeconds: remaining),
            progress: runningTimer.progress(asOf: referenceDate),
            tintHex: isBreak ? Self.breakTintHex : nil,
            symbolOverride: runningTimer.pomodoro.map { $0.phase.isBreak ? "cup.and.saucer.fill" : "brain.head.profile" }
        )
    }

    /// Calm green for breaks; focus keeps the person's theme color.
    nonisolated static let breakTintHex = "34D399"

    private func advancePomodoro(_ state: PomodoroState, at now: Date) {
        guard let next = state.phase.next(in: state.plan) else {
            cancel()
            onTimerCompleted?("Pomodoro finished. \(state.plan.rounds) focus rounds done.")
            return
        }
        // Re-arm from the old deadline so a slightly late tick doesn't
        // stretch the session. After a long gap (the Mac slept) start the
        // next phase now instead, rather than racing through missed phases.
        let deadline = runningTimer?.deadline ?? now
        let start = now.timeIntervalSince(deadline) < 60 ? deadline : now
        arm(phase: next, plan: state.plan, at: start)
        onPomodoroPhaseChanged?(next.announcement(in: state.plan))
    }

    // MARK: Formatting + parsing

    /// `mm:ss` under an hour, `h:mm:ss` above it. Monospaced digits in the
    /// pill keep the width from jittering as digits change.
    nonisolated static func formatted(remainingSeconds: TimeInterval) -> String {
        let totalSeconds = Int(remainingSeconds.rounded(.up))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Parses the shorthand people actually type: "25m", "1h30m", "90s",
    /// "2h15m", or a bare number of minutes. Returns nil when nothing in
    /// the string looks like a duration, so callers can fall through to
    /// their normal handling instead of starting a mystery timer.
    nonisolated static func parseDuration(from text: String) -> TimeInterval? {
        let normalized = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        var totalSeconds: TimeInterval = 0
        var didMatchAnyUnit = false
        var pendingDigits = ""

        for character in normalized {
            if character.isNumber {
                pendingDigits.append(character)
                continue
            }
            guard let value = Double(pendingDigits) else {
                pendingDigits = ""
                continue
            }
            switch character {
            case "h": totalSeconds += value * 3600; didMatchAnyUnit = true
            case "m": totalSeconds += value * 60; didMatchAnyUnit = true
            case "s": totalSeconds += value; didMatchAnyUnit = true
            default: break
            }
            if didMatchAnyUnit { pendingDigits = "" }
        }

        // A trailing bare number means minutes ("set a timer for 25").
        if !didMatchAnyUnit, let bareValue = Double(pendingDigits), bareValue > 0 {
            return bareValue * 60
        }
        return didMatchAnyUnit && totalSeconds > 0 ? totalSeconds : nil
    }
}
