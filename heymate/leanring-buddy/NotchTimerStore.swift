//
//  NotchTimerStore.swift
//  leanring-buddy
//
//  Timers and focus sessions surfaced as a notch activity. One timer at a
//  time on purpose: the pill has room for one countdown, and a stack of
//  competing timers is a to-do app, not an ambient surface.
//
//  The countdown does NOT tick on a display-rate timer. The deadline is a
//  Date; the pill re-reads it once a second while the timer is the visible
//  activity, and not at all otherwise.
//

import Combine
import Foundation

@MainActor
final class NotchTimerStore: ObservableObject {

    struct RunningTimer: Equatable {
        let label: String
        let startedAt: Date
        let deadline: Date

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
    var onTimerCompleted: ((String) -> Void)?

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

    func cancel() {
        stopTicking()
        runningTimer = nil
        activity = nil
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

    private func refreshActivity(asOf referenceDate: Date) {
        guard let runningTimer else {
            activity = nil
            return
        }
        let remaining = runningTimer.remaining(asOf: referenceDate)
        guard remaining > 0 else {
            let completedLabel = runningTimer.label
            cancel()
            onTimerCompleted?(completedLabel)
            return
        }
        activity = NotchActivity(
            kind: .timer,
            trailingText: Self.formatted(remainingSeconds: remaining),
            progress: runningTimer.progress(asOf: referenceDate)
        )
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
