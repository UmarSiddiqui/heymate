//
//  SpokenFailureTests.swift
//  leanring-buddyTests
//
//  Voice Talk must not announce every failure as “out of credits”.
//  Mac listen/speak are local; only real model quota/billing errors
//  get the credits utterance.
//

import Foundation
import Testing
@testable import HeyMate

struct SpokenFailureTests {

    @Test func cancellationIsSilent() {
        #expect(SpokenFailure.classify(CancellationError()) == .cancelled)
        #expect(SpokenFailure.classify(CancellationError()).spokenUtterance == nil)

        let cancelledURL = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled,
            userInfo: [NSLocalizedDescriptionKey: "cancelled"]
        )
        #expect(SpokenFailure.classify(cancelledURL) == .cancelled)
    }

    @Test func http402AndQuotaWordsAreCredits() {
        let paymentRequired = NSError(
            domain: "OpenCodeClient",
            code: 402,
            userInfo: [NSLocalizedDescriptionKey: "API Error: payment required"]
        )
        #expect(SpokenFailure.classify(paymentRequired) == .outOfCredits)

        #expect(SpokenFailure.classify(message: "insufficient_quota") == .outOfCredits)
        #expect(SpokenFailure.classify(message: "I'm all out of credits") == .outOfCredits)
        #expect(SpokenFailure.classify(message: "provider billing balance is empty") == .outOfCredits)
        #expect(SpokenFailure.classify(message: "usage limit reached") == .outOfCredits)
    }

    @Test func credentialsAndGenericErrorsAreNotCredits() {
        #expect(SpokenFailure.classify(message: "invalid credentials") == .generic)
        #expect(SpokenFailure.classify(message: "OpenCode response contained no text") == .generic)
        #expect(SpokenFailure.classify(message: "Could not create OpenCode session") == .generic)
        #expect(SpokenFailure.classify(message: "TTS API error (500): boom") == .generic)

        let unauthorized = NSError(
            domain: "ElevenLabsTTS",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: "unauthorized"]
        )
        #expect(SpokenFailure.classify(unauthorized) == .generic)
    }

    @Test func creditsUtteranceNamesTheModelNotVoice() {
        let spoken = SpokenFailure.outOfCredits.spokenUtterance ?? ""
        #expect(spoken.contains("model"))
        #expect(spoken.contains("credits"))
        #expect(spoken.contains("mac"))
        #expect(!spoken.contains("ElevenLabs"))
    }
}
