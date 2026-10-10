//
//  LocalKernelTests.swift
//  HeyMateTests
//

import Foundation
import Testing
@testable import HeyMate

struct LocalKernelTests {

    @Test func appleScriptStringLiteralEscapesQuotesAndBackslashes() {
        #expect(AppleScript.literal(#"say "hi""#) == #""say \"hi\"""#)
        #expect(AppleScript.literal(#"a\b"#) == #""a\\b""#)
    }

    @Test func osascriptRunnerReturnsExpressionResult() {
        let result = AppleScript.run("1 + 1")
        #expect(result.succeeded)
        #expect(result.output == "2")
    }

    @Test func requestCompletionStateIsRaceSafe() {
        let state = HeyMateRequestCompletionState()
        #expect(!state.didComplete)
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            state.didComplete = true
        }
        #expect(state.didComplete)
    }

    @Test func outputVolumeScalarClamps() {
        #expect(SystemVolume.clampedScalar(-1) == 0)
        #expect(SystemVolume.clampedScalar(0.4) == 0.4)
        #expect(SystemVolume.clampedScalar(2) == 1)
    }

    @Test func localVoiceActionDoesNotTreatOpenThisAsLaunch() {
        #expect(LocalVoiceAction.parse("open this") == nil)
        #expect(LocalVoiceAction.parse("open Safari") == .openApp(name: "safari"))
        #expect(LocalVoiceAction.parse("mute") == .mute)
        #expect(LocalVoiceAction.parse("make it louder") == .volumeUp)
    }
}
