//
//  AgentProcessIdentityTests.swift
//  leanring-buddyTests
//

import Darwin
import Foundation
import Testing
@testable import HeyMate

struct AgentProcessIdentityTests {
    @Test func currentProcessMatchesCapturedIdentity() throws {
        let identity = try #require(AgentProcessIdentityInspector.identity(for: getpid()))
        #expect(identity.pid == getpid())
        #expect(identity.uid == UInt32(getuid()))
        #expect(identity.executablePath.isEmpty == false)
        #expect(identity.bootSessionID.isEmpty == false)
        #expect(AgentProcessIdentityInspector.matchesLiveProcess(identity))
    }

    @Test func reusedPIDWithDifferentStartTimeIsRejected() throws {
        let identity = try #require(AgentProcessIdentityInspector.identity(for: getpid()))
        let staleIdentity = AgentProcessIdentity(
            pid: identity.pid,
            startSeconds: identity.startSeconds + 1,
            startMicroseconds: identity.startMicroseconds,
            executablePath: identity.executablePath,
            uid: identity.uid,
            bootSessionID: identity.bootSessionID
        )
        #expect(AgentProcessIdentityInspector.matchesLiveProcess(staleIdentity) == false)
    }

    @Test func invalidPIDHasNoIdentity() {
        #expect(AgentProcessIdentityInspector.identity(for: -1) == nil)
    }
}
