//
//  StarNudgeTests.swift
//  leanring-buddyTests
//
//  The GitHub star ask waits for a few answered questions and never returns
//  once the user has answered it either way.
//

import Testing
@testable import HeyMate

struct StarNudgeTests {

    @Test func waitsForEnoughAnsweredQuestions() {
        let threshold = StarNudgePreferences.answersBeforeOffering
        #expect(!StarNudgePreferences.shouldOffer(answeredQuestionCount: 0, isResolved: false))
        #expect(!StarNudgePreferences.shouldOffer(answeredQuestionCount: threshold - 1, isResolved: false))
        #expect(StarNudgePreferences.shouldOffer(answeredQuestionCount: threshold, isResolved: false))
    }

    @Test func neverReturnsOnceAnswered() {
        let threshold = StarNudgePreferences.answersBeforeOffering
        #expect(!StarNudgePreferences.shouldOffer(answeredQuestionCount: threshold, isResolved: true))
        #expect(!StarNudgePreferences.shouldOffer(answeredQuestionCount: threshold * 10, isResolved: true))
    }
}
