//
//  NotchBuddyTests.swift
//  HeyMateTests
//
//  The collapsed notch's character: state mapping, pace, doze, rotation,
//  Reduce Motion and redraw scheduling. Pure values; no windows.
//

import CoreGraphics
import Foundation
import Testing
@testable import HeyMate

@MainActor
struct NotchBuddyTests {
    private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let mateA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let mateB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let mateC = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

    private func run(_ mate: UUID, _ status: AgentRunStatus, action: String = "Working",
                     createdAt offset: TimeInterval = 0, id: Int = 1) -> NotchBuddyRun {
        NotchBuddyRun(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
                      mateID: mate, status: status, latestAction: action,
                      createdAt: base.addingTimeInterval(offset))
    }

    private func context(runs: [NotchBuddyRun] = [], state: CompanionState = .idle) -> NotchBuddyContext {
        var context = NotchBuddyContext(activeMateID: mateA, now: base)
        context.runs = runs
        context.companionState = state
        return context
    }

    // MARK: State mapping

    @Test func companionStatesMapToPoses() {
        #expect(NotchBuddyDirector.pose(for: .idle) == nil)
        #expect(NotchBuddyDirector.pose(for: .agentRunning(UUID())) == nil)
        #expect(NotchBuddyDirector.pose(for: .listening(.talk)) == .listening)
        #expect(NotchBuddyDirector.pose(for: .finalizingTranscript) == .listening)
        #expect(NotchBuddyDirector.pose(for: .capturingContext) == .thinking)
        #expect(NotchBuddyDirector.pose(for: .thinking) == .thinking)
        #expect(NotchBuddyDirector.pose(for: .speaking) == .speaking)
        #expect(NotchBuddyDirector.pose(for: .guiding) == .guiding)
        #expect(NotchBuddyDirector.pose(for: .waitingForApproval(UUID())) == .attention)
        #expect(NotchBuddyDirector.pose(for: .error("x")) == .failed)
    }

    @Test func runsPickTheirWorkKindAndWaveWhenTheyNeedYou() {
        let now = base
        #expect(NotchBuddyDirector.pose(for: run(mateA, .running, action: "Reading Package.swift"), at: now) == .working(.reading, .walk))
        #expect(NotchBuddyDirector.pose(for: run(mateA, .running, action: "Editing README"), at: now) == .working(.writing, .walk))
        #expect(NotchBuddyDirector.pose(for: run(mateA, .running, action: "Running tests"), at: now) == .working(.tooling, .walk))
        #expect(NotchBuddyDirector.pose(for: run(mateA, .running, action: "Searching the web"), at: now) == .working(.browsing, .walk))
        #expect(NotchBuddyDirector.pose(for: run(mateA, .running, action: "Thinking it over"), at: now) == .working(.reasoning, .walk))
        #expect(NotchBuddyDirector.pose(for: run(mateA, .running, action: "Working on it"), at: now) == .working(.none, .walk))
        #expect(NotchBuddyDirector.pose(for: run(mateA, .planning), at: now) == .working(.reasoning, .walk))
        #expect(NotchBuddyDirector.pose(for: run(mateA, .awaitingPlanApproval), at: now) == .attention)
        #expect(NotchBuddyDirector.pose(for: run(mateA, .waitingForApproval), at: now) == .attention)
        #expect(NotchBuddyDirector.pose(for: run(mateA, .queued), at: now) == .idle)
    }

    @Test func voiceOutranksJobsOnTheActiveMate() {
        let scene = NotchBuddyDirector.scene(context(runs: [run(mateB, .running)], state: .speaking),
                                             at: base.addingTimeInterval(1), still: false)
        #expect(scene.pose == .speaking)
        #expect(scene.mateID == mateA)
        #expect(scene.liveMateCount == 1)
    }

    @Test func finishedJobsCelebrateOrWobbleOnce() {
        var context = context()
        context.outcomes = [NotchBuddyOutcome(runID: UUID(), mateID: mateB, succeeded: true, at: base)]
        let during = NotchBuddyDirector.scene(context, at: base.addingTimeInterval(0.5), still: false)
        #expect(during.pose == .celebrate)
        #expect(during.mateID == mateB)
        let after = NotchBuddyDirector.scene(context, at: base.addingTimeInterval(NotchBuddyDirector.outcomeDuration + 0.1), still: false)
        #expect(after.pose == .idle)
        // Once-poses hold their last frame rather than looping.
        #expect(NotchBuddyFrameClock.frame(for: .celebrate, elapsed: 10, still: false) == 15)

        context.outcomes = [NotchBuddyOutcome(runID: UUID(), mateID: mateB, succeeded: false, at: base)]
        #expect(NotchBuddyDirector.scene(context, at: base.addingTimeInterval(0.5), still: false).pose == .failed)
    }

    @Test func modelRecordsOutcomesOnlyForObservedTransitions() {
        var clock = base
        let model = NotchBuddyModel(defaultMateID: mateA, now: { clock })
        var job = AgentRun.queued(id: UUID(), title: "t", prompt: "", workspaceURL: URL(fileURLWithPath: "/tmp/x"),
                                  executor: .openCode, origin: .sandbox, createdAt: base)
        // Loaded already finished: history, not news.
        job.status = .succeeded
        model.setRuns([job])
        #expect(model.context.outcomes.isEmpty)

        var live = AgentRun.queued(id: UUID(), title: "t", prompt: "", workspaceURL: URL(fileURLWithPath: "/tmp/y"),
                               executor: .openCode, origin: .sandbox, createdAt: base)
        live.status = .running
        model.setRuns([live])
        clock = clock.addingTimeInterval(2)
        live.status = .succeeded
        model.setRuns([live])
        #expect(model.context.outcomes.count == 1)
        #expect(model.context.outcomes.first?.succeeded == true)
    }

    // MARK: Pace

    @Test func paceThresholds() {
        #expect(NotchBuddyGait.forRate(0) == .walk)
        #expect(NotchBuddyGait.forRate(7.99) == .walk)
        #expect(NotchBuddyGait.forRate(8) == .run)
        #expect(NotchBuddyGait.forRate(27.9) == .run)
        #expect(NotchBuddyGait.forRate(28) == .sprint)
        #expect(NotchBuddyGait.forRate(.nan) == .walk)
    }

    @Test func paceSmoothsSamples() {
        var pace = NotchBuddyPace()
        pace.sample(units: 0, at: base)
        #expect(pace.smoothedRate == nil)
        // Second observation seeds directly: 20 units over 1 s.
        pace.sample(units: 20, at: base.addingTimeInterval(1))
        #expect(pace.smoothedRate == 20)
        // Then 0.65 · previous + 0.35 · sample.
        pace.sample(units: 40, at: base.addingTimeInterval(2))
        #expect(abs((pace.smoothedRate ?? 0) - (0.65 * 20 + 0.35 * 40)) < 0.0001)
        // Intervals shorter than 0.25 s are clamped.
        var burst = NotchBuddyPace()
        burst.sample(units: 0, at: base)
        burst.sample(units: 10, at: base.addingTimeInterval(0.01))
        #expect(burst.smoothedRate == 40)
    }

    @Test func activityEntriesDrivePaceAndGoStale() {
        var tracker = NotchBuddyPaceTracker()
        var job = AgentRun.queued(id: UUID(), title: "t", prompt: "", workspaceURL: URL(fileURLWithPath: "/tmp/x"),
                                  executor: .openCode, origin: .sandbox, createdAt: base)
        job.status = .running
        tracker.observe([job], at: base)
        #expect(tracker.pace(for: job.id)?.gait(at: base) == .walk)

        // One entry per second is 24 token-equivalents per second: a run.
        var now = base
        for _ in 0..<6 {
            now = now.addingTimeInterval(1)
            job.appendActivity(kind: .progress, text: "step \(job.activity.count)", createdAt: now)
            tracker.observe([job], at: now)
        }
        #expect(tracker.pace(for: job.id)?.gait(at: now) == .run)

        // Two entries every 0.5 s is 96/s: a sprint.
        for _ in 0..<8 {
            now = now.addingTimeInterval(0.5)
            job.appendActivity(kind: .progress, text: "a\(job.activity.count)", createdAt: now)
            job.appendActivity(kind: .agent, text: "b\(job.activity.count)", createdAt: now)
            tracker.observe([job], at: now)
        }
        #expect(tracker.pace(for: job.id)?.gait(at: now) == .sprint)

        // Quiet for longer than `staleAfter`: back to a walk, no timer.
        #expect(tracker.pace(for: job.id)?.gait(at: now.addingTimeInterval(NotchBuddyPace.staleAfter + 1)) == .walk)

        // User messages are not work.
        var other = NotchBuddyPaceTracker()
        other.observe([job], at: now)
        job.appendActivity(kind: .user, text: "hurry up", createdAt: now.addingTimeInterval(1))
        other.observe([job], at: now.addingTimeInterval(1))
        #expect(other.pace(for: job.id)?.smoothedRate == 0)
    }

    // MARK: Doze

    @Test func dozesAfterTwoQuietMinutesAndWakesOnActivity() {
        let quiet = context()
        #expect(NotchBuddyDirector.scene(quiet, at: base.addingTimeInterval(119), still: false).pose == .idle)
        let dozing = NotchBuddyDirector.scene(quiet, at: base.addingTimeInterval(120), still: false)
        #expect(dozing.pose == .doze)
        #expect(dozing.since == base.addingTimeInterval(120))

        // A live job keeps it awake however long it runs.
        #expect(NotchBuddyDirector.scene(context(runs: [run(mateA, .running)]),
                                         at: base.addingTimeInterval(600), still: false).pose != .doze)

        var clock = base
        let model = NotchBuddyModel(defaultMateID: mateA, now: { clock })
        clock = base.addingTimeInterval(200)
        #expect(NotchBuddyDirector.isDozing(model.context, at: clock))
        model.noteUserPresence()
        #expect(model.context.wakeStartedAt == clock)
        #expect(NotchBuddyDirector.scene(model.context, at: clock.addingTimeInterval(0.2), still: false).pose == .waking)
        let afterWake = clock.addingTimeInterval(NotchBuddyDirector.wakeDuration + 0.05)
        #expect(NotchBuddyDirector.scene(model.context, at: afterWake, still: false).pose == .idle)
        // The idle clock restarted, so it does not doze straight back.
        #expect(!NotchBuddyDirector.isDozing(model.context, at: clock.addingTimeInterval(119)))
    }

    @Test func voiceWakesWithoutAStretch() {
        let clock = base
        let model = NotchBuddyModel(defaultMateID: mateA, now: { clock.addingTimeInterval(300) })
        model.setCompanionState(.listening(.talk))
        #expect(NotchBuddyDirector.scene(model.context, at: clock.addingTimeInterval(300.1), still: false).pose == .listening)
    }

    // MARK: Rotation

    @Test func rotationOrderIsUrgencyThenAge() {
        let runs = [
            run(mateA, .running, createdAt: 0, id: 1),
            run(mateB, .running, createdAt: -10, id: 2),
            run(mateC, .awaitingPlanApproval, createdAt: 30, id: 3),
            run(mateA, .queued, createdAt: -50, id: 4),
            run(mateB, .succeeded, createdAt: -99, id: 5),
        ]
        let order = NotchBuddyDirector.rotation(runs)
        #expect(order.map(\.mateID) == [mateC, mateB, mateA])
        // Each mate is shown by its most urgent job.
        #expect(order.last?.id == runs[0].id)
    }

    @Test func rotatesEveryFourSecondsAndHoldsTheMostUrgentUnderReduceMotion() {
        let context = context(runs: [
            run(mateA, .running, createdAt: 0, id: 1),
            run(mateB, .waitingForApproval, createdAt: 5, id: 2),
        ])
        let slotStart = Date(timeIntervalSinceReferenceDate: (base.timeIntervalSinceReferenceDate / 4).rounded(.down) * 4 + 400)
        let first = NotchBuddyDirector.scene(context, at: slotStart.addingTimeInterval(0.1), still: false)
        let second = NotchBuddyDirector.scene(context, at: slotStart.addingTimeInterval(4.1), still: false)
        let third = NotchBuddyDirector.scene(context, at: slotStart.addingTimeInterval(8.1), still: false)
        #expect(first.mateID != second.mateID)
        #expect(first.mateID == third.mateID)
        #expect(first.since == slotStart)
        #expect(Set([first.mateID, second.mateID]) == [mateA, mateB])

        for offset in [0.1, 4.1, 8.1] {
            let still = NotchBuddyDirector.scene(context, at: slotStart.addingTimeInterval(offset), still: true)
            #expect(still.mateID == mateB)
            #expect(still.pose == .attention)
        }
    }

    // MARK: Reduce Motion and redraws

    @Test func reduceMotionGivesAStillPose() {
        let poses: [NotchBuddyPose] = [.idle, .doze, .listening, .speaking, .attention, .celebrate,
                                       .working(.writing, .sprint), .working(.none, .run)]
        for pose in poses {
            for elapsed in [0.0, 0.3, 1.7, 42] {
                #expect(NotchBuddyFrameClock.frame(for: pose, elapsed: elapsed, still: true) == NotchBuddyFrameClock.stillFrame)
            }
            let still = NotchBuddyFigure.make(pose: pose, frame: 0, loop: 0)
            #expect(still == NotchBuddyFigure.make(pose: pose, frame: NotchBuddyFrameClock.frame(for: pose, elapsed: 9, still: true), loop: 0))
        }
        // No wake-up stretch under Reduce Motion.
        var context = context()
        context.wakeStartedAt = base
        #expect(NotchBuddyDirector.scene(context, at: base.addingTimeInterval(0.2), still: true).pose == .idle)
    }

    @Test func frameClockLoopsFromPoseStart() {
        #expect(NotchBuddyFrameClock.frame(for: .idle, elapsed: 0, still: false) == 0)
        #expect(NotchBuddyFrameClock.frame(for: .idle, elapsed: 1, still: false) == 8)
        #expect(NotchBuddyFrameClock.frame(for: .idle, elapsed: 2, still: false) == 0)
        #expect(NotchBuddyFrameClock.loop(for: .idle, elapsed: 4.1, still: false) == 2)
        #expect(NotchBuddyFrameClock.frame(for: .working(.none, .sprint), elapsed: 0.5, still: false) == 9)
        #expect(NotchBuddyFrameClock.frame(for: .idle, elapsed: -3, still: false) == 0)
        for pose in [NotchBuddyPose.doze, .idle, .working(.none, .sprint)] {
            #expect(NotchBuddyFrameClock.redrawInterval(for: pose) >= 1 / NotchBuddyFrameClock.maximumFPS)
        }
    }

    @Test func redrawsStopWhenHiddenOrStill() {
        let hidden = NotchBuddyMotion(policy: CompanionMotionPolicy(reduceMotion: false, idleAnimations: true, isVisible: false))
        #expect(hidden.nextRedraw(after: base, context: context()) == nil)

        let animated = NotchBuddyMotion(policy: CompanionMotionPolicy(reduceMotion: false, idleAnimations: true, isVisible: true))
        let next = animated.nextRedraw(after: base.addingTimeInterval(1), context: context())
        #expect(next == base.addingTimeInterval(1 + 1.0 / 8))

        // Still: one wake-up at the doze onset, then nothing.
        let still = NotchBuddyMotion(policy: CompanionMotionPolicy(reduceMotion: true, idleAnimations: true, isVisible: true))
        #expect(still.nextRedraw(after: base.addingTimeInterval(1), context: context()) == base.addingTimeInterval(120))
        #expect(still.nextRedraw(after: base.addingTimeInterval(121), context: context()) == nil)

        // Idle motion off: the idle pose holds, but a working mate walks.
        let calm = NotchBuddyMotion(policy: CompanionMotionPolicy(reduceMotion: false, idleAnimations: false, isVisible: true))
        #expect(calm.nextRedraw(after: base.addingTimeInterval(1), context: context()) == base.addingTimeInterval(120))
        let working = context(runs: [run(mateA, .running)])
        #expect(calm.nextRedraw(after: base.addingTimeInterval(1), context: working) == base.addingTimeInterval(1 + 1.0 / 14))
    }

    // MARK: Full screen

    @Test func onlyEdgeToEdgeWindowsCountAsFullScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(NotchFullScreenMonitor.coversScreen(windowBounds: [screen], screenFrame: screen))
        // A zoomed window stops under the menu bar.
        #expect(!NotchFullScreenMonitor.coversScreen(windowBounds: [CGRect(x: 0, y: 38, width: 1512, height: 944)], screenFrame: screen))
        #expect(!NotchFullScreenMonitor.coversScreen(windowBounds: [], screenFrame: screen))
        let external = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        #expect(NotchFullScreenMonitor.coversScreen(windowBounds: [external], screenFrame: external))
        #expect(!NotchFullScreenMonitor.coversScreen(windowBounds: [external], screenFrame: screen))
    }

    @Test func pillWidensForTheCharacterButNotInFullScreen() {
        let model = NotchPillModel()
        #expect(model.wantsWidenedFrame)
        model.isBuddySuppressed = true
        #expect(!model.wantsWidenedFrame)
        model.voiceState = .listening
        #expect(model.wantsWidenedFrame)
    }
}
