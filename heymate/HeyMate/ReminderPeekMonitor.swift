//
//  ReminderPeekMonitor.swift
//  HeyMate
//
//  Next due Apple Reminder, exposed as an opt-in notch micro-app.
//

import Combine
import EventKit
import Foundation

@MainActor
final class ReminderPeekMonitor: ObservableObject {

    struct DueReminder: Equatable, Identifiable {
        let id: String
        let title: String
        let dueDate: Date
        let isOverdue: Bool
    }

    @Published private(set) var nextReminder: DueReminder?
    @Published private(set) var activity: NotchActivity?
    @Published private(set) var authorizationDenied = false
    /// Left on at the end of a previous session, but macOS has never been
    /// asked. Held back until the user taps the micro-app again.
    @Published private(set) var needsPermissionPrompt = false

    private let eventStore = EKEventStore()
    private var storeChangedObserver: NSObjectProtocol?
    private var refreshCancellable: AnyCancellable?
    private var isRunning = false

    /// - Parameter promptForAccess: `true` only when the user just turned
    ///   this micro-app on. Launch restores pass `false` so the session
    ///   never opens with an unrequested permission panel.
    func start(promptForAccess: Bool) async {
        guard !isRunning else { return }
        isRunning = true

        let outcome = await resolveAccess(promptForAccess: promptForAccess)
        guard isRunning else { return }
        switch outcome {
        case .granted:
            authorizationDenied = false
            needsPermissionPrompt = false
        case .denied:
            authorizationDenied = true
            needsPermissionPrompt = false
            isRunning = false
            return
        case .notAsked:
            authorizationDenied = false
            needsPermissionPrompt = true
            isRunning = false
            return
        }

        storeChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        refreshCancellable = Timer.publish(every: 60, tolerance: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }

        refresh()
    }

    func stop() {
        isRunning = false
        if let storeChangedObserver {
            NotificationCenter.default.removeObserver(storeChangedObserver)
        }
        storeChangedObserver = nil
        refreshCancellable?.cancel()
        refreshCancellable = nil
        nextReminder = nil
        activity = nil
    }

    func completeNextReminder() {
        guard let nextReminder,
              let reminder = eventStore.calendarItem(withIdentifier: nextReminder.id) as? EKReminder else {
            return
        }
        reminder.isCompleted = true
        reminder.completionDate = Date()
        do {
            try eventStore.save(reminder, commit: true)
            refresh()
        } catch {
            // Keep current item visible when EventKit rejects the mutation.
        }
    }

    private enum AccessOutcome {
        case granted
        case denied
        /// macOS has never asked, and this call was not allowed to.
        case notAsked
    }

    private func resolveAccess(promptForAccess: Bool) async -> AccessOutcome {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized:
            return .granted
        case .denied, .restricted, .writeOnly:
            return .denied
        case .notDetermined:
            guard promptForAccess else { return .notAsked }
            let granted = await withCheckedContinuation { continuation in
                eventStore.requestFullAccessToReminders { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
            return granted ? .granted : .denied
        @unknown default:
            return .denied
        }
    }

    private func refresh() {
        guard isRunning else { return }
        let endDate = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: endDate,
            calendars: nil
        )

        eventStore.fetchReminders(matching: predicate) { [weak self] reminders in
            let candidates = (reminders ?? []).compactMap(Self.snapshot)
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                let next = candidates.sorted { $0.dueDate < $1.dueDate }.first
                self.nextReminder = next
                self.activity = next.map {
                    NotchActivity(
                        kind: .reminder,
                        trailingText: Self.pillLabel(for: $0, now: Date()),
                        tintHex: $0.isOverdue ? "FF6B6B" : nil
                    )
                }
            }
        }
    }

    private nonisolated static func snapshot(_ reminder: EKReminder) -> DueReminder? {
        guard !reminder.isCompleted,
              let title = reminder.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              let components = reminder.dueDateComponents,
              let dueDate = Calendar.current.date(from: components) else {
            return nil
        }
        return DueReminder(
            id: reminder.calendarItemIdentifier,
            title: title,
            dueDate: dueDate,
            isOverdue: dueDate < Date()
        )
    }

    nonisolated static func pillLabel(for reminder: DueReminder, now: Date) -> String {
        if reminder.dueDate <= now { return "due now" }
        let minutes = max(1, Int(reminder.dueDate.timeIntervalSince(now) / 60))
        if minutes < 60 { return "due \(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "due \(hours)h" }
        return "due \(hours / 24)d"
    }
}
