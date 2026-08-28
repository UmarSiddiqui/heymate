//
//  NotchActivityTests.swift
//  leanring-buddyTests
//
//  Arbitration rules for the notch's ambient activity slot: priority,
//  expiry, and replace-by-kind. These decide what a user sees around their
//  camera all day, so the rules are pinned rather than assumed.
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct NotchActivityTests {

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func agentOutranksEveryOtherKind() {
        let candidates = NotchActivityKind.allCases.map {
            NotchActivity(kind: $0, trailingText: "x")
        }
        let winner = NotchActivityArbiter.frontmostActivity(among: candidates, asOf: referenceDate)
        #expect(winner?.kind == .agent)
    }

    @Test func somethingTheUserJustDidBeatsAmbientBackground() {
        let shelf = NotchActivity(kind: .shelf, trailingText: "3 files")
        let media = NotchActivity(kind: .media, trailingText: "Song")
        let battery = NotchActivity(kind: .battery, trailingText: "18%")
        let winner = NotchActivityArbiter.frontmostActivity(
            among: [media, battery, shelf],
            asOf: referenceDate
        )
        #expect(winner?.kind == .shelf)
    }

    @Test func expiredActivitiesAreNeverChosen() {
        let expiredAgent = NotchActivity(
            kind: .agent,
            trailingText: "done",
            expiresAt: referenceDate.addingTimeInterval(-1)
        )
        let liveMedia = NotchActivity(kind: .media, trailingText: "Song")
        let winner = NotchActivityArbiter.frontmostActivity(
            among: [expiredAgent, liveMedia],
            asOf: referenceDate
        )
        #expect(winner?.kind == .media)
    }

    @Test func anActivityExpiresExactlyAtItsDeadline() {
        let activity = NotchActivity(kind: .battery, trailingText: "80%", expiresAt: referenceDate)
        #expect(activity.isExpired(asOf: referenceDate))
        #expect(!activity.isExpired(asOf: referenceDate.addingTimeInterval(-0.001)))
    }

    @Test func upsertReplacesRatherThanStacksTheSameKind() {
        let firstTrack = NotchActivity(kind: .media, trailingText: "Track one")
        let secondTrack = NotchActivity(kind: .media, trailingText: "Track two")
        let afterFirst = NotchActivityArbiter.upserting(firstTrack, into: [])
        let afterSecond = NotchActivityArbiter.upserting(secondTrack, into: afterFirst)

        #expect(afterSecond.count == 1)
        #expect(afterSecond.first?.trailingText == "Track two")
    }

    @Test func removingDropsOnlyTheNamedKind() {
        let activities = [
            NotchActivity(kind: .media, trailingText: "Song"),
            NotchActivity(kind: .timer, trailingText: "5:00")
        ]
        let remaining = NotchActivityArbiter.removing(kind: .media, from: activities)
        #expect(remaining.map(\.kind) == [.timer])
    }

    @Test func emptyInputYieldsNothingRatherThanCrashing() {
        #expect(NotchActivityArbiter.frontmostActivity(among: [], asOf: referenceDate) == nil)
    }
}

@MainActor
struct NotchTimerStoreTests {

    @Test(arguments: [
        ("25m", TimeInterval(1_500)),
        ("1h30m", TimeInterval(5_400)),
        ("90s", TimeInterval(90)),
        ("2h15m", TimeInterval(8_100)),
        ("45", TimeInterval(2_700)),
        ("1h", TimeInterval(3_600))
    ])
    func parsesTheShorthandPeopleActuallyType(input: String, expected: TimeInterval) {
        #expect(NotchTimerStore.parseDuration(from: input) == expected)
    }

    @Test(arguments: ["", "soon", "abc", "0"])
    func returnsNilRatherThanGuessingADuration(input: String) {
        #expect(NotchTimerStore.parseDuration(from: input) == nil)
    }

    @Test func formatsUnderAnHourAsMinutesAndSeconds() {
        #expect(NotchTimerStore.formatted(remainingSeconds: 65) == "1:05")
        #expect(NotchTimerStore.formatted(remainingSeconds: 5) == "0:05")
    }

    @Test func formatsOverAnHourWithAnHoursField() {
        #expect(NotchTimerStore.formatted(remainingSeconds: 3_725) == "1:02:05")
    }

    @Test func roundsPartialSecondsUpSoTheLastSecondIsVisible() {
        // Counting down from 5.4 should read "0:06", not flash "0:05" early.
        #expect(NotchTimerStore.formatted(remainingSeconds: 5.4) == "0:06")
    }
}

@MainActor
struct NowPlayingLabelTests {

    @Test func shortTitlesPassThroughUntouched() {
        #expect(NowPlayingMonitor.pillLabel(forTrackTitle: "Roygbiv") == "Roygbiv")
    }

    @Test func longTitlesTruncateOnAWordBoundaryWhenThereIsOne() {
        let label = NowPlayingMonitor.pillLabel(forTrackTitle: "Everything In Its Right Place")
        #expect(label.hasSuffix("…"))
        #expect(label.count <= 15)
        #expect(!label.contains("  "))
    }

    @Test func longSingleWordTitlesStillGetCut() {
        let label = NowPlayingMonitor.pillLabel(forTrackTitle: "Supercalifragilistic")
        #expect(label == "Supercalifragi…")
    }
}
