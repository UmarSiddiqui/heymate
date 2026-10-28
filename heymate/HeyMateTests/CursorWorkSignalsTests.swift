//
//  CursorWorkSignalsTests.swift
//  HeyMateTests
//
//  The reply pace and step kind the thinking cursor shows.
//

import Testing
@testable import HeyMate

struct CursorWorkSignalsTests {

    @Test func firstSampleOnlySetsTheBaseline() {
        var pace = CursorWorkPace()
        pace.sample(textLength: 400, at: 10)
        #expect(pace.tokensPerSecond == nil)
        #expect(pace.tempo == .calm)
    }

    @Test func tempoFollowsSmoothedTokenRate() {
        var pace = CursorWorkPace()
        pace.sample(textLength: 0, at: 0)
        // 40 characters in 0.5 s = 20 tokens/s.
        pace.sample(textLength: 40, at: 0.5)
        #expect(pace.tokensPerSecond == 20)
        #expect(pace.tempo == .busy)
        // Then 80 tokens/s: 0.65 × 20 + 0.35 × 80 = 41.
        pace.sample(textLength: 200, at: 1.0)
        #expect(abs((pace.tokensPerSecond ?? 0) - 41) < 0.0001)
        #expect(pace.tempo == .racing)
    }

    @Test func stallsAndNewRepliesSlowItDown() {
        var pace = CursorWorkPace()
        pace.sample(textLength: 0, at: 0)
        pace.sample(textLength: 80, at: 0.5)
        // A shorter text is a new reply and counts as no progress.
        pace.sample(textLength: 10, at: 1.0)
        #expect(pace.tempo == .busy)
        // 40 tokens/s decays below 8 after four quiet samples.
        for time in [1.5, 2.0, 2.5] { pace.sample(textLength: 10, at: time) }
        #expect(pace.tempo == .calm)
    }

    @Test func shortIntervalsAreFlooredAtAQuarterSecond() {
        var pace = CursorWorkPace()
        pace.sample(textLength: 0, at: 0)
        pace.sample(textLength: 8, at: 0.01)
        #expect(pace.tokensPerSecond == 8)
    }

    @Test func activityFirstMatchWins() {
        #expect(CursorActivityKind.classify("tool start: web_search") == .web)
        #expect(CursorActivityKind.classify("Reading package.json") == .reading)
        #expect(CursorActivityKind.classify("tool: edit_file") == .writing)
        #expect(CursorActivityKind.classify("tool start: bash") == .tool)
        #expect(CursorActivityKind.classify("Thinking") == .reasoning)
        #expect(CursorActivityKind.classify("Took a screenshot") == .image)
        #expect(CursorActivityKind.classify("HeyMate Agent connected") == nil)
        #expect(CursorActivityKind.classify(nil) == nil)
    }
}
