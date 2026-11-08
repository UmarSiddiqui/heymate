//
//  OnboardingInterviewTests.swift
//  HeyMateTests
//

import Testing
@testable import HeyMate

@MainActor
struct OnboardingInterviewTests {

    // MARK: Replies

    @Test func readsANextQuestion() {
        let reply = OnboardingInterview.parseReply(#"{"reaction": "Love that.", "question": "Who is it for?"}"#)
        #expect(reply == .next(reaction: "Love that.", question: "Who is it for?"))
    }

    @Test func readsOneTapSuggestions() {
        let text = #"{"reaction": "Nice.", "question": "Who is it for?", "suggestions": ["Students.", "students", "  ", "Small teams", "Me", "A fourth one"]}"#
        #expect(OnboardingInterview.parseReply(text)
            == .next(reaction: "Nice.", question: "Who is it for?", suggestions: ["Students", "Small teams", "Me"]))
    }

    @Test func transcriptSurvivesARoundTrip() {
        let lines = [
            OnboardingInterviewLine(speaker: .heyMate, text: "What are you working on?"),
            OnboardingInterviewLine(speaker: .user, text: "A Mac app."),
        ]
        #expect(OnboardingInterview.decode(OnboardingInterview.encode(lines)) == lines)
        #expect(OnboardingInterview.decode(nil).isEmpty)
    }

    @Test func readsAWrapUpWithMates() {
        let text = """
        Sure! Here you go:
        ```json
        {"reaction": "Nice.", "summary": "You're shipping a Mac app.", "mates": [
          {"name": "Launch Desk", "job": "Plans the launch."},
          {"name": "Bug Net", "job": "Triages crash reports."},
          {"name": "Inbox Scout", "job": "Sorts feedback email."},
          {"name": "Extra", "job": "Ignored, only three are kept."}
        ]}
        ```
        """
        guard case .wrapUp(let reaction, let summary, let mates) = OnboardingInterview.parseReply(text) else {
            Issue.record("expected a wrap-up")
            return
        }
        #expect(reaction == "Nice.")
        #expect(summary == "You're shipping a Mac app.")
        #expect(mates.map(\.name) == ["Launch Desk", "Bug Net", "Inbox Scout"])
    }

    @Test func readsEachMatesFirstJob() {
        let text = #"{"reaction": "Nice.", "summary": "s", "mates": [{"name": "Bug Net", "job": "Triages crashes.", "first_job": " I'll sort the open crashes. "}, {"name": "Quiet", "job": "Does work.", "first_job": ""}]}"#
        guard case .wrapUp(_, _, let mates) = OnboardingInterview.parseReply(text) else {
            Issue.record("expected a wrap-up")
            return
        }
        #expect(mates.map(\.firstJob) == ["I'll sort the open crashes.", nil])
    }

    @Test func resumesStepsFromTheLongerTour() {
        #expect(OnboardingStep.restored("voice") == .voice)
        #expect(OnboardingStep.restored("mic") == .talk)
        #expect(OnboardingStep.restored("circle") == .point)
        #expect(OnboardingStep.restored("type") == .kickoff)
        #expect(OnboardingStep.restored("firstTask") == .kickoff)
        #expect(OnboardingStep.restored("interview") == .interview)
        #expect(OnboardingStep.restored("nonsense") == nil)
        #expect(OnboardingStep.allCases.count == 10)
        #expect(OnboardingStep.allCases.first == .voice)
    }

    @Test func dropsMatesWithoutANameOrJob() {
        let text = #"{"reaction": "Ok.", "summary": "s", "mates": [{"name": "", "job": "x"}, {"name": "Real", "job": "Does work."}]}"#
        guard case .wrapUp(_, _, let mates) = OnboardingInterview.parseReply(text) else {
            Issue.record("expected a wrap-up")
            return
        }
        #expect(mates == [OnboardingMateSuggestion(name: "Real", job: "Does work.")])
    }

    @Test func nothingUsableFallsBack() {
        #expect(OnboardingInterview.parseReply("I'm not sure what to ask.") == nil)
        #expect(OnboardingInterview.parseReply(#"{"reaction": "Hm."}"#) == nil)
        #expect(OnboardingInterview.parseReply(#"{"reaction": "Hm.", "summary": "s", "mates": []}"#) == nil)
    }

    @Test func transcriptLabelsWhoSaidWhat() {
        let lines = [
            OnboardingInterviewLine(speaker: .heyMate, text: "What are you working on?"),
            OnboardingInterviewLine(speaker: .user, text: "A Mac app."),
        ]
        #expect(OnboardingInterview.transcript(lines) == "heymate: What are you working on?\nuser: A Mac app.")
    }

    // MARK: Names

    @Test(arguments: [
        ("My name is Umar", "Umar"),
        ("my name is umar.", "Umar"),
        ("Hi, I'm Sam", "Sam"),
        ("hey heymate, call me Priya", "Priya"),
        ("Alex", "Alex"),
        ("Hello Jordan", "Jordan"),
    ])
    func findsTheName(transcript: String, name: String) {
        #expect(OnboardingInterview.name(fromIntroduction: transcript) == name)
    }

    @Test(arguments: [
        "testing testing one two three",
        "",
        "I'm just trying this out to see what happens",
        "hello",
    ])
    func doesNotInventAName(transcript: String) {
        #expect(OnboardingInterview.name(fromIntroduction: transcript) == nil)
    }
}
