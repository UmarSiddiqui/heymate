//
//  SubscriptionCLIFailureTests.swift
//  HeyMateTests
//
//  A CLI that exits non-zero must fail the turn, not become the answer.
//

import Foundation
import Testing
@testable import HeyMate

struct SubscriptionCLIFailureTests {

    @Test func claudeTextErrorBecomesSignedOutFailure() {
        let error = SubscriptionCLIVisionClient.cliFailure(
            output: "Failed to authenticate: OAuth session expired and could not be refreshed\n",
            exitStatus: 1,
            parseAsCodexJSONL: false
        )
        #expect(error.localizedDescription
            == "Failed to authenticate: OAuth session expired and could not be refreshed")
        #expect(SpokenFailure.classify(error) == .signedOut)
    }

    @Test func codexErrorEventIsPreferredOverRawJSONL() {
        let output = """
        {"type":"thread.started","thread_id":"t"}
        {"type":"error","message":"Not logged in"}
        """
        let error = SubscriptionCLIVisionClient.cliFailure(
            output: output,
            exitStatus: 1,
            parseAsCodexJSONL: true
        )
        #expect(error.localizedDescription == "Not logged in")
        #expect(SpokenFailure.classify(error) == .signedOut)
    }

    @Test func silentExitStillExplainsItself() {
        let error = SubscriptionCLIVisionClient.cliFailure(
            output: "",
            exitStatus: 3,
            parseAsCodexJSONL: false
        )
        #expect(error.localizedDescription == "The engine exited with status 3.")
        #expect(SpokenFailure.classify(error) == .generic)
    }
}
