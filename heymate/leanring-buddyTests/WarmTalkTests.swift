//
//  WarmTalkTests.swift
//  leanring-buddyTests
//
//  The warm Talk child: what goes in on stdin, how its last line is read,
//  and that the pool hands a started child one question and nothing else.
//

import Foundation
import Testing
@testable import HeyMate

struct WarmTalkTests {

    // MARK: Arguments

    @Test func warmArgumentsReadTheQuestionFromStdin() {
        let arguments = SubscriptionCLIVisionClient.claudeTalkArguments(
            prompt: "ignored",
            systemPrompt: SubscriptionCLIVisionClient.warmSystemPromptStub,
            model: "sonnet",
            streamsInput: true
        )
        #expect(Array(arguments.prefix(7)) == ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages"])
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
        let launch = WarmTalkLaunch(
            executableURL: try fakeCLI(),
            arguments: [],
            environmentKeysToRemove: [],
            environmentOverrides: [:]
        )
        let pool = WarmTalkPool()
        pool.prewarm(launch)

        let child = try #require(pool.takeChild(for: launch)?.child)
        defer { child.discard() }
        #expect(child.isRunning)

        try child.write(Data("{}\n".utf8))
        let line = child.readLine() ?? ""
        #expect(line.contains("warm answer"))

        // Taking again starts a new child rather than reusing the used one.
        let second = try #require(pool.takeChild(for: launch)?.child)
        defer { second.discard() }
        #expect(second !== child)
    }

    // MARK: Conversation sessions

    @Test func answeredChildContinuesItsOwnChatOnly() throws {
        let launch = WarmTalkLaunch(executableURL: try fakeCLI(), arguments: [], environmentKeysToRemove: [], environmentOverrides: [:])
        let pool = WarmTalkPool()
        let (child, isContinuing) = try #require(pool.takeChild(for: launch, conversationKey: "chat-a", position: 1))
        #expect(!isContinuing)
        child.conversationKey = "chat-a"
        child.nextConversationPosition = 3
        child.completedTurns = 1
        pool.checkIn(child)

        // Same chat, the expected position: the same child, continuing.
        let next = try #require(pool.takeChild(for: launch, conversationKey: "chat-a", position: 3))
        #expect(next.child === child)
        #expect(next.isContinuing)
        pool.checkIn(next.child)

        // A different chat never inherits it.
        let other = try #require(pool.takeChild(for: launch, conversationKey: "chat-b", position: 1))
        defer { other.child.discard() }
        #expect(other.child !== child)
        #expect(!other.isContinuing)
        #expect(!child.isRunning)
    }

    @Test func editedChatDoesNotContinue() throws {
        let launch = WarmTalkLaunch(executableURL: try fakeCLI(), arguments: [], environmentKeysToRemove: [], environmentOverrides: [:])
        let pool = WarmTalkPool()
        let child = try #require(pool.takeChild(for: launch, conversationKey: "chat", position: 1)?.child)
        child.conversationKey = "chat"
        child.nextConversationPosition = 3
        pool.checkIn(child)
        // A message was deleted: the chat is at 2, not the 3 the child expects.
        let next = try #require(pool.takeChild(for: launch, conversationKey: "chat", position: 2))
        defer { next.child.discard() }
        #expect(!next.isContinuing)
        #expect(next.child !== child)
    }

    @Test func oneOffQuestionLeavesTheChatSessionAlone() throws {
        let launch = WarmTalkLaunch(executableURL: try fakeCLI(), arguments: [], environmentKeysToRemove: [], environmentOverrides: [:])
        let pool = WarmTalkPool()
        let child = try #require(pool.takeChild(for: launch, conversationKey: "chat", position: 1)?.child)
        child.conversationKey = "chat"
        child.nextConversationPosition = 3
        pool.checkIn(child)

        let oneOff = try #require(pool.takeChild(for: launch))
        oneOff.child.discard()
        #expect(oneOff.child !== child)

        let resumed = try #require(pool.takeChild(for: launch, conversationKey: "chat", position: 3))
        defer { resumed.child.discard() }
        #expect(resumed.child === child)
        #expect(resumed.isContinuing)
    }

    @Test func childPastItsScreenLimitIsRetired() throws {
        let launch = WarmTalkLaunch(executableURL: try fakeCLI(), arguments: [], environmentKeysToRemove: [], environmentOverrides: [:])
        let pool = WarmTalkPool()
        let child = try #require(pool.takeChild(for: launch, conversationKey: "chat", position: 1)?.child)
        child.conversationKey = "chat"
        child.nextConversationPosition = 3
        child.imageTurns = WarmTalkPool.maximumImageTurns
        pool.checkIn(child)
        #expect(!child.isRunning)
        let next = try #require(pool.takeChild(for: launch, conversationKey: "chat", position: 3))
        defer { next.child.discard() }
        #expect(!next.isContinuing)
    }

    @Test func claudeTextDeltasAreReadFromPartialMessages() {
        let delta = #"{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}}"#
        #expect(SubscriptionCLIVisionClient.warmTextDelta(fromStdoutLine: delta) == "Hel")
        let subagent = #"{"type":"stream_event","parent_tool_use_id":"toolu_1","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}}}"#
        #expect(SubscriptionCLIVisionClient.warmTextDelta(fromStdoutLine: subagent) == nil)
        #expect(SubscriptionCLIVisionClient.warmTextDelta(fromStdoutLine: #"{"type":"result","result":"text_delta"}"#) == nil)
    }

    @Test func codexTextDeltasAreRead() {
        let line = #"{"method":"item/agentMessage/delta","params":{"threadId":"t","itemId":"i","delta":"lo"}}"#
        #expect(CodexAppServerProtocol.textDelta(fromLine: line) == "lo")
        #expect(CodexAppServerProtocol.textDelta(fromLine: #"{"method":"turn/completed","params":{}}"#) == nil)
    }

    @Test func codexTurnIDsAdvance() throws {
        let line = try #require(CodexAppServerProtocol.turnStartJSON(threadID: "t", systemPrompt: "", prompt: "hi", imagePaths: [], requestID: 7))
        let json = try #require(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        #expect(json["id"] as? Int == 7)
        #expect(CodexAppServerProtocol.turnEvent(fromLine: #"{"id":7,"error":{"message":"no"}}"#, requestID: 7) == .failed("no"))
        #expect(CodexAppServerProtocol.turnEvent(fromLine: #"{"id":3,"error":{"message":"no"}}"#, requestID: 7) == nil)
    }

    @Test func unchangedInstructionsAreNotPastedAgain() {
        #expect(SubscriptionCLIVisionClient.instructionsToSend("be brief", previous: nil) == "be brief")
        #expect(SubscriptionCLIVisionClient.instructionsToSend("be brief", previous: "be brief") != "be brief")
        #expect(SubscriptionCLIVisionClient.instructionsToSend("be kind", previous: "be brief") == "be kind")
    }

    @Test func mismatchedLaunchIsNotReused() throws {
        let executable = try fakeCLI()
        let first = WarmTalkLaunch(executableURL: executable, arguments: ["--model", "a"], environmentKeysToRemove: [], environmentOverrides: [:])
        let second = WarmTalkLaunch(executableURL: executable, arguments: ["--model", "b"], environmentKeysToRemove: [], environmentOverrides: [:])
        let pool = WarmTalkPool()
        pool.prewarm(first)
        let child = try #require(pool.takeChild(for: second)?.child)
        defer { child.discard() }
        #expect(child.launch == second)
    }

    // MARK: Codex app-server

    @Test func codexIsolationDisablesUserSetup() {
        let arguments = SubscriptionCLIVisionClient.codexAppServerArguments(
            userMCPServerNames: ["playwright", "\"my server\"", "heymate"]
        )
        #expect(arguments.first == "app-server")
        for feature in ["hooks", "plugins", "apps", "memories"] {
            #expect(arguments.contains(feature))
        }
        #expect(arguments.contains("notify=[]"))
        #expect(arguments.contains("mcp_servers.playwright.enabled=false"))
        #expect(arguments.contains("mcp_servers.\"my server\".enabled=false"))
        // HeyMate's own server is added back for connected apps, never disabled.
        #expect(!arguments.contains("mcp_servers.heymate.enabled=false"))
    }

    @Test func codexServerNamesComeFromTopLevelTablesOnly() {
        let toml = """
        model = "gpt-5"
        [mcp_servers.playwright]
        command = "npx"
        [mcp_servers.node_repl]
        [mcp_servers.node_repl.env]
        FOO = "1"
        [mcp_servers."quoted.name"]
        [plugins."figma@openai-curated"]
        """
        #expect(SubscriptionCLIVisionClient.codexUserMCPServerNames(configTOML: toml)
            == ["playwright", "node_repl", "\"quoted.name\""])
    }

    @Test func codexThreadStartIsReadOnlyEphemeralAndSkipsTheFastDefault() throws {
        let json = SubscriptionCLIVisionClient.codexThreadStartParamsJSON(model: "gpt-6.1-sol", effort: "medium")
        let params = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(params["sandbox"] as? String == "read-only")
        #expect(params["approvalPolicy"] as? String == "never")
        #expect(params["ephemeral"] as? Bool == true)
        #expect(params["model"] as? String == "gpt-6.1-sol")
        #expect((params["config"] as? [String: Any])?["model_reasoning_effort"] as? String == "medium")

        let fastDefault = SubscriptionCLIVisionClient.codexThreadStartParamsJSON(
            model: SubscriptionCLIVisionClient.codexFastTalkModelIdentifier,
            effort: ""
        )
        #expect(!fastDefault.contains("model"))
    }

    @Test func codexTurnCarriesInstructionsImagesAndQuestion() throws {
        let data = try #require(CodexAppServerProtocol.turnStartJSON(
            threadID: "t1",
            systemPrompt: "be brief",
            prompt: "what is this?",
            imagePaths: [(path: "/tmp/screen-0.jpg", label: "main")]
        ))
        let json = try #require(try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any])
        #expect(json["method"] as? String == "turn/start")
        #expect(json["id"] as? Int == 3)
        let params = try #require(json["params"] as? [String: Any])
        #expect(params["threadId"] as? String == "t1")
        let input = try #require(params["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String } == ["text", "text", "localImage", "text"])
        #expect(input[2]["path"] as? String == "/tmp/screen-0.jpg")
        #expect(input[3]["text"] as? String == "what is this?")
    }

    @Test func codexAnswerIsTheFinalAgentMessage() {
        #expect(CodexAppServerProtocol.turnEvent(fromLine: #"{"method":"turn/started","params":{}}"#) == nil)
        #expect(CodexAppServerProtocol.turnEvent(
            fromLine: #"{"method":"item/completed","params":{"item":{"type":"userMessage","content":[]}}}"#
        ) == nil)
        #expect(CodexAppServerProtocol.turnEvent(
            fromLine: #"{"method":"item/completed","params":{"item":{"type":"agentMessage","phase":"final_answer","text":"a wallpaper"}}}"#
        ) == .answered("a wallpaper"))
    }

    @Test func codexErrorsSurfaceTheReadableMessage() {
        let line = #"{"method":"error","params":{"error":{"message":"{\"type\":\"error\",\"error\":{\"message\":\"The model is not supported.\"}}"},"willRetry":false}}"#
        #expect(CodexAppServerProtocol.turnEvent(fromLine: line) == .failed("The model is not supported."))
        let retrying = #"{"method":"error","params":{"error":{"message":"busy"},"willRetry":true}}"#
        #expect(CodexAppServerProtocol.turnEvent(fromLine: retrying) == nil)
        let failedTurn = #"{"method":"turn/completed","params":{"turn":{"status":"failed"}}}"#
        #expect(CodexAppServerProtocol.turnEvent(fromLine: failedTurn) == .failed("Codex stopped before it answered."))
    }

    @Test func codexChildIsHandshakenDuringWarmUp() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-codex-\(UUID().uuidString).sh")
        let script = """
        #!/bin/sh
        read init
        echo '{"method":"account/updated","params":{}}'
        echo '{"id":1,"result":{}}'
        read start
        echo '{"id":2,"result":{"thread":{"id":"thread-42"}}}'
        read turn
        echo '{"method":"item/completed","params":{"item":{"type":"agentMessage","phase":"final_answer","text":"warm codex"}}}'
        cat > /dev/null
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        let launch = WarmTalkLaunch(
            executableURL: url,
            arguments: [],
            environmentKeysToRemove: [],
            environmentOverrides: [:],
            codexThreadStartParamsJSON: "{}"
        )
        let pool = WarmTalkPool()
        pool.prewarm(launch)
        let child = try #require(pool.takeChild(for: launch)?.child)
        defer { child.discard() }
        #expect(child.codexThreadID == "thread-42")

        let turn = try #require(CodexAppServerProtocol.turnStartJSON(
            threadID: "thread-42", systemPrompt: "", prompt: "hi", imagePaths: []
        ))
        try child.write(turn)
        let line = try #require(child.readLine())
        #expect(CodexAppServerProtocol.turnEvent(fromLine: line) == .answered("warm codex"))
    }
}
