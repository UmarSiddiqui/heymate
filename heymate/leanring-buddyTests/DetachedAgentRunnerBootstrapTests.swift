//
//  DetachedAgentRunnerBootstrapTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct DetachedAgentRunnerBootstrapTests {
    @Test func invocationAcceptsOnlyFixedBootstrapDescriptor() throws {
        let runID = UUID()
        let attemptID = UUID()
        let valid = try #require(
            DetachedAgentRunnerInvocation(
                arguments: [
                    "/Applications/HeyMate.app/Contents/MacOS/HeyMate",
                    DetachedAgentRunnerInvocation.commandLineFlag,
                    runID.uuidString,
                    attemptID.uuidString,
                    "3"
                ]
            )
        )

        #expect(valid.runID == runID)
        #expect(valid.attemptID == attemptID)
        #expect(valid.bootstrapFileDescriptor == 3)
        #expect(
            DetachedAgentRunnerInvocation(
                arguments: [
                    "HeyMate",
                    DetachedAgentRunnerInvocation.commandLineFlag,
                    runID.uuidString,
                    attemptID.uuidString,
                    "9"
                ]
            ) == nil
        )
        #expect(
            DetachedAgentRunnerInvocation(
                arguments: [
                    "HeyMate",
                    DetachedAgentRunnerInvocation.commandLineFlag,
                    runID.uuidString,
                    attemptID.uuidString,
                    "3",
                    "unexpected"
                ]
            ) == nil
        )
    }

    @Test func invocationRejectsMissingOrMalformedIdentifiers() {
        #expect(DetachedAgentRunnerInvocation(arguments: ["HeyMate"]) == nil)
        #expect(
            DetachedAgentRunnerInvocation(
                arguments: [
                    "HeyMate",
                    DetachedAgentRunnerInvocation.commandLineFlag,
                    "not-a-run-id",
                    UUID().uuidString,
                    "3"
                ]
            ) == nil
        )
    }
}
