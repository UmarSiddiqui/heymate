//
//  CalendarPeekMonitor.swift
//  leanring-buddy
//
//  "Your next meeting" in the notch, plus a one-tap join for video calls.
//
//  Strictly opt-in. Calendar access is never requested at launch — the
//  monitor stays dormant until the user turns the micro-app on, which is
//  also the moment the permission prompt makes sense to them.
//
//  Refresh is event-driven (EventKit posts a store-changed notification)
//  plus one coarse timer, because "starts in 10 minutes" has to change
//  even when nothing about the calendar itself changed.
//

import Combine
import EventKit
import Foundation

@MainActor
final class CalendarPeekMonitor: ObservableObject {

    struct UpcomingEvent: Equatable {
        let title: String
        let startDate: Date
        let endDate: Date
        /// First conferencing URL found in the event's URL, location, or
        /// notes. nil when this is not a video meeting.
        let joinURL: URL?
        let calendarColorHex: String?
    }

    @Published private(set) var nextEvent: UpcomingEvent?
    @Published private(set) var activity: NotchActivity?
    @Published private(set) var authorizationDenied = false

    /// Only events starting inside this window are worth ambient space.
    private static let lookaheadWindow: TimeInterval = 60 * 60 * 12

    /// Start showing the countdown this long before the event.
    private static let alertLeadTime: TimeInterval = 60 * 30

    private let eventStore = EKEventStore()
    private var storeChangedObserver: NSObjectProtocol?
    private var refreshCancellable: AnyCancellable?

    func start() async {
        guard storeChangedObserver == nil else { return }

        let granted = await requestAccess()
        guard granted else {
            authorizationDenied = true
            return
        }
        authorizationDenied = false

        storeChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        // 60 s tolerance lets the OS coalesce this with other wakeups; a
        // "starts in 12 min" label does not need second accuracy.
        refreshCancellable = Timer.publish(every: 60, tolerance: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }

        refresh()
    }

    func stop() {
        if let storeChangedObserver {
            NotificationCenter.default.removeObserver(storeChangedObserver)
        }
        storeChangedObserver = nil
        refreshCancellable?.cancel()
        refreshCancellable = nil
        nextEvent = nil
        activity = nil
    }

    private func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            eventStore.requestFullAccessToEvents { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func refresh() {
        let now = Date()
        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: now.addingTimeInterval(Self.lookaheadWindow),
            calendars: nil
        )
        let upcoming = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }

        guard let event = upcoming.first, let title = event.title else {
            nextEvent = nil
            activity = nil
            return
        }

        nextEvent = UpcomingEvent(
            title: title,
            startDate: event.startDate,
            endDate: event.endDate,
            joinURL: Self.conferenceURL(in: event),
            calendarColorHex: nil
        )

        let secondsUntilStart = event.startDate.timeIntervalSince(now)
        guard secondsUntilStart <= Self.alertLeadTime else {
            activity = nil
            return
        }
        activity = NotchActivity(
            kind: .calendar,
            trailingText: Self.countdownLabel(secondsUntilStart: secondsUntilStart)
        )
    }

    nonisolated static func countdownLabel(secondsUntilStart: TimeInterval) -> String {
        if secondsUntilStart <= 0 { return "now" }
        let minutes = Int((secondsUntilStart / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes)m" }
        return "in \(minutes / 60)h"
    }

    /// Video-call links live in different fields depending on which tool
    /// created the invite, so check all three the same way.
    nonisolated static func conferenceURL(in event: EKEvent) -> URL? {
        let candidateStrings = [
            event.url?.absoluteString,
            event.location,
            event.notes
        ].compactMap { $0 }

        for candidate in candidateStrings {
            if let found = firstConferenceURL(in: candidate) { return found }
        }
        return nil
    }

    /// Hosts we recognize as "this is a meeting you can join".
    nonisolated static let conferenceHostFragments = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "meet.jit.si", "around.co",
        "discord.gg", "chime.aws", "bluejeans.com", "gotomeeting.com"
    ]

    nonisolated static func firstConferenceURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url, let host = url.host?.lowercased() else { continue }
            if conferenceHostFragments.contains(where: { host.contains($0) }) {
                return url
            }
        }
        return nil
    }
}
