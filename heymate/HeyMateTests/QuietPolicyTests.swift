//
//  QuietPolicyTests.swift
//  HeyMateTests
//

import Testing
@testable import HeyMate

struct QuietPolicyTests {

    @Test func shouldSilenceWhenAnyInputFlagIsTrue() {
        #expect(!QuietPolicy.shouldSilence(callsActive: false, screenSharing: false, focusActive: false))
        #expect(QuietPolicy.shouldSilence(callsActive: true, screenSharing: false, focusActive: false))
        #expect(QuietPolicy.shouldSilence(callsActive: false, screenSharing: true, focusActive: false))
        #expect(QuietPolicy.shouldSilence(callsActive: false, screenSharing: false, focusActive: true))
        #expect(QuietPolicy.shouldSilence(callsActive: true, screenSharing: true, focusActive: true))
    }

    @Test func heyMatesOwnMicrophoneIsNotACall() {
        #expect(!QuietPolicy.isAnotherProcessRecording(inputRunningPIDs: [], ownPID: 42))
        #expect(!QuietPolicy.isAnotherProcessRecording(inputRunningPIDs: [42], ownPID: 42))
        #expect(QuietPolicy.isAnotherProcessRecording(inputRunningPIDs: [42, 7], ownPID: 42))
    }
}
