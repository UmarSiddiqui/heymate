//
//  MemoryExtractorTests.swift
//  HeyMateTests
//
//  Parsing and dedupe for Talk memory proposals. Every extract() test
//  stubs the request, so the suite never reaches the network.
//

import Foundation
import Testing
@testable import HeyMate

struct MemoryExtractorParsingTests {

    @Test func aPrefilledTailWithNestedObjectsStillReadsItems() {
        let reply = #""items":[{"kind":"preference","text":"Prefers dark mode"},{"kind":"project_fact","text":"Northwind is the billing rewrite"}]}"#
        #expect(
            MemoryExtractor.items(fromClassifierReply: reply)?.map(\.text)
                == ["Prefers dark mode", "Northwind is the billing rewrite"]
        )
    }

    @Test func aStubbedMessagesPayloadParses() throws {
        let url = try #require(URL(string: "https://classifier.test/messages"))
        let (data, response) = try messagesResponse(
            text: #""items":[{"kind":"preference","text":"Prefers dark mode"},{"kind":"project_fact","text":"Northwind is the billing rewrite"}]}"#,
            url: url
        )
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        let text = try #require(VoiceIntentClassifier.replyText(fromResponseData: data))
        #expect(
            MemoryExtractor.items(fromClassifierReply: text)?.map(\.text)
                == ["Prefers dark mode", "Northwind is the billing rewrite"]
        )
    }

    @Test func aPrefilledReplyIsReassembled() {
        let reply = #""items":[{"kind":"preference","text":"Prefers dark mode"}]}"#
        #expect(
            MemoryExtractor.items(fromPrefilledReply: reply)
                == [ExtractedMemory(kind: .preference, text: "Prefers dark mode")]
        )
    }

    @Test func aFullObjectStillParsesWhenTheBraceWasRepeated() {
        let reply = #"{"items":[{"kind":"projectFact","text":"Northwind lives in ~/Projects/Northwind"}]}"#
        #expect(
            MemoryExtractor.items(fromClassifierReply: reply)?.map(\.text)
                == ["Northwind lives in ~/Projects/Northwind"]
        )
    }

    @Test func anEmptyItemListProposesNothing() {
        #expect(MemoryExtractor.items(fromPrefilledReply: #""items":[]}"#) == [])
    }

    @Test func aProseReplyProposesNothing() {
        #expect(MemoryExtractor.items(fromClassifierReply: "Sure, I'll remember that.") == nil)
    }

    @Test func aSessionSummaryIsNotDurableMemory() {
        let reply = #""items":[{"kind":"sessionSummary","text":"Talked about lunch"},{"kind":"preference","text":"Wants one sentence replies"}]}"#
        #expect(
            MemoryExtractor.items(fromPrefilledReply: reply)
                == [ExtractedMemory(kind: .preference, text: "Wants one sentence replies")]
        )
    }

    @Test func credentialsAreNotStored() {
        let reply = #""items":[{"kind":"preference","text":"password is hunter2"},{"kind":"projectFact","text":"api key is sk-ant-api03-secret"},{"kind":"preference","text":"I prefer a password manager"},{"kind":"projectFact","text":"Northwind ships in May"}]}"#
        #expect(
            MemoryExtractor.items(fromPrefilledReply: reply)?.map(\.text)
                == ["I prefer a password manager", "Northwind ships in May"]
        )
    }

    @Test func theAssistantTurnIsPrefilledAndTheCallStaysSmall() {
        let exchange = MemoryExtractor.exchangeText(user: "I prefer dark mode", assistant: "Noted.")
        let body = MemoryExtractor.requestBody(exchange: exchange, model: MemoryExtractor.classifierModel(configured: "claude-sonnet-4-6"))
        let messages = body["messages"] as? [[String: String]]
        #expect(JSONSerialization.isValidJSONObject(body))
        #expect(messages?.last?["content"] == "{")
        #expect((body["max_tokens"] as? Int) == 200)
        #expect((body["model"] as? String) == VoiceIntentClassifier.classifierModel)
        #expect(MemoryExtractor.classifierModel(configured: "local-llama") == "local-llama")
    }

    @Test func thePromptRefusesToAnswerTheUser() {
        #expect(MemoryExtractor.systemPrompt.contains("You are not the assistant"))
        #expect(MemoryExtractor.systemPrompt.contains("Never record passwords"))
        #expect(MemoryExtractor.systemPrompt.contains("empty items array"))
    }
}

@MainActor
struct MemoryExtractorRequestTests {

    @Test func aPrefilledClassifierReplyBecomesOwnedMemory() async {
        let owner = MemoryContext.heyMateTalkOwnerID
        let extractor = makeExtractor()
        var posted = false
        extractor.performRequest = { request in
            posted = true
            #expect(request.timeoutInterval == MemoryExtractor.timeout)
            #expect(request.url?.host == "classifier.test")
            return try messagesResponse(
                text: prefilledItems(
                    #"{"kind":"preference","text":"Prefers dark mode"},{"kind":"project_fact","text":"Northwind is the billing rewrite"}"#
                ),
                url: try #require(request.url)
            )
        }

        let items = await extractor.extract(
            user: "I prefer dark mode. Northwind is the billing rewrite.",
            assistant: "I'll keep that in mind.",
            existing: [],
            ownerMateID: owner
        )

        #expect(posted)
        #expect(items.map(\.kind) == [.preference, .projectFact])
        #expect(items.map(\.text) == ["Prefers dark mode", "Northwind is the billing rewrite"])
        #expect(items.allSatisfy { $0.mateID == owner })
    }

    @Test func existingMemoriesAreDeduped() async {
        let existing = MemoryItem(
            id: UUID(),
            kind: .preference,
            text: "Prefers dark mode",
            createdAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let extractor = makeExtractor()
        extractor.performRequest = { request in
            try messagesResponse(
                text: prefilledItems(
                    #"{"kind":"preference","text":"prefers  dark mode"},{"kind":"projectFact","text":"Northwind ships in May"}"#
                ),
                url: try #require(request.url)
            )
        }

        let items = await extractor.extract(
            user: "Remember I prefer dark mode, and Northwind ships in May.",
            assistant: "Got it.",
            existing: [existing],
            ownerMateID: nil
        )

        #expect(items.map(\.text) == ["Northwind ships in May"])
        #expect(items.allSatisfy { $0.mateID == nil })
    }

    @Test func aTimeoutOrFailureProposesNothing() async {
        let extractor = makeExtractor()
        extractor.performRequest = { _ in throw URLError(.timedOut) }
        let timedOut = await extractor.extract(
            user: "I prefer dark mode",
            assistant: "Okay.",
            existing: [],
            ownerMateID: nil
        )
        #expect(timedOut.isEmpty)

        extractor.performRequest = { request in
            try messagesResponse(text: #""items":[{"kind":"preference","text":"Prefers dark mode"}]"#, url: try #require(request.url), status: 500)
        }
        let failed = await extractor.extract(
            user: "I prefer dark mode",
            assistant: "Okay.",
            existing: [],
            ownerMateID: nil
        )
        #expect(failed.isEmpty)
    }

    @Test func anUnusableCustomAPIDoesNotCallTheNetwork() async {
        let extractor = MemoryExtractor(endpoint: "https://classifier.test/messages", apiKey: "test-key")
        extractor.customAPIUsableOverride = false
        var posted = false
        extractor.performRequest = { _ in
            posted = true
            throw URLError(.badServerResponse)
        }
        extractor.performOnDeviceExtraction = { _ in nil }

        let items = await extractor.extract(
            user: "I prefer dark mode",
            assistant: "Okay.",
            existing: [],
            ownerMateID: MemoryContext.heyMateTalkOwnerID
        )
        #expect(posted == false)
        #expect(items.isEmpty)
    }

    @Test func onDeviceReplyIsUsedOnlyWhenTheCustomAPIIsUnusable() async {
        let extractor = MemoryExtractor(endpoint: "https://api.anthropic.com/v1/messages")
        extractor.customAPIUsableOverride = false
        extractor.performRequest = { _ in
            Issue.record("custom API was called")
            throw URLError(.notConnectedToInternet)
        }
        extractor.performOnDeviceExtraction = { _ in
            #"{"items":[{"kind":"preference","text":"Wants replies in one sentence"}]}"#
        }

        let items = await extractor.extract(
            user: "Please answer in one sentence.",
            assistant: "I will.",
            existing: [],
            ownerMateID: MemoryContext.heyMateTalkOwnerID
        )
        #expect(items.map(\.text) == ["Wants replies in one sentence"])
    }

    @Test func aBlankExchangeDoesNotCallOut() async {
        let extractor = makeExtractor()
        var posted = false
        extractor.performRequest = { _ in
            posted = true
            throw URLError(.unknown)
        }
        let items = await extractor.extract(user: "  \n", assistant: " ", existing: [], ownerMateID: nil)
        #expect(items.isEmpty)
        #expect(posted == false)
    }

    private func makeExtractor() -> MemoryExtractor {
        let extractor = MemoryExtractor(endpoint: "https://classifier.test/messages", apiKey: "test-key")
        extractor.customAPIUsableOverride = true
        extractor.performOnDeviceExtraction = { _ in nil }
        extractor.performRequest = { _ in throw URLError(.notConnectedToInternet) }
        return extractor
    }
}

private func prefilledItems(_ itemsJSON: String) -> String {
    "\"items\":[" + itemsJSON + "]}"
}

private func messagesResponse(text: String, url: URL, status: Int = 200) throws -> (Data, URLResponse) {
    let payload: [String: Any] = ["content": [["type": "text", "text": text]]]
    let data = try JSONSerialization.data(withJSONObject: payload)
    let response = try #require(
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
    )
    return (data, response)
}
