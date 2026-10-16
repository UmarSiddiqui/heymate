import Foundation
import Testing
@testable import HeyMate

@MainActor
struct LiveExecutionSteeringTests {
    @MainActor
    private final class Peer {
        let connection = CodexAppServerConnection()
        lazy var session = CodexAppServerExecutionSession(connection: connection)
        var sent: [[String: JSONValue]] = []
        var autoSteer = true
        var beforeStartReply: (() -> Void)?
        var turnID = "owned-turn"
        var policy = "untrusted"
        var outcomeCount = 0
        var approved: [CodexAppServerExecutionSession.Approval] = []
        let workspace = URL(fileURLWithPath: "/tmp/steering-pure-fixture")

        func connect() async throws {
            _ = session
            session.onApproval = { [weak self] in self?.approved.append($0) }
            session.onOutcome = { [weak self] _ in self?.outcomeCount += 1 }
            try await connection.connect(write: { [weak self] data in
                guard let self, let value = try? JSONDecoder().decode(JSONValue.self, from: data), case .object(let fields) = value else { return false }
                self.sent.append(fields)
                guard let id = fields["id"], case .string(let method) = fields["method"] else { return true }
                switch method {
                case "initialize": self.reply(id, .emptyObject)
                case "thread/resume": self.reply(id, .object([
                    "thread": .object(["id": .string("owned-thread")]), "cwd": .string(self.workspace.path),
                    "approvalPolicy": .string(self.policy), "sandbox": .object([
                        "type": .string("workspaceWrite"), "writableRoots": .array([.string(self.workspace.path)]),
                        "networkAccess": .bool(false), "excludeSlashTmp": .bool(true), "excludeTmpdirEnvVar": .bool(true)
                    ])
                ]))
                case "turn/start":
                    self.beforeStartReply?()
                    self.reply(id, .object(["turn": .object(["id": .string(self.turnID), "status": .string("inProgress")])]))
                case "turn/interrupt": self.reply(id, .emptyObject)
                case "turn/steer" where self.autoSteer: self.reply(id, .object(["turnId": .string(self.turnID)]))
                default: break
                }
                return true
            }, stop: {})
        }
        func start() async throws {
            _ = try await session.start(launch: .init(threadID: "owned-thread", model: "chosen-model", effort: "high",
                                                      mcpArguments: [], approvalPolicy: "untrusted"), workspace: workspace)
        }
        func deliver(_ value: JSONValue) { connection.receive(String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)) }
        func reply(_ id: JSONValue, _ value: JSONValue) { deliver(.object(["id": id, "result": value])) }
        func request(_ id: Int, turn: String = "owned-turn") {
            deliver(.object(["id": .number(Double(id)), "method": .string("item/commandExecution/requestApproval"),
                "params": .object(["threadId": .string("owned-thread"), "turnId": .string(turn),
                                    "itemId": .string("command-\(id)"), "command": .string("touch fixture.txt")])]))
        }
        func complete(turn: String = "owned-turn") {
            deliver(.object(["method": .string("turn/completed"), "params": .object([
                "threadId": .string("owned-thread"), "turn": .object(["id": .string(turn), "status": .string("completed"),
                    "items": .array([.object(["type": .string("agentMessage"), "id": .string("answer"),
                                              "phase": .string("final_answer"), "text": .string("HEYMATE_RESULT: Verified fixture.")])])])
            ])]))
        }
        func count(_ method: String) -> Int { sent.filter { $0["method"] == .string(method) }.count }
        func steerID() -> JSONValue? { sent.last { $0["method"] == .string("turn/steer") }?["id"] }
    }

    @Test func executionResumesOwnedThreadAndReappliesPolicy() async throws {
        let peer = Peer(); try await peer.connect(); try await peer.start()
        #expect(peer.count("thread/resume") == 1 && peer.count("thread/start") == 0)
        let start = peer.sent.first { $0["method"] == .string("turn/start") }!
        guard case .object(let params) = start["params"], case .object(let sandbox) = params["sandboxPolicy"] else { Issue.record("missing policy"); return }
        #expect(params["approvalPolicy"] == .string("untrusted"))
        #expect(params["model"] == .string("chosen-model"))
        #expect(sandbox["type"] == .string("workspaceWrite") && sandbox["networkAccess"] == .bool(false))
        #expect(sandbox["writableRoots"] == .array([.string(peer.workspace.path)]))
        peer.connection.close()
    }

    @Test func wrongTurnCannotSteerOrRequestApproval() async throws {
        let peer = Peer(); try await peer.connect(); try await peer.start()
        let receipt = await peer.session.steer(text: "Update", expectedTurnID: "wrong-turn", messageID: UUID())
        #expect(receipt == .unavailable && peer.count("turn/steer") == 0)
        peer.request(51, turn: "wrong-turn")
        #expect(peer.approved.isEmpty)
        #expect(peer.sent.last?["error"] != nil)
        peer.complete(turn: "wrong-turn")
        #expect(peer.session.outcome == nil)
        peer.connection.close()
    }

    @Test func earlyApprovalsBindOnlyAfterStartAndAreSingleUse() async throws {
        let peer = Peer(); try await peer.connect()
        peer.beforeStartReply = { peer.request(11); peer.request(12) }
        try await peer.start()
        #expect(peer.approved.count == 1)
        let first = peer.approved[0]
        #expect(first.details.contains("touch fixture.txt"))
        #expect(peer.session.resolveApproval(localID: first.localID, approve: true))
        #expect(!peer.session.resolveApproval(localID: first.localID, approve: true))
        peer.session.presentNextApproval()
        #expect(peer.approved.count == 2)
        #expect(!peer.session.resolveApproval(localID: first.localID, approve: true))
        #expect(peer.session.resolveApproval(localID: peer.approved[1].localID, approve: false))
        let responses = peer.sent.filter { $0["method"] == nil && $0["result"] != nil }
        #expect(responses.contains { $0["id"] == .number(11) && $0["result"] == .object(["decision": .string("accept")]) })
        #expect(responses.contains { $0["id"] == .number(12) && $0["result"] == .object(["decision": .string("decline")]) })
        peer.connection.close()
    }

    @Test func completionBeforeAcknowledgementStillRecordsExactAcceptanceWithoutReplay() async throws {
        let peer = Peer(); try await peer.connect(); try await peer.start(); peer.autoSteer = false
        let messageID = UUID()
        let sending = Task { await peer.session.steer(text: "Keep scope small", expectedTurnID: "owned-turn", messageID: messageID) }
        for _ in 0..<100 where peer.steerID() == nil { await Task.yield() }
        let id = try #require(peer.steerID())
        peer.complete()
        #expect(peer.outcomeCount == 1)
        peer.reply(id, .object(["turnId": .string("owned-turn")]))
        #expect(await sending.value == .accepted)
        #expect(await peer.session.steer(text: "Keep scope small", expectedTurnID: "owned-turn", messageID: messageID) == .accepted)
        #expect(await peer.session.steer(text: "Changed input", expectedTurnID: "owned-turn", messageID: messageID) == .rejected)
        #expect(peer.count("turn/steer") == 1 && peer.count("turn/start") == 1)
        peer.connection.close()
    }

    @Test func connectionLossLeavesUnknownDeliveryAndDoesNotReplay() async throws {
        let peer = Peer(); try await peer.connect(); try await peer.start(); peer.autoSteer = false
        let sending = Task { await peer.session.steer(text: "Update", expectedTurnID: "owned-turn", messageID: UUID()) }
        for _ in 0..<100 where peer.steerID() == nil { await Task.yield() }
        peer.connection.close()
        #expect(await sending.value == .unknown)
        #expect(peer.count("turn/steer") == 1)
    }

    @Test func interruptAcknowledgementDoesNotClaimTerminalOutcome() async throws {
        let peer = Peer(); try await peer.connect(); try await peer.start()
        await peer.session.interrupt()
        #expect(peer.session.outcome == nil)
        let sent = try #require(peer.sent.last { $0["method"] == .string("turn/interrupt") })
        #expect(sent["params"] == .object(["threadId": .string("owned-thread"), "turnId": .string("owned-turn")]))
        peer.connection.close()
    }

    @Test func changedApprovalPolicyStopsBeforeStartingExecution() async throws {
        let peer = Peer(); try await peer.connect(); peer.policy = "never"
        do { try await peer.start(); Issue.record("policy mismatch accepted") } catch {}
        #expect(peer.count("turn/start") == 0)
        peer.connection.close()
    }

    @Test func unavailableFallbackQueuesOnlyOnceAndUnknownNeverQueues() throws {
        let runID = UUID(), attempt = UUID(), token = UUID(), message = UUID()
        var run = AgentRun.queued(id: runID, title: "Fixture", prompt: "Fixture", workspaceURL: URL(fileURLWithPath: "/tmp/unused-steering"), executor: .codex, origin: .attached)
        run.status = .running; run.detachedAttemptIdentifier = attempt.uuidString
        run.liveInputDeliveries = [.init(id: message, attemptID: attempt, turnToken: token, text: "Narrow scope", status: .sending)]
        var state = DetachedAgentDurableState(runID: runID, attemptID: attempt, leg: .execute, phase: .succeeded)
        state.liveInputReceipts = [.init(messageID: message, turnToken: token, status: .unavailable)]
        let once = try DetachedAgentRunReducer.reduce(run: run, state: state, journal: [])
        let twice = try DetachedAgentRunReducer.reduce(run: once, state: state, journal: [])
        #expect(once.queuedFollowUpInstructions == ["Narrow scope"] && twice.queuedFollowUpInstructions == ["Narrow scope"])
        state.liveInputReceipts?[0].status = .unknown
        let unknown = try DetachedAgentRunReducer.reduce(run: run, state: state, journal: [])
        #expect(unknown.queuedFollowUpInstructions.isEmpty && unknown.liveInputDeliveries?[0].status == .unknown)
        state.liveInputReceipts = [.init(messageID: message, turnToken: UUID(), status: .accepted)]
        let wrongToken = try DetachedAgentRunReducer.reduce(run: run, state: state, journal: [])
        #expect(wrongToken.liveInputDeliveries?[0].status == .unknown)
    }
}
