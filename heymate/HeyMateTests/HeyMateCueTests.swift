//
//  HeyMateCueTests.swift
//  HeyMateTests
//
//  Every sound has a motion, the motion's biggest moment lands on the
//  sound's peak, cues stay micro (hatching aside), Reduce Motion is
//  opacity only, and one call plays the sound and publishes the motion.
//

import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import HeyMate

@MainActor
struct HeyMateCueTests {

    /// How far a motion accent may sit from a beat of its sound. One frame
    /// at 60 Hz is ~17 ms; two frames is still heard as "on the beat".
    private let syncTolerance: TimeInterval = 0.035

    private func samples(upTo end: TimeInterval, step: TimeInterval = 0.005) -> [TimeInterval] {
        stride(from: 0, through: end + step, by: step).map { $0 }
    }

    @Test func everySoundHasAMotion() {
        for sound in UISoundPlayer.Sound.allCases {
            let parts = CueChoreography.parts(for: sound)
            #expect(!parts.isEmpty, "\(sound) has no parts")
            for part in parts {
                #expect(CueChoreography.motion(for: sound, part: part) != nil, "\(sound) \(part) has no motion")
            }
            #expect(CueChoreography.duration(for: sound) > 0, "\(sound) has no duration")
        }
    }

    @Test func timingIsMeasuredAndOrdered() {
        for sound in UISoundPlayer.Sound.allCases {
            let timing = CueChoreography.timing(for: sound)
            #expect(timing.peak >= 0 && timing.peak < timing.audible, "\(sound) peak/audible out of order")
            for beat in timing.beats {
                #expect(beat >= 0 && beat < timing.audible, "\(sound) beat \(beat) outside the sound")
            }
        }
    }

    @Test func accentLandsOnABeatOfTheSound() {
        for sound in UISoundPlayer.Sound.allCases {
            let timing = CueChoreography.timing(for: sound)
            let accent = CueChoreography.accent(for: sound)
            let beats = [timing.peak] + timing.beats
            let nearest = beats.map { abs($0 - accent.time) }.min() ?? .infinity
            #expect(nearest <= syncTolerance, "\(sound) accent at \(accent.time)s misses its beats \(beats)")
        }
    }

    @Test func accentIsAKeyedMomentOfItsPart() {
        for sound in UISoundPlayer.Sound.allCases {
            let accent = CueChoreography.accent(for: sound)
            #expect(CueChoreography.parts(for: sound).contains(accent.part), "\(sound) accents a part it doesn't animate")
            let keys = CueChoreography.motion(for: sound, part: accent.part)?.keyTimes ?? []
            #expect(keys.contains { abs($0 - accent.time) < 0.0005 }, "\(sound) accent \(accent.time)s is not a keyframe")
        }
    }

    @Test func motionStartsWithTheSound() {
        for sound in UISoundPlayer.Sound.allCases {
            let keys = CueChoreography.parts(for: sound)
                .compactMap { CueChoreography.motion(for: sound, part: $0) }
                .flatMap(\.keyTimes)
            #expect(keys.min() == 0, "\(sound) motion doesn't start at t = 0")
        }
    }

    /// 4–12 pt of travel and 0.92–1.08 scale for the element itself. The
    /// mic dot's grow-in (0.6) is in the spec; props (the tapback's 1.15,
    /// the done ring) and sparkles are separate small objects.
    @Test func subjectsStayMicro() {
        for sound in UISoundPlayer.Sound.allCases where !CueChoreography.isShowpiece(sound) {
            guard let motion = CueChoreography.motion(for: sound, part: .subject) else { continue }
            for time in samples(upTo: motion.endTime) {
                let frame = motion.frame(at: time)
                let largest = max(frame.scale * frame.scaleX, frame.scale * frame.scaleY)
                let smallest = min(frame.scale * frame.scaleX, frame.scale * frame.scaleY)
                #expect(largest <= 1.08 + 0.0001, "\(sound) grows to \(largest) at \(time)s")
                if sound != .listenStart {
                    #expect(smallest >= 0.92 - 0.0001, "\(sound) shrinks to \(smallest) at \(time)s")
                }
                #expect(abs(frame.offsetX) <= 12 && abs(frame.offsetY) <= 12, "\(sound) travels too far at \(time)s")
                #expect(abs(frame.rotation) <= 6, "\(sound) tilts too far at \(time)s")
            }
        }
    }

    @Test func onlyHatchingIsLong() {
        for sound in UISoundPlayer.Sound.allCases {
            let duration = CueChoreography.duration(for: sound)
            if CueChoreography.isShowpiece(sound) {
                #expect(duration <= 5.5, "hatching outlasts its 5.5 s file")
            } else {
                let audible = CueChoreography.timing(for: sound).audible
                #expect(duration <= max(audible, 0.6) + 0.05, "\(sound) moves for \(duration)s, past its sound")
            }
        }
    }

    /// The subject ends at rest, except the ones that leave (a closed job
    /// card, a removed item, a closing panel's content).
    @Test func subjectsSettle() {
        let exits: [UISoundPlayer.Sound] = [.panelClose, .jobClosed, .levelDown]
        for sound in UISoundPlayer.Sound.allCases {
            guard let motion = CueChoreography.motion(for: sound, part: .subject) else { continue }
            let end = motion.frame(at: motion.endTime + 1)
            #expect(end.offsetX == 0 && end.rotation == 0, "\(sound) doesn't settle")
            if exits.contains(sound) {
                #expect(end.opacity == 0, "\(sound) should leave")
            } else {
                #expect(end.opacity == 1 && abs(end.scale - 1) < 0.0001 && end.offsetY == 0, "\(sound) doesn't settle")
            }
        }
    }

    @Test func reduceMotionIsOpacityOnly() {
        for sound in UISoundPlayer.Sound.allCases {
            for part in CueChoreography.parts(for: sound) {
                guard let motion = CueChoreography.motion(for: sound, part: part) else { continue }
                for time in samples(upTo: motion.endTime, step: 0.02) {
                    let frame = CueChoreography.frame(for: sound, part: part, elapsed: time, reduceMotion: true)
                    #expect(frame.scale == 1 && frame.scaleX == 1 && frame.scaleY == 1, "\(sound) \(part) scales under Reduce Motion")
                    #expect(frame.offsetX == 0 && frame.offsetY == 0, "\(sound) \(part) moves under Reduce Motion")
                    #expect(frame.rotation == 0, "\(sound) \(part) rotates under Reduce Motion")
                }
                let settled = CueChoreography.frame(
                    for: sound, part: part,
                    elapsed: CueChoreography.reducedMotionFadeDuration, reduceMotion: true
                )
                #expect(settled.opacity == motion.frame(at: motion.endTime).opacity, "\(sound) \(part) fade doesn't settle in 0.15 s")
            }
        }
    }

    @Test func reducedMotionFadeMatchesTheDesignToken() {
        #expect(CueChoreography.reducedMotionFadeDuration == DS.Animation.fast)
    }

    @Test func hatchingFollowsTheRumble() {
        let egg = CueChoreography.motion(for: .hatching, part: .prop)!
        let early = samples(upTo: 0.6).map { abs(egg.frame(at: $0).rotation) }.max() ?? 0
        let late = stride(from: 2.0, through: 2.5, by: 0.005).map { abs(egg.frame(at: $0).rotation) }.max() ?? 0
        #expect(early <= 2.8, "the egg wobbles too hard at the start of the rumble")
        #expect(late >= 4.4 && late <= 5.0, "the egg should reach about ±5° before it bursts")

        let firstCrack = CueChoreography.motion(for: .hatching, part: .item(0))!
        let secondCrack = CueChoreography.motion(for: .hatching, part: .item(1))!
        #expect(firstCrack.frame(at: 1.59).opacity == 0 && firstCrack.frame(at: 1.64).opacity == 1)
        #expect(secondCrack.frame(at: 2.09).opacity == 0 && secondCrack.frame(at: 2.14).opacity == 1)

        let face = CueChoreography.motion(for: .hatching, part: .subject)!
        #expect(face.frame(at: 2.5).opacity == 0)
        #expect(abs(face.frame(at: 2.8).scale - 1.1) < 0.0001)
        #expect(abs(face.frame(at: 3.2).scale - 1.0) < 0.0001)
    }

    // MARK: Word reveal

    @Test func replyWordsRevealFromThePop() {
        let pop = CueChoreography.accent(for: .messageReceived).time
        #expect(CueChoreography.revealedWordCount(totalWords: 10, elapsed: pop - 0.01, reduceMotion: false) == 0)
        #expect(CueChoreography.revealedWordCount(totalWords: 10, elapsed: pop, reduceMotion: false) == 1)
        #expect(CueChoreography.revealedWordCount(totalWords: 10, elapsed: pop + 0.035 * 3 + 0.001, reduceMotion: false) == 4)
        let end = CueChoreography.wordRevealDuration(totalWords: 10)
        #expect(CueChoreography.revealedWordCount(totalWords: 10, elapsed: end + 0.001, reduceMotion: false) == 10)
        #expect(CueChoreography.revealedWordCount(totalWords: 10, elapsed: 0, reduceMotion: true) == 10)
    }

    @Test func longRepliesRevealQuickly() {
        #expect(CueChoreography.wordRevealDuration(totalWords: 400) <= CueChoreography.accent(for: .messageReceived).time + 1.5 + 0.0001)
    }

    @Test func hiddenWordsKeepTheirPlace() {
        #expect(ChatWordReveal.hiddenStartOffset(afterWords: 0, in: "hello there") == 0)
        #expect(ChatWordReveal.hiddenStartOffset(afterWords: 1, in: "hello there") == 6)
        #expect(ChatWordReveal.hiddenStartOffset(afterWords: 2, in: "hello there") == nil)
        #expect(ChatWordReveal.hiddenStartOffset(afterWords: 1, in: "  hi\n\nyou") == 6)

        let hidden = ChatWordReveal.hidingWords(after: 1, in: AttributedString("hello there"))
        #expect(String(hidden.characters) == "hello there")
    }

    @Test func revealBudgetsCrossBlocks() {
        let blocks = ChatWordReveal.blocks(from: "One two\n\n```\ncode\n```\nthree four")
        #expect(blocks.count == 3)
        #expect(ChatWordReveal.budgets(for: blocks, visibleWords: nil) == [nil, nil, nil])
        #expect(ChatWordReveal.budgets(for: blocks, visibleWords: 1) == [1, 0, 0])
        #expect(ChatWordReveal.budgets(for: blocks, visibleWords: 3) == [nil, nil, 0])
        #expect(ChatWordReveal.budgets(for: blocks, visibleWords: 4) == [nil, nil, 1])
        #expect(ChatWordReveal.totalWords(in: "**Bold** words `here`") == 3)
    }

    // MARK: One cue, one call

    @Test func oneCallPlaysTheSoundAndPublishesTheMotion() {
        var played: [UISoundPlayer.Sound] = []
        let clock = Date(timeIntervalSince1970: 1_000)
        let center = HeyMateCue(now: { clock }, playSound: { played.append($0) })

        let event = center.fire(.jobDone, subject: "run-1")

        #expect(played == [.jobDone])
        #expect(center.lastCue == event)
        #expect(center.activeCue(for: [.jobDone], subject: "run-1", at: clock) == event)
        #expect(center.activeCue(for: [.jobDone], subject: "run-2", at: clock) == nil)
        #expect(center.activeCue(for: [.jobDone], subject: nil, at: clock) == event)
        #expect(center.activeCue(for: [.jobStarted], subject: nil, at: clock) == nil)
        let afterwards = clock.addingTimeInterval(CueChoreography.duration(for: .jobDone) + 0.01)
        #expect(center.activeCue(for: [.jobDone], subject: "run-1", at: afterwards) == nil)
    }

    @Test func onlyTheNewestMessageJoinsItsCue() {
        let clock = Date(timeIntervalSince1970: 1_000)
        let center = HeyMateCue(now: { clock }, playSound: { _ in })
        let event = center.fire(.messageSent)
        let justSent = clock.addingTimeInterval(0.02)
        let earlier = clock.addingTimeInterval(-30)
        #expect(center.activeCue(for: [.messageSent], subject: nil, bornAt: justSent, at: justSent) == event)
        #expect(center.activeCue(for: [.messageSent], subject: nil, bornAt: earlier, at: justSent) == nil)
    }

    /// The motion doesn't depend on the sound playing: a center whose
    /// sound is a no-op (sounds off) still publishes the cue.
    @Test func motionPlaysWithSoundsOff() {
        let center = HeyMateCue(playSound: { _ in })
        center.fire(.thumbsUp)
        #expect(center.lastCue?.sound == .thumbsUp)
    }

    @Test func oldCuesArePruned() {
        var now = Date(timeIntervalSince1970: 1_000)
        let center = HeyMateCue(now: { now }, playSound: { _ in })
        center.fire(.messageSent)
        now = now.addingTimeInterval(HeyMateCue.retention + 0.1)
        center.fire(.messageReceived)
        #expect(center.recentCues.map(\.sound) == [.messageReceived])

        for _ in 0..<(HeyMateCue.maximumRecentCues + 5) { center.fire(.jobDone) }
        #expect(center.recentCues.count == HeyMateCue.maximumRecentCues)
    }
}
