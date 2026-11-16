import Foundation
import Testing
@testable import HeyMate

@MainActor
struct MateAgentContinuationTests {
    private struct Turn: Equatable {
        let status: String
        let continues: Bool
    }

    private func drive(_ turns: [Turn], startsAsContinuation: Bool = false, max: Int = MateAgentContinuation.maxContinuations,
                       pausedThrows: Bool = false) async throws -> (Turn, [MateAgentContinuation.Step], [Int]) {
        var steps: [MateAgentContinuation.Step] = []
        var pauses: [Int] = []
        let result = try await MateAgentContinuation.run(
            startsAsContinuation: startsAsContinuation, max: max,
            submit: { step in steps.append(step); return turns[min(step.index, turns.count - 1)] },
            status: \.status, continues: \.continues,
            paused: { _, used in
                pauses.append(used)
                if pausedThrows { throw CancellationError() }
            })
        return (result, steps, pauses)
    }

    @Test func decisionContinuesOnlyACompleteCheckpointWithBudgetLeft() {
        #expect(MateAgentContinuation.shouldContinue(status: "complete", continues: true, used: 0, isCancelled: false))
        #expect(!MateAgentContinuation.shouldContinue(status: "complete", continues: false, used: 0, isCancelled: false))
        #expect(!MateAgentContinuation.shouldContinue(status: "complete", continues: true, used: 0, isCancelled: true))
        #expect(!MateAgentContinuation.shouldContinue(status: "error", continues: true, used: 0, isCancelled: false))
        #expect(!MateAgentContinuation.shouldContinue(status: "interrupted", continues: true, used: 0, isCancelled: false))
        #expect(MateAgentContinuation.shouldContinue(status: "complete", continues: true,
            used: MateAgentContinuation.maxContinuations - 1, isCancelled: false))
        #expect(!MateAgentContinuation.shouldContinue(status: "complete", continues: true,
            used: MateAgentContinuation.maxContinuations, isCancelled: false))
        #expect(MateAgentContinuation.maxContinuations == 12)
    }

    @Test func checkpointsChainIntoOneFinalAnswer() async throws {
        let checkpoint = Turn(status: "complete", continues: true)
        let final = Turn(status: "complete", continues: false)
        let (result, steps, pauses) = try await drive([checkpoint, checkpoint, final])
        #expect(result == final)
        #expect(steps.map(\.index) == [0, 1, 2])
        #expect(steps.map(\.isContinuation) == [false, true, true])
        #expect(steps.allSatisfy { $0.allowsContinuation })
        #expect(pauses == [1, 2])
    }

    @Test func aPlainAnswerRunsOneTurn() async throws {
        let (result, steps, pauses) = try await drive([Turn(status: "complete", continues: false)])
        #expect(result.continues == false)
        #expect(steps.count == 1 && pauses.isEmpty)
    }

    @Test func theChainIsBoundedAndTheLastTurnMayNotCheckpoint() async throws {
        let (_, steps, pauses) = try await drive([Turn(status: "complete", continues: true)], max: 3)
        #expect(steps.count == 4)
        #expect(pauses == [1, 2, 3])
        #expect(steps.map(\.allowsContinuation) == [true, true, true, false])
    }

    @Test func taskWorkThatResumesIsAContinuationFromItsFirstTurn() async throws {
        let (_, steps, _) = try await drive([Turn(status: "complete", continues: false)], startsAsContinuation: true)
        #expect(steps.first?.isContinuation == true)
    }

    @Test func stopBetweenTurnsEndsTheWholeChain() async {
        var submitted = 0
        let task = Task { @MainActor in
            try await MateAgentContinuation.run(
                submit: { _ -> Turn in submitted += 1; return Turn(status: "complete", continues: true) },
                status: \.status, continues: \.continues,
                paused: { _, _ in withUnsafeCurrentTask { $0?.cancel() } })
        }
        let outcome = await task.result
        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(submitted == 1)
    }

    @Test func aFailingPauseEndsTheChain() async {
        await #expect(throws: CancellationError.self) {
            _ = try await drive([Turn(status: "complete", continues: true)], pausedThrows: true)
        }
    }
}
