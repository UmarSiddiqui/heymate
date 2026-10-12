//
//  HarnessTurnNotesTests.swift
//  HeyMateTests
//
//  Situational notes that prefix a user message. No manager, no network.
//

import Foundation
import Testing
@testable import HeyMate

struct HarnessTurnNotesTests {
    private let now = Date(timeIntervalSince1970: 1_760_227_200) // 2025-10-12 00:00:00 UTC
    private let zone = TimeZone(identifier: "Australia/Perth")!

    private func input(
        hasScreenshot: Bool = false,
        userActedWhileThinking: Bool = false,
        isRetryOfFailedRun: Bool = false,
        kind: HarnessTurnKind = .conversation,
        runningJobs: [HarnessJobNote] = [],
        recentExchanges: [HarnessExchange] = [],
        routines: [HarnessRoutineLine] = [],
        includeRunningJobs: Bool = false,
        includeRecentExchanges: Bool = false,
        includeRoutines: Bool = false
    ) -> HarnessTurnNoteInput {
        HarnessTurnNoteInput(
            now: now,
            timeZone: zone,
            hasScreenshot: hasScreenshot,
            userActedWhileThinking: userActedWhileThinking,
            isRetryOfFailedRun: isRetryOfFailedRun,
            kind: kind,
            runningJobs: runningJobs,
            recentExchanges: recentExchanges,
            routines: routines,
            includeRunningJobs: includeRunningJobs,
            includeRecentExchanges: includeRecentExchanges,
            includeRoutines: includeRoutines
        )
    }

    @Test func everyTurnNamesTheDateAndTimezone() {
        let notes = HarnessTurnNotes.prefix(input())
        #expect(notes.hasPrefix("Today is "))
        #expect(notes.contains("Australia/Perth"))
        #expect(notes.contains("Sunday 12 October 2025"))
    }

    @Test func aMissingScreenshotIsCalledOut() {
        let notes = HarnessTurnNotes.prefix(input(hasScreenshot: false))
        #expect(notes.contains("No screenshot is attached."))
    }

    @Test func aScreenshotOmitsThatNote() {
        let notes = HarnessTurnNotes.prefix(input(hasScreenshot: true))
        #expect(!notes.contains("No screenshot is attached."))
    }

    @Test func aGuidedClickDuringTheTurnIsNoted() {
        let notes = HarnessTurnNotes.prefix(input(userActedWhileThinking: true))
        #expect(notes.contains("The user acted while you were thinking."))
    }

    @Test func aRetryAsksToContinueWhatIsAlreadyDone() {
        let notes = HarnessTurnNotes.prefix(input(isRetryOfFailedRun: true))
        #expect(notes.contains("Check what is already done and continue."))
    }

    @Test func routineAndStandingOrderBriefsAreMarkedAsHeyMate() {
        let routine = HarnessTurnNotes.prefix(input(kind: .routine(isFirstRun: true)))
        let standing = HarnessTurnNotes.prefix(input(kind: .standingOrder))
        #expect(routine.contains("This brief was written by HeyMate."))
        #expect(standing.contains("This brief was written by HeyMate."))
        #expect(!routine.contains("Report only what is new."))
    }

    @Test func laterRoutineRunsReportOnlyWhatIsNew() {
        let notes = HarnessTurnNotes.prefix(input(kind: .routine(isFirstRun: false)))
        #expect(notes.contains("Report only what is new."))
    }

    @Test func talkCanCarryRunningAndWaitingJobs() {
        let notes = HarnessTurnNotes.prefix(input(
            runningJobs: [
                HarnessJobNote(mateName: "Nova", title: "Draft the brief", state: .running),
                HarnessJobNote(mateName: "Ada", title: "Inbox check", state: .waiting)
            ],
            includeRunningJobs: true
        ))
        #expect(notes.contains("Agents still working:"))
        #expect(notes.contains("Nova — Draft the brief (running)"))
        #expect(notes.contains("Ada — Inbox check (waiting)"))
    }

    @Test func spawnedRunsGetRecentExchangesAsContextOnly() {
        let notes = HarnessTurnNotes.prefix(input(
            recentExchanges: [
                HarnessExchange(user: "Ship the landing page", assistant: "I'll plan it first.")
            ],
            includeRecentExchanges: true
        ))
        #expect(notes.contains("Use only if the transcript refers to them."))
        #expect(notes.contains("You: Ship the landing page"))
        #expect(notes.contains("HeyMate: I'll plan it first."))
    }

    @Test func aMateTurnListsLiveRoutinesAsAuthoritative() {
        let notes = HarnessTurnNotes.prefix(input(
            routines: [
                HarnessRoutineLine(
                    title: "Morning check",
                    scheduleSummary: "Every hour",
                    isPaused: false,
                    task: "Morning check\nLook at overnight mail"
                )
            ],
            includeRoutines: true
        ))
        #expect(notes.contains("This list is the one that is live:"))
        #expect(notes.contains("Morning check — Every hour — on."))
    }

    @Test func notesPrefixTheUserMessageAndStayOutOfAnEmptyTranscript() {
        let combined = HarnessTurnNotes.userMessage(notes: "Today is Monday.", transcript: "What is this?")
        #expect(combined == "Today is Monday.\n\nWhat is this?")
        #expect(HarnessTurnNotes.userMessage(notes: "   ", transcript: "Hello") == "Hello")
    }

    @Test func anOrdinaryTurnDoesNotInventAHeyMateBrief() {
        let notes = HarnessTurnNotes.prefix(input())
        #expect(!notes.contains("This brief was written by HeyMate."))
        #expect(!notes.contains("Agents still working:"))
        #expect(!notes.contains("Recent companion exchanges."))
    }

    @MainActor @Test func jobTitlesUseTheTaskNotTheNotes() {
        let notes = HarnessTurnNotes.prefix(HarnessTurnNoteInput(
            now: Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!,
            hasScreenshot: false, userActedWhileThinking: false, isRetryOfFailedRun: false,
            kind: .conversation, runningJobs: [], recentExchanges: [], routines: [],
            includeRunningJobs: false, includeRecentExchanges: false, includeRoutines: false
        ))
        let message = HarnessTurnNotes.userMessage(notes: notes, transcript: "Draft the launch email\n\nKeep it short")
        #expect(HarnessTurnNotes.transcript(fromUserMessage: message) == "Draft the launch email\n\nKeep it short")
        #expect(HeadlessAgentLauncher.title(from: message) == "Draft the launch email")
        #expect(HarnessTurnNotes.transcript(fromUserMessage: "Plain task") == "Plain task")
    }
}
