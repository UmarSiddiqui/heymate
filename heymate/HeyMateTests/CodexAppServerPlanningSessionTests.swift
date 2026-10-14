import Foundation
import Testing
@testable import HeyMate

@MainActor
struct CodexAppServerPlanningSessionTests {
    @MainActor
    private final class Peer {
        let connection = CodexAppServerConnection()
        lazy var session = CodexAppServerPlanningSession(
            owner: .init(runID: UUID(), attemptID: UUID()), connection: connection)
        var sent: [[String: JSONValue]] = []
        var threadID = "thread-owned"
        var turnID = "turn-owned"
        var autoSteer = true
        var onTurnStart: (() -> Void)?
        var steerError: String?
        var sandbox: JSONValue = .object(["type": .string("readOnly"), "networkAccess": .bool(false)])
        var outcomeCount = 0

        func connect() async throws {
            try await connection.connect(write: { [weak self] data in
                guard let self, let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
                      case .object(let fields) = decoded else { return false }
                self.sent.append(fields)
                guard let id = fields["id"], case .string(let method) = fields["method"] else { return true }
                switch method {
                case "initialize": self.reply(id, .emptyObject)
                case "thread/start", "thread/resume":
                    self.reply(id, .object(["thread": .object(["id": .string(self.threadID)]),
                                           "sandbox": self.sandbox, "approvalPolicy": .string("on-request")]))
                case "turn/start":
                    self.onTurnStart?()
                    self.reply(id, .object(["turn": .object(["id": .string(self.turnID), "status": .string("inProgress")])]))
                case "turn/steer" where self.autoSteer:
                    if let error = self.steerError {
                        self.deliver(.object(["id": id, "error": .object(["code": .number(-32000), "message": .string(error)])]))
                    } else { self.reply(id, .object(["turnId": .string(self.turnID)])) }
                case "turn/interrupt": self.reply(id, .emptyObject)
                default: break
                }
                return true
            }, stop: {})
            session.onOutcome = { [weak self] _ in self?.outcomeCount += 1 }
        }

        func start(resume: String? = nil) async throws -> CodexAppServerPlanningSession.Identity {
            try await session.start(text: "Plan a settings change", workspaceURL: URL(fileURLWithPath: "/tmp/owned-workspace"),
                                    resumeThreadID: resume, model: "chosen-model", effort: "high")
        }
        func deliver(_ value: JSONValue) {
            let data = try! JSONEncoder().encode(value)
            connection.receive(String(decoding: data, as: UTF8.self))
        }
        func reply(_ id: JSONValue, _ result: JSONValue) { deliver(.object(["id": id, "result": result])) }
        func notify(_ method: String, _ fields: [String: JSONValue]) {
            deliver(.object(["method": .string(method), "params": .object(fields)]))
        }
        func message(_ text: String, itemID: String = "answer", phase: String? = "final_answer") -> JSONValue {
            var fields: [String: JSONValue] = ["type": .string("agentMessage"), "id": .string(itemID), "text": .string(text)]
            if let phase { fields["phase"] = .string(phase) }
            return .object(fields)
        }
        func complete(status: String = "completed", thread: String? = nil, turn: String? = nil, items: [JSONValue] = []) {
            notify("turn/completed", ["threadId": .string(thread ?? threadID),
                "turn": .object(["id": .string(turn ?? turnID), "status": .string(status), "items": .array(items)])])
        }
        func count(_ method: String) -> Int { sent.filter { $0["method"] == .string(method) }.count }
        func params(_ method: String) throws -> [String: JSONValue] {
            guard case .object(let value) = sent.last(where: { $0["method"] == .string(method) })?["params"] else {
                throw CodexAppServerPlanningSession.Failure.invalidResponse
            }
            return value
        }
        func waitForSteer() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while count("turn/steer") == 0 {
                guard ContinuousClock.now < deadline else { throw CodexAppServerConnection.Failure.timedOut }
                await Task.yield()
            }
        }
    }

    @Test func everyPlanningTurnReappliesReadOnlyPolicyAndKeepsChosenModel() async throws {
        let peer = Peer()
        try await peer.connect()
        let identity = try await peer.start()
        #expect(identity.owner == peer.session.owner)
        #expect(identity.threadID == "thread-owned")
        #expect(identity.turnID == "turn-owned")
        let thread = try peer.params("thread/start")
        let turn = try peer.params("turn/start")
        #expect(thread["sandbox"] == .string("read-only"))
        #expect(thread["approvalPolicy"] == .string("on-request"))
        #expect(turn["sandboxPolicy"] == .object(["type": .string("readOnly"), "networkAccess": .bool(false)]))
        #expect(turn["model"] == .string("chosen-model"))
        #expect(turn["effort"] == .string("high"))
        _ = await peer.session.shutdown()
    }

    @Test func resumeRequiresExactThreadAndNeverStartsFreshOnMismatch() async throws {
        let peer = Peer()
        try await peer.connect()
        await #expect(throws: CodexAppServerPlanningSession.Failure.invalidResponse) { try await peer.start(resume: "other-thread") }
        #expect(peer.count("thread/resume") == 1)
        #expect(peer.count("thread/start") == 0)
        #expect(peer.count("turn/start") == 0)
        #expect(peer.outcomeCount == 1)
    }

    @Test func notificationsBeforeStartReplyBindOnlyReturnedTurn() async throws {
        let peer = Peer()
        try await peer.connect()
        peer.onTurnStart = { [weak peer] in
            peer?.complete(turn: "foreign-turn", items: [peer!.message("Wrong")])
            peer?.complete(items: [peer!.message("Owned plan")])
        }
        _ = try await peer.start()
        #expect(peer.session.outcome == .completed(plan: "Owned plan"))
        #expect(peer.outcomeCount == 1)
        _ = await peer.session.shutdown()
    }

    @Test func foreignEventsCannotFinishOrContaminateOwnedPlan() async throws {
        let peer = Peer()
        try await peer.connect()
        _ = try await peer.start()
        peer.complete(thread: "foreign-thread", items: [peer.message("Wrong")])
        peer.complete(turn: "foreign-turn", items: [peer.message("Wrong")])
        peer.notify("item/agentMessage/delta", ["threadId": .string(peer.threadID), "turnId": .string("foreign-turn"),
                                                  "itemId": .string("foreign"), "delta": .string("Wrong")])
        #expect(peer.session.outcome == nil)
        peer.complete(items: [peer.message("Owned")])
        peer.complete(items: [peer.message("Late wrong")])
        #expect(peer.session.outcome == .completed(plan: "Owned"))
        #expect(peer.outcomeCount == 1)
        _ = await peer.session.shutdown()
    }

    @Test func terminalSnapshotDeduplicatesDeltasAndPrefersFinalAnswer() async throws {
        let peer = Peer()
        try await peer.connect()
        _ = try await peer.start()
        peer.notify("item/agentMessage/delta", ["threadId": .string(peer.threadID), "turnId": .string(peer.turnID),
                                                  "itemId": .string("answer"), "delta": .string("Plan")])
        peer.notify("item/completed", ["threadId": .string(peer.threadID), "turnId": .string(peer.turnID),
                                        "item": peer.message("Full plan")])
        peer.complete(items: [peer.message("Reading files", itemID: "comment", phase: "commentary"), peer.message("Full plan")])
        #expect(peer.session.outcome == .completed(plan: "Full plan"))
        _ = await peer.session.shutdown()
    }

    @Test func missingPhaseRemainsCompatibleButCommentaryAloneIsNotPlan() async throws {
        let legacy = Peer()
        try await legacy.connect()
        _ = try await legacy.start()
        legacy.complete(items: [legacy.message("Legacy plan", phase: nil)])
        #expect(legacy.session.outcome == .completed(plan: "Legacy plan"))
        _ = await legacy.session.shutdown()
        let commentary = Peer()
        try await commentary.connect()
        _ = try await commentary.start()
        commentary.complete(items: [commentary.message("Reading files", phase: "commentary")])
        #expect(commentary.session.outcome == .failed("The agent finished without producing a plan."))
        _ = await commentary.session.shutdown()
    }

    @Test func steerRequiresOwnedTurnAndMessageIDBindsExactInput() async throws {
        let peer = Peer()
        try await peer.connect()
        _ = try await peer.start()
        let id = UUID()
        #expect(await peer.session.steer(text: "Use two columns", expectedTurnID: "foreign", messageID: id) == .unavailable)
        #expect(peer.count("turn/steer") == 0)
        #expect(await peer.session.steer(text: "Use two columns", expectedTurnID: peer.turnID, messageID: id) == .acknowledged(turnID: peer.turnID))
        let params = try peer.params("turn/steer")
        #expect(params["expectedTurnId"] == .string(peer.turnID))
        #expect(params["threadId"] == .string(peer.threadID))
        #expect(params["clientUserMessageId"] == .string(id.uuidString))
        #expect(params["sandboxPolicy"] == nil)
        #expect(await peer.session.steer(text: "Use two columns", expectedTurnID: peer.turnID, messageID: id) == .acknowledged(turnID: peer.turnID))
        #expect(await peer.session.steer(text: "Different input", expectedTurnID: peer.turnID, messageID: id) == .rejected("Message ID already belongs to different input."))
        #expect(peer.count("turn/steer") == 1)
        _ = await peer.session.shutdown()
    }

    @Test func timeoutIsUnknownAndNeverReplayedOrStartedAsAnotherTurn() async throws {
        let peer = Peer()
        peer.autoSteer = false
        try await peer.connect()
        _ = try await peer.start()
        let id = UUID()
        #expect(await peer.session.steer(text: "Update plan", expectedTurnID: peer.turnID, messageID: id, timeout: .milliseconds(10)) == .unknown)
        #expect(await peer.session.steer(text: "Update plan", expectedTurnID: peer.turnID, messageID: id) == .unknown)
        #expect(peer.count("turn/steer") == 1)
        #expect(peer.count("turn/start") == 1)
        _ = await peer.session.shutdown()
    }

    @Test func completionRaceRetainsAcknowledgementWithoutRevivingTurn() async throws {
        let peer = Peer()
        peer.autoSteer = false
        try await peer.connect()
        _ = try await peer.start()
        let id = UUID()
        let steer = Task { await peer.session.steer(text: "Update plan", expectedTurnID: peer.turnID, messageID: id) }
        try await peer.waitForSteer()
        #expect(await peer.session.steer(text: "Update plan", expectedTurnID: peer.turnID, messageID: id) == .pending)
        let rpcID = try #require(peer.sent.last?["id"])
        peer.complete(items: [peer.message("Final plan")])
        peer.reply(rpcID, .object(["turnId": .string(peer.turnID)]))
        #expect(await steer.value == .acknowledged(turnID: peer.turnID))
        #expect(peer.session.outcome == .completed(plan: "Final plan"))
        #expect(await peer.session.steer(text: "New", expectedTurnID: peer.turnID, messageID: UUID()) == .unavailable)
        #expect(peer.outcomeCount == 1)
        _ = await peer.session.shutdown()
    }

    @Test func remoteSteerRejectionNeverLaunchesFallbackTurn() async throws {
        let peer = Peer()
        peer.steerError = "No active turn was available to steer."
        try await peer.connect()
        _ = try await peer.start()
        #expect(await peer.session.steer(text: "Update plan", expectedTurnID: peer.turnID, messageID: UUID()) == .rejected("No active turn was available to steer."))
        #expect(peer.count("turn/start") == 1)
        _ = await peer.session.shutdown()
    }

    @Test func interruptAcknowledgementWaitsForTerminalEvent() async throws {
        let peer = Peer()
        try await peer.connect()
        _ = try await peer.start()
        #expect(await peer.session.interrupt(expectedTurnID: "foreign") == .unavailable)
        #expect(await peer.session.interrupt(expectedTurnID: peer.turnID) == .requested)
        #expect(peer.session.outcome == nil)
        #expect(try peer.params("turn/interrupt") == ["threadId": .string(peer.threadID), "turnId": .string(peer.turnID)])
        peer.complete(status: "interrupted")
        #expect(peer.session.outcome == .interrupted)
        #expect(peer.outcomeCount == 1)
        _ = await peer.session.shutdown()
    }

    @Test func eofCannotLookLikeCompletedTurn() async throws {
        let peer = Peer()
        try await peer.connect()
        _ = try await peer.start()
        peer.connection.close()
        #expect(peer.session.outcome == .failed("Planning connection closed before turn completion."))
        _ = await peer.session.shutdown()
        #expect(peer.outcomeCount == 1)
    }

    @Test func failedTurnUsesOwnedErrorAndEmptyTurnCannotSucceed() async throws {
        let peer = Peer()
        try await peer.connect()
        _ = try await peer.start()
        peer.notify("turn/completed", ["threadId": .string(peer.threadID), "turn": .object([
            "id": .string(peer.turnID), "status": .string("failed"), "items": .array([]),
            "error": .object(["message": .string("Read denied")])
        ])])
        #expect(peer.session.outcome == .failed("Read denied"))
        _ = await peer.session.shutdown()
        let empty = Peer()
        try await empty.connect()
        _ = try await empty.start()
        empty.complete()
        #expect(empty.session.outcome == .failed("The agent finished without producing a plan."))
        _ = await empty.session.shutdown()
    }

    @Test func invalidInputNeverStartsThreadAndOversizedTextClosesSession() async throws {
        let peer = Peer()
        try await peer.connect()
        await #expect(throws: CodexAppServerPlanningSession.Failure.invalidInput) {
            try await peer.session.start(text: " ", workspaceURL: URL(fileURLWithPath: "/tmp"))
        }
        #expect(peer.count("thread/start") == 0)
        _ = try await peer.start()
        peer.notify("item/agentMessage/delta", ["threadId": .string(peer.threadID), "turnId": .string(peer.turnID),
                                                  "itemId": .string("large"), "delta": .string(String(repeating: "x", count: 4_194_305))])
        #expect(peer.session.outcome == .failed("Planning text exceeded the supported limit."))
        #expect(peer.outcomeCount == 1)
        _ = await peer.session.shutdown()
    }

    @Test func serverCannotUpgradePlanningPolicyBeforeTurnStarts() async throws {
        for sandbox in [JSONValue.object(["type": .string("workspaceWrite")]),
                        .object(["type": .string("readOnly"), "networkAccess": .bool(true)])] {
            let peer = Peer()
            peer.sandbox = sandbox
            try await peer.connect()
            await #expect(throws: CodexAppServerPlanningSession.Failure.policyMismatch) { try await peer.start() }
            #expect(peer.count("turn/start") == 0)
            #expect(peer.outcomeCount == 1)
        }
    }

    @Test func mismatchedSteerAcknowledgementStaysUnknownAndNeverRetargets() async throws {
        let peer = Peer()
        try await peer.connect()
        let owned = try await peer.start()
        peer.turnID = "unexpected-turn"
        #expect(await peer.session.steer(text: "Update plan", expectedTurnID: owned.turnID, messageID: UUID()) == .unknown)
        #expect(peer.session.identity == owned)
        #expect(peer.count("turn/start") == 1)
        _ = await peer.session.shutdown()
    }
}
