//
//  AgentRunRecoveryTests.swift
//  HeyMateTests
//

import Foundation
import Testing
@testable import HeyMate

struct AgentRunRecoveryTests {

    @Test func didStopQuicklyWithinTenSeconds() {
        let createdAt = Date(timeIntervalSince1970: 100)
        #expect(
            AgentRunRecovery.didStopQuickly(
                startedAt: nil,
                createdAt: createdAt,
                finishedAt: createdAt.addingTimeInterval(9)
            )
        )
        #expect(
            !AgentRunRecovery.didStopQuickly(
                startedAt: nil,
                createdAt: createdAt,
                finishedAt: createdAt.addingTimeInterval(11)
            )
        )
    }

    @Test func followUpInstructionIncludesOriginalTask() {
        let instruction = AgentRunRecovery.followUpInstruction(for: "Ship the landing page")
        #expect(instruction.contains("Ship the landing page"))
        #expect(instruction.contains("continue the original task"))
    }
}
