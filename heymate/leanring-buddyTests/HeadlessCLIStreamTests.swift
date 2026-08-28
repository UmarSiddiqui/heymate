//
//  HeadlessCLIStreamTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct HeadlessCLILineAccumulatorTests {

    private func chunk(_ text: String) -> Data { Data(text.utf8) }

    @Test func completeLinesAreDeliveredImmediately() {
        let accumulator = HeadlessCLILineAccumulator()
        let lines = accumulator.completeLines(from: chunk("{\"a\":1}\n{\"b\":2}\n"))
        #expect(lines == ["{\"a\":1}", "{\"b\":2}"])
    }

    /// The bug this class exists for: a JSON line split across two pipe reads
    /// used to arrive as two invalid fragments, and every agent event inside it
    /// was dropped.
    @Test func lineSplitAcrossReadsIsRejoinedNotDropped() {
        let accumulator = HeadlessCLILineAccumulator()

        let firstRead = accumulator.completeLines(from: chunk("{\"type\":\"tool_use\",\"na"))
        #expect(firstRead.isEmpty)

        let secondRead = accumulator.completeLines(from: chunk("me\":\"write\"}\n"))
        #expect(secondRead == ["{\"type\":\"tool_use\",\"name\":\"write\"}"])
    }

    @Test func partialLineIsHeldUntilItsNewlineArrives() {
        let accumulator = HeadlessCLILineAccumulator()
        #expect(accumulator.completeLines(from: chunk("first\nsecond-half")) == ["first"])
        #expect(accumulator.completeLines(from: chunk("-of-second\nthird\n")) == ["second-half-of-second", "third"])
    }

    /// A multi-byte character straddling a chunk boundary used to make the
    /// whole chunk fail to decode, not just the one character.
    @Test func multiByteCharacterSplitAcrossReadsSurvives() {
        let accumulator = HeadlessCLILineAccumulator()
        let emojiBytes = Array("✅".utf8)

        #expect(accumulator.completeLines(from: Data([UInt8(ascii: "x")] + emojiBytes.prefix(1))).isEmpty)
        let completed = accumulator.completeLines(
            from: Data(emojiBytes.dropFirst() + [UInt8(ascii: "\n")])
        )
        #expect(completed == ["x✅"])
    }

    @Test func flushDeliversAFinalLineWithoutATrailingNewline() {
        let accumulator = HeadlessCLILineAccumulator()
        #expect(accumulator.completeLines(from: chunk("done")).isEmpty)
        #expect(accumulator.flushRemainder() == ["done"])
        #expect(accumulator.flushRemainder().isEmpty)
    }

    @Test func blankLinesAreNotDelivered() {
        let accumulator = HeadlessCLILineAccumulator()
        #expect(accumulator.completeLines(from: chunk("\n\nreal\n\n")) == ["real"])
    }

    @Test func carriageReturnsAreTrimmed() {
        let accumulator = HeadlessCLILineAccumulator()
        #expect(accumulator.completeLines(from: chunk("value\r\n")) == ["value"])
    }
}

struct HeadlessCLIStandardErrorTailTests {

    @Test func recentLinesReturnsTheNewestLinesOldestFirst() {
        let tail = HeadlessCLIStandardErrorTail()
        tail.append(Data("one\ntwo\nthree\nfour\n".utf8))
        #expect(tail.recentLines(limit: 2) == ["three", "four"])
    }

    @Test func emptyStandardErrorProducesNoLines() {
        let tail = HeadlessCLIStandardErrorTail()
        #expect(tail.recentLines(limit: 6).isEmpty)
    }

    @Test func retainedBytesAreBounded() {
        let tail = HeadlessCLIStandardErrorTail()
        for index in 0..<4000 {
            tail.append(Data("line \(index)\n".utf8))
        }
        let lines = tail.recentLines(limit: 3)
        #expect(lines.count == 3)
        #expect(lines.last == "line 3999")
    }
}

struct HeadlessExecutorPolicyTests {

    /// Claude Code runs on the subscription sign-in, so a provider key leaking
    /// in from the secrets file would silently move billing to the API.
    @Test func claudeCodeStripsProviderKeys() {
        #expect(HeadlessExecutor.claudeCode.usesSubscriptionSignIn)
        #expect(HeadlessExecutor.claudeCode.environmentKeysToRemove.contains("ANTHROPIC_API_KEY"))
        #expect(HeadlessExecutor.claudeCode.environmentKeysToRemove.contains("ANTHROPIC_BASE_URL"))
    }

    @Test func codexStripsProviderKeys() {
        #expect(HeadlessExecutor.codex.usesSubscriptionSignIn)
        #expect(HeadlessExecutor.codex.environmentKeysToRemove.contains("OPENAI_API_KEY"))
        #expect(HeadlessExecutor.codex.executableName == "codex")
    }

    /// Bringing your own provider keys is the entire point of OpenCode.
    @Test func openCodeStripsNothing() {
        #expect(HeadlessExecutor.openCode.usesSubscriptionSignIn == false)
        #expect(HeadlessExecutor.openCode.environmentKeysToRemove.isEmpty)
    }

    @Test func strippedKeysAreAbsentFromTheChildEnvironment() {
        let environment = HeadlessChildEnvironment.build(
            stripping: ["ANTHROPIC_API_KEY"],
            overrides: ["HEYMATE_BRIDGE_URL": "http://127.0.0.1:18732"]
        )
        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["HEYMATE_BRIDGE_URL"] == "http://127.0.0.1:18732")
        #expect(environment["TERM"] == "dumb")
        #expect(environment["PATH"]?.isEmpty == false)
    }
}

struct HeadlessCLILaunchSpecTests {

    private let workspaceURL = URL(fileURLWithPath: "/tmp/heymate-spec-test", isDirectory: true)

    private func openCodeSpec(model: String?) -> HeadlessCLILaunchSpec {
        HeadlessCLIAdapterFactory.adapter(for: .openCode, openCodeModelIdentifier: model).launchSpec(
            workspaceURL: workspaceURL,
            leg: .plan(prompt: "build a landing page"),
            origin: .sandbox,
            title: "build a landing page",
            sessionIdentifier: ""
        )
    }

    /// Without an explicit model, `opencode run` falls back to its own default
    /// rather than the model showing in Settings.
    @Test func openCodePassesTheSelectedModel() {
        let arguments = openCodeSpec(model: "anthropic/claude-sonnet-4-6").arguments
        #expect(arguments.contains("--pure"))
        #expect(arguments.contains("--model"))
        #expect(arguments.contains("anthropic/claude-sonnet-4-6"))
    }

    @Test func openCodeOmitsTheModelFlagWhenNoneIsSelected() {
        #expect(openCodeSpec(model: nil).arguments.contains("--model") == false)
    }

    @Test func claudeCodeCarriesItsStrippedKeysOnTheSpec() {
        let spec = HeadlessCLIAdapterFactory.adapter(
            for: .claudeCode,
            claudeModelIdentifier: "sonnet"
        ).launchSpec(
            workspaceURL: workspaceURL,
            leg: .plan(prompt: "build a landing page"),
            origin: .sandbox,
            title: "build a landing page",
            sessionIdentifier: "4662b1f8-8da1-4865-a3a2-ecd91d20cbb0"
        )
        #expect(spec.environmentKeysToRemove.contains("ANTHROPIC_API_KEY"))
        #expect(spec.arguments.contains("stream-json"))
        #expect(spec.arguments.contains("--model"))
        #expect(spec.arguments.contains("sonnet"))
    }
}

struct HeadlessExecutorReadinessTests {

    @Test func onlyDefiniteNegativesBlockALaunch() {
        #expect(HeadlessExecutorReadiness.ready(detail: "Claude Pro").allowsLaunch)
        #expect(HeadlessExecutorReadiness.indeterminate().allowsLaunch)
        #expect(
            HeadlessExecutorReadiness(state: .usingAPIKey, detail: "", remedy: "").allowsLaunch
        )
        #expect(
            HeadlessExecutorReadiness(state: .notSignedIn, detail: "", remedy: "").allowsLaunch == false
        )
        #expect(
            HeadlessExecutorReadiness(state: .notInstalled, detail: "", remedy: "").allowsLaunch == false
        )
    }
}
