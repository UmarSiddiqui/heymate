//
//  VoiceIntentClassifierTests.swift
//  leanring-buddyTests
//
//  The replies below are verbatim output from the real model, including the
//  code fences and the trailing prose it sometimes adds. Parsing them is the
//  whole job — a classifier that cannot read its own answer routes nothing.
//

import Foundation
import Testing
@testable import HeyMate

struct VoiceIntentDecisionParsingTests {

    @Test func fencedJSONIsRead() {
        let reply = """
        ```json
        {"route":"agent","task":"clean up downloads folder"}
        ```
        """
        #expect(
            VoiceIntentClassifier.decision(fromModelReply: reply)
                == VoiceIntentDecision(route: .agent, task: "clean up downloads folder")
        )
    }

    /// Observed: the model answers correctly and then keeps talking.
    @Test func trailingProseAfterTheJSONIsIgnored() {
        let reply = """
        ```json
        {"route":"talk","task":""}
        ```

        No error shown. Paste error message or screenshot.
        """
        #expect(VoiceIntentClassifier.decision(fromModelReply: reply) == .talk)
    }

    /// The request prefills the assistant turn with `{`, so what comes back is
    /// the rest of the object.
    @Test func aPrefilledReplyIsReassembled() {
        let reply = #""route":"agent","task":"organise desktop by file type"}"#
        #expect(
            VoiceIntentClassifier.decision(fromPrefilledReply: reply)
                == VoiceIntentDecision(route: .agent, task: "organise desktop by file type")
        )
    }

    /// This is what the model used to return for "draft the reply to Sam" —
    /// it answered instead of routing. Nil sends the caller to the offline
    /// fallback, which is right; guessing a route would not be.
    @Test func aProseOnlyReplyDecidesNothing() {
        let reply = "I don't have the context of Sam's message. Share the email you want to reply to."
        #expect(VoiceIntentClassifier.decision(fromModelReply: reply) == nil)
    }

    /// Spawning an agent with an empty prompt fails the job; falling back to
    /// Talk does not.
    @Test func anAgentRouteWithNoTaskIsRefused() {
        #expect(VoiceIntentClassifier.decision(fromModelReply: #"{"route":"agent","task":""}"#) == nil)
    }

    @Test func anUnknownRouteIsRefused() {
        #expect(VoiceIntentClassifier.decision(fromModelReply: #"{"route":"compute","task":"x"}"#) == nil)
    }

    @Test func onlyTheAgentRouteCarriesATask() {
        #expect(VoiceIntentClassifier.decision(fromModelReply: #"{"route":"talk","task":"stray"}"#) == .talk)
    }

    /// A brace inside the task must not close the object early.
    @Test func bracesInsideStringsDoNotTruncate() {
        let reply = #"{"route":"agent","task":"fix the {mustache} template"}"#
        #expect(
            VoiceIntentClassifier.decision(fromModelReply: reply)
                == VoiceIntentDecision(route: .agent, task: "fix the {mustache} template")
        )
    }

    @Test func replyTextIsPulledOutOfTheMessagesResponse() {
        let responseJSON = #"{"content":[{"type":"text","text":"{\"route\":\"talk\",\"task\":\"\"}"}]}"#
        let text = VoiceIntentClassifier.replyText(fromResponseData: Data(responseJSON.utf8))
        #expect(text == #"{"route":"talk","task":""}"#)
    }
}

struct VoiceIntentRequestTests {

    /// The prefill is what stops the model prefacing its JSON with prose.
    @Test func theAssistantTurnIsPrefilledWithAnOpeningBrace() {
        let body = VoiceIntentClassifier.requestBody(for: "clean up my downloads folder")
        let messages = body["messages"] as? [[String: String]]
        #expect(messages?.count == 2)
        #expect(messages?[0]["role"] == "user")
        #expect(messages?[1]["role"] == "assistant")
        #expect(messages?[1]["content"] == "{")
    }

    /// This runs while the user waits, so it must stay on the small model.
    @Test func theRequestStaysSmall() {
        let body = VoiceIntentClassifier.requestBody(for: "x")
        #expect((body["model"] as? String)?.contains("haiku") == true)
        #expect((body["max_tokens"] as? Int) == 200)
    }

    /// Without this the model answers the sentence rather than routing it —
    /// observed on every under-specified phrasing.
    @Test func thePromptForbidsAnsweringAndAskingForClarification() {
        #expect(VoiceIntentClassifier.systemPrompt.contains("You are not the"))
        #expect(VoiceIntentClassifier.systemPrompt.contains("never ask for clarification"))
    }

    @Test func cacheKeysFoldCaseAndPunctuation() {
        #expect(
            VoiceIntentClassifier.cacheKey(for: "Clean up my Downloads folder!")
                == VoiceIntentClassifier.cacheKey(for: "clean up my downloads folder")
        )
    }
}
