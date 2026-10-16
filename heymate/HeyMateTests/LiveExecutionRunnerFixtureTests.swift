import Foundation
import Testing
@testable import HeyMate

@MainActor
struct LiveExecutionRunnerFixtureTests {
    @Test func detachedMailboxPreservesApprovalAndLateSteerAcknowledgement() async throws {
        let node = try #require(LoginShellExecutableResolver.resolveExecutable(named: "node"))
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("heymate-offline-steering-\(UUID())")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let script = fixture.appendingPathComponent("fake-codex")
        let contents = """
        #!\(node.path)
        const readline = require('node:readline');
        const send = value => process.stdout.write(JSON.stringify(value)+'\\n');
        const reply = (id,result) => send({id,result});
        readline.createInterface({input:process.stdin}).on('line', line => {
          const m=JSON.parse(line), p=m.params||{};
          if(m.method==='initialize') reply(m.id,{});
          else if(m.method==='config/read') reply(m.id,{config:{notify:[],model_provider:'openai',features:{apps:false,hooks:false,plugins:false,multi_agent:false},mcp_servers:{}}});
          else if(m.method==='thread/resume') reply(m.id,{thread:{id:'fixture-thread'},cwd:p.cwd,approvalPolicy:p.approvalPolicy,sandbox:{type:'workspaceWrite',networkAccess:false,writableRoots:[p.cwd],excludeSlashTmp:true,excludeTmpdirEnvVar:true}});
          else if(m.method==='turn/start') {
            reply(m.id,{turn:{id:'fixture-turn',status:'inProgress'}});
            send({id:901,method:'item/commandExecution/requestApproval',params:{threadId:'fixture-thread',turnId:'fixture-turn',itemId:'fixture-command',command:'touch fixture.txt'}});
          } else if(m.method==='turn/steer') {
            if(p.threadId!=='fixture-thread'||p.expectedTurnId!=='fixture-turn') process.exit(40);
            send({method:'turn/completed',params:{threadId:'fixture-thread',turn:{id:'fixture-turn',status:'completed',items:[{type:'agentMessage',id:'answer',phase:'final_answer',text:'HEYMATE_RESULT: Steered fixture result.'}]}}});
            setTimeout(()=>reply(m.id,{turnId:'fixture-turn'}),30);
          } else if(m.id===901 && m.result?.decision!=='accept') process.exit(41);
        });
        """
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let root = fixture.appendingPathComponent("runtime")
        let request = DetachedAgentLaunchRequest(runID: UUID(), attemptID: UUID(), executor: .codex, leg: .execute,
            spec: .init(executableURL: script, arguments: [], currentDirectoryURL: fixture, runtimeLimit: 10),
            codexExecution: .init(threadID: "fixture-thread", model: nil, effort: nil, mcpArguments: [], approvalPolicy: "untrusted"))
        var exitCodes: [Int32] = []
        let engine = try DetachedAgentRunnerEngine(request: request, rootDirectoryURL: root,
                                                   exitProcess: { exitCodes.append($0) }, wakeMainApp: {})
        let mailbox = try DetachedAgentCommandMailbox(rootDirectoryURL: root, runID: request.runID, attemptID: request.attemptID)
        func state() -> DetachedAgentDurableState? {
            try? DetachedAgentDurableStateStore.loadReadOnly(rootDirectoryURL: root, runID: request.runID, attemptID: request.attemptID)
        }
        engine.start()
        let waiting = await wait { state()?.phase == .waitingForApproval }
        #expect(waiting)
        let pending = try #require(state()?.pendingApprovalToken)
        #expect(state()?.liveSteeringToken == nil)
        let details = AgentPrivateApprovalStore.load(root: root, runID: request.runID, attemptID: request.attemptID, token: pending.rawValue)
        #expect(details?.contains("touch fixture.txt") == true)
        _ = try mailbox.enqueue(.init(runID: request.runID, attemptID: request.attemptID,
                                      command: .respondToApproval(token: .init(), decision: .approve)))
        try await Task.sleep(for: .milliseconds(300))
        #expect(state()?.phase == .waitingForApproval && state()?.pendingApprovalToken == pending)
        _ = try mailbox.enqueue(.init(runID: request.runID, attemptID: request.attemptID,
                                      command: .respondToApproval(token: pending, decision: .approve)))
        let running = await wait { state()?.liveSteeringToken != nil }
        #expect(running)
        let token = try #require(state()?.liveSteeringToken)
        let staleID = UUID()
        _ = try mailbox.enqueue(.init(runID: request.runID, attemptID: request.attemptID, messageID: staleID,
                                      command: .sendFollowUp("stale fixture input", turnToken: UUID())))
        let rejected = await wait { state()?.liveInputReceipts?.contains { $0.messageID == staleID && $0.status == .unavailable } == true }
        #expect(rejected && state()?.phase == .running)
        let liveID = UUID()
        let input = DetachedAgentCommandEnvelope(runID: request.runID, attemptID: request.attemptID, messageID: liveID,
                                                command: .sendFollowUp("private fixture update", turnToken: token))
        _ = try mailbox.enqueue(input)
        let ended = await wait { state()?.phase.isTerminal == true }
        #expect(ended)
        let final = try #require(state())
        #expect(final.phase == .succeeded && final.liveSteeringToken == nil)
        #expect(final.liveInputReceipts?.contains { $0.messageID == liveID && $0.status == .accepted } == true)
        #expect(exitCodes == [0])
        #expect(try mailbox.enqueue(input) == false)
        #expect(try AgentPrivateResultStore.load(root: root, runID: request.runID, attemptID: request.attemptID) == "Steered fixture result.")
        let encoded = String(decoding: try JSONEncoder().encode(final), as: UTF8.self)
        #expect(!encoded.contains("fixture-thread") && !encoded.contains("fixture-turn") && !encoded.contains("private fixture update"))
        let journal = try DetachedAgentRuntimeJournal.loadReadOnly(rootDirectoryURL: root, runID: request.runID, attemptID: request.attemptID)
        let journalJSON = String(decoding: try JSONEncoder().encode(journal), as: UTF8.self)
        #expect(!journalJSON.contains("touch fixture.txt") && !journalJSON.contains("private fixture update"))
        withExtendedLifetime(engine) {}
    }

    private func wait(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}
