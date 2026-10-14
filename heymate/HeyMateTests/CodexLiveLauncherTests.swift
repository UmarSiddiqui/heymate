import Darwin
import Foundation
import Testing
@testable import HeyMate

@MainActor
struct CodexLiveLauncherTests {
    @MainActor private final class Harness {
        let root: URL
        let store: FileAgentRunStore
        let launcher: HeadlessAgentLauncher
        let log: URL
        init(unsafeFinal: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-live-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            log = root.appendingPathComponent("peer.jsonl")
            store = FileAgentRunStore(fileURL: root.appendingPathComponent("runs.json"))
            launcher = HeadlessAgentLauncher(store: store, undoLedger: FileAgentUndoLedger(rootDirectoryURL: root.appendingPathComponent("undo")))
            let executable = root.appendingPathComponent("codex-peer")
            let source = #"""
            #!/usr/bin/python3
            import json, os, pathlib, sys
            root = pathlib.Path(__file__).parent
            final = any(x.startswith('mcp_servers=') for x in sys.argv)
            unsafe = (root / 'unsafe').exists()
            def emit(value):
                print(json.dumps(value), flush=True)
            for line in sys.stdin:
                message = json.loads(line)
                with (root / 'peer.jsonl').open('a') as output:
                    output.write(json.dumps({'pid':os.getpid(),'final':final, **message})+'\n')
                method = message.get('method')
                identifier = message.get('id')
                if identifier is None:
                    continue
                result = {}
                if method == 'config/read':
                    result = {'config':{'features':{x:False for x in ['apps','hooks','plugins','multi_agent']},
                        'notify':[], 'model_provider':'openai',
                        'mcp_servers':{'fixture.server':{'enabled': not final or unsafe}}}}
                elif method in ['thread/start','thread/resume']:
                    result = {'thread':{'id':'owned-thread'},'sandbox':{'type':'readOnly','networkAccess':False},'approvalPolicy':'on-request'}
                elif method == 'turn/start':
                    result = {'turn':{'id':'owned-turn','status':'inProgress'}}
                elif method == 'turn/steer':
                    result = {'turnId':'owned-turn'}
                emit({'id':identifier,'result':result})
                if method == 'turn/steer':
                    emit({'method':'turn/completed','params':{'threadId':'owned-thread','turn':{
                        'id':'owned-turn','status':'completed','items':[{'type':'agentMessage','id':'plan',
                        'phase':'final_answer','text':'Inspect settings, then propose change. Approval required.'}]}}})
            """#
            try source.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            if unsafeFinal { try Data().write(to: root.appendingPathComponent("unsafe")) }
            launcher.resolveExecutable = { _ in executable }
        }
        func start() -> UUID {
            launcher.startAttached(prompt: "Inspect settings", executor: .codex, workspaceURL: root,
                screenContext: AgentScreenContext(activeAppName: "Fixture", windowTitle: "Test"))
        }
        func records() -> [[String: JSONValue]] {
            guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                      case .object(let fields) = value else { return nil }
                return fields
            }
        }
        func cleanup() async {
            for run in store.loadAll() where !run.status.isTerminal { launcher.cancel(runID: run.id) }
            _ = await CodexLiveLauncherTests.wait { self.store.loadAll().allSatisfy { $0.status.isTerminal || $0.status == .awaitingPlanApproval } }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    @Test func liveInputUsesOwnedTurnAndPlanWaitsForChildExit() async throws {
        let h = try Harness()
        let id = h.start()
        let ready = await Self.wait { h.records().contains { $0["method"] == .string("turn/start") } }
        #expect(ready)
        #expect(h.launcher.sendFollowUp(runID: id, instruction: "Include accessibility checks"))
        #expect(h.launcher.followUpDeliverySummary(runID: id).contains("Sending update"))
        let completed = await Self.wait { h.store.run(id: id)?.status == .awaitingPlanApproval }
        #expect(completed)
        let run = try #require(h.store.run(id: id))
        #expect(run.sessionIdentifier == "owned-thread")
        #expect(run.queuedFollowUpInstructions.isEmpty)
        #expect(run.pid == nil)
        #expect(run.activity.contains { $0.text.contains("acknowledged update") })
        let records = h.records()
        #expect(records.filter { $0["method"] == .string("initialize") }.count == 2)
        let steer = try #require(records.first { $0["method"] == .string("turn/steer") })
        guard case .object(let params) = steer["params"] else { Issue.record("Missing steering params"); await h.cleanup(); return }
        #expect(params["expectedTurnId"] == .string("owned-turn"))
        #expect(params["threadId"] == .string("owned-thread"))
        #expect(records.filter { $0["method"] == .string("turn/start") }.count == 1)
        for record in records {
            if case .number(let pid) = record["pid"] { #expect(kill(pid_t(pid), 0) != 0) }
        }
        await h.cleanup()
    }

    @Test func unsafeMergedConfigurationNeverStartsThread() async throws {
        let h = try Harness(unsafeFinal: true)
        let id = h.start()
        let failed = await Self.wait { h.store.run(id: id)?.status == .failed }
        #expect(failed)
        #expect(!h.records().contains { $0["method"] == .string("thread/start") || $0["method"] == .string("turn/start") })
        #expect(h.store.run(id: id)?.pid == nil)
        await h.cleanup()
    }

    @Test func cancellationStopsOwnedPlanningWithoutPublishingPlan() async throws {
        let h = try Harness()
        let id = h.start()
        let ready = await Self.wait { h.records().contains { $0["method"] == .string("turn/start") } }
        #expect(ready)
        h.launcher.cancel(runID: id)
        let cancelled = await Self.wait { h.store.run(id: id)?.status == .cancelled }
        #expect(cancelled)
        #expect(h.store.run(id: id)?.planText.isEmpty == true)
        #expect(!h.records().contains { $0["method"] == .string("turn/steer") })
        await h.cleanup()
    }

    @Test func overridesQuoteServerNamesAndRejectEnabledFinalServer() throws {
        let response: JSONValue = .object(["config": .object([
            "features": .object(Dictionary(uniqueKeysWithValues: CodexPlanningIsolation.disabledFeatures.map { ($0, .bool(false)) })),
            "notify": .array([]), "model_provider": .string("openai"),
            "mcp_servers": .object(["fixture.server": .object(["enabled": .bool(true)])])
        ])])
        let arguments = try CodexPlanningIsolation.arguments(disablingServersFrom: response)
        #expect(arguments.contains("mcp_servers={\"fixture.server\"={enabled=false}}"))
        #expect(throws: CodexPlanningIsolation.Failure.self) { try CodexPlanningIsolation.validateFinalConfiguration(response) }
    }

    @Test func cancelBeforeStartupCannotLaunchLateProcess() async throws {
        let h = try Harness()
        let id = h.start()
        h.launcher.cancel(runID: id)
        let cancelled = await Self.wait { h.store.run(id: id)?.status == .cancelled }
        #expect(cancelled)
        for _ in 0..<20 { await Task.yield() }
        #expect(h.records().isEmpty)
        await h.cleanup()
    }

    @Test func timeoutStopsLiveTurnBeforeFailureBecomesTerminal() async throws {
        let h = try Harness()
        h.launcher.runtimeLimitForLeg = { _ in 0.35 }
        let id = h.start()
        let failed = await Self.wait { h.store.run(id: id)?.status == .failed }
        #expect(failed)
        #expect(h.store.run(id: id)?.error == "Timed out")
        for record in h.records() {
            if case .number(let pid) = record["pid"] { #expect(kill(pid_t(pid), 0) != 0) }
        }
        await h.cleanup()
    }

    @Test func messageAfterPlanInvalidatesApprovalAndResumesSameThread() async throws {
        let h = try Harness()
        let id = h.start()
        let ready = await Self.wait { h.records().contains { $0["method"] == .string("turn/start") } }
        #expect(ready)
        #expect(h.launcher.sendFollowUp(runID: id, instruction: "Include accessibility"))
        let awaiting = await Self.wait { h.store.run(id: id)?.status == .awaitingPlanApproval }
        #expect(awaiting)
        #expect(h.launcher.sendFollowUp(runID: id, instruction: "Revise contrast checks"))
        #expect(h.store.run(id: id)?.status == .planning)
        #expect(h.store.run(id: id)?.planText.isEmpty == true)
        let resumed = await Self.wait { h.records().contains { $0["method"] == .string("thread/resume") } }
        #expect(resumed)
        #expect(h.records().filter { $0["method"] == .string("thread/start") }.count == 1)
        await h.cleanup()
    }
}
