//
//  ClaudeWarmTalkTests.swift
//  leanring-buddyTests
//
//  The warm Talk child: what goes in on stdin, how its last line is read,
//  and that the pool hands a started child one question and nothing else.
//

import Foundation
import Testing
@testable import HeyMate

struct ClaudeWarmTalkTests {

    // MARK: Arguments

    @Test func warmArgumentsReadTheQuestionFromStdin() {
        let arguments = SubscriptionCLIVisionClient.claudeTalkArguments(
            prompt: "ignored",
            systemPrompt: SubscriptionCLIVisionClient.warmSystemPromptStub,
            model: "sonnet",
            streamsInput: true
        )
        #expect(Array(arguments.prefix(6)) == ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"])
        #expect(!arguments.contains("ignored"))
        #expect(arguments.contains("--safe-mode"))
        #expect(arguments.contains("plan"))
    }

    @Test func oneShotArgumentsAreUnchanged() {
        let arguments = SubscriptionCLIVisionClient.claudeTalkArguments(
            prompt: "what is this",
            systemPrompt: "",
            model: ""
        )
        #expect(Array(arguments.prefix(4)) == ["-p", "what is this", "--output-format", "text"])
    }

    // MARK: Message

    @Test func messageCarriesInstructionsImagesAndQuestionInOrder() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])
        let line = try #require(SubscriptionCLIVisionClient.warmUserMessageJSON(
            systemPrompt: "be brief",
            prompt: "what is on screen?",
            images: [(data: jpeg, label: "main display")]
        ))
        #expect(line.last == 0x0A)

        let json = try #require(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        #expect(json["type"] as? String == "user")
        let message = try #require(json["message"] as? [String: Any])
        #expect(message["role"] as? String == "user")
        let content = try #require(message["content"] as? [[String: Any]])
        #expect(content.count == 4)
        #expect((content[0]["text"] as? String)?.contains("<heymate-instructions>\nbe brief\n</heymate-instructions>") == true)
        #expect(content[1]["text"] as? String == "Screenshot 1 (main display):")
        let source = try #require(content[2]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/jpeg")
        #expect(source["data"] as? String == jpeg.base64EncodedString())
        #expect(content[3]["text"] as? String == "what is on screen?")
    }

    @Test func textOnlyMessageHasNoEmptyBlocks() throws {
        let line = try #require(SubscriptionCLIVisionClient.warmUserMessageJSON(
            systemPrompt: "",
            prompt: "hi",
            images: []
        ))
        let json = try #require(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        let content = try #require((json["message"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["text"] as? String == "hi")
    }

    @Test func imageTypesAreSniffed() {
        #expect(SubscriptionCLIVisionClient.imageMediaType(for: Data([0x89, 0x50, 0x4E, 0x47, 0x0D])) == "image/png")
        #expect(SubscriptionCLIVisionClient.imageMediaType(for: Data([0xFF, 0xD8, 0xFF])) == "image/jpeg")
        #expect(SubscriptionCLIVisionClient.imageMediaType(for: Data("GIF89a".utf8)) == "image/gif")
        #expect(SubscriptionCLIVisionClient.imageMediaType(for: Data("RIFF\0\0\0\0WEBP".utf8)) == "image/webp")
    }

    // MARK: Result line

    @Test func answerIsReadFromTheResultLine() {
        #expect(SubscriptionCLIVisionClient.warmTurnOutcome(fromStdoutLine: #"{"type":"system","subtype":"init"}"#) == nil)
        #expect(SubscriptionCLIVisionClient.warmTurnOutcome(fromStdoutLine: #"{"type":"assistant","message":{}}"#) == nil)
        #expect(SubscriptionCLIVisionClient.warmTurnOutcome(
            fromStdoutLine: #"{"type":"result","subtype":"success","is_error":false,"result":"it's a terminal"}"#
        ) == .answered("it's a terminal"))
    }

    @Test func signedOutResultIsAFailureEvenWhenLabelledSuccess() {
        let line = #"{"type":"result","subtype":"success","is_error":true,"result":"Failed to authenticate: OAuth session expired and could not be refreshed"}"#
        #expect(SubscriptionCLIVisionClient.warmTurnOutcome(fromStdoutLine: line)
            == .failed("Failed to authenticate: OAuth session expired and could not be refreshed"))
    }

    // MARK: Pool

    /// A stand-in CLI: waits for one stdin line, then answers.
    private func fakeCLI() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-claude-\(UUID().uuidString).sh")
        let script = """
        #!/bin/sh
        read line
        echo '{"type":"result","subtype":"success","is_error":false,"result":"warm answer"}'
        cat > /dev/null
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func prewarmedChildIsHandedOutOnceAndAnswers() throws {
        let launch = ClaudeWarmTalkLaunch(
            executableURL: try fakeCLI(),
            arguments: [],
            environmentKeysToRemove: [],
            environmentOverrides: [:]
        )
        let pool = ClaudeWarmTalkPool()
        pool.prewarm(launch)

        let child = try #require(pool.takeChild(for: launch))
        defer { child.discard() }
        #expect(child.isRunning)

        try child.standardInput.write(contentsOf: Data("{}\n".utf8))
        let line = String(data: child.standardOutput.availableData, encoding: .utf8) ?? ""
        #expect(line.contains("warm answer"))

        // Taking again starts a new child rather than reusing the used one.
        let second = try #require(pool.takeChild(for: launch))
        defer { second.discard() }
        #expect(second !== child)
    }

    @Test func mismatchedLaunchIsNotReused() throws {
        let executable = try fakeCLI()
        let first = ClaudeWarmTalkLaunch(executableURL: executable, arguments: ["--model", "a"], environmentKeysToRemove: [], environmentOverrides: [:])
        let second = ClaudeWarmTalkLaunch(executableURL: executable, arguments: ["--model", "b"], environmentKeysToRemove: [], environmentOverrides: [:])
        let pool = ClaudeWarmTalkPool()
        pool.prewarm(first)
        let child = try #require(pool.takeChild(for: second))
        defer { child.discard() }
        #expect(child.launch == second)
    }
}
