//
//  HeyMateRequestCompletionState.swift
//  leanring-buddy
//
//  OSAllocatedUnfairLock around a didComplete flag so in-flight voice/agent
//  work stays race-free off the main actor. Do not grow this into a timing
//  encyclopedia.
//

import Foundation
import os

final class HeyMateRequestCompletionState: @unchecked Sendable {
    private let didCompleteStorage = OSAllocatedUnfairLock(initialState: false)

    var didComplete: Bool {
        get { didCompleteStorage.withLock { $0 } }
        set { didCompleteStorage.withLock { $0 = newValue } }
    }
}
