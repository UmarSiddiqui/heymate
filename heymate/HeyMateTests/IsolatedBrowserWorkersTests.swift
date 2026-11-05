import Foundation
import Testing
@testable import HeyMate

@MainActor
struct IsolatedBrowserWorkersTests {
    private final class Driver: BrowserWorkerTransport {
        var calls: [(String, [String: Any])] = []
        var stopped = false
        var delay: Duration = .milliseconds(20)
        var active = 0
        var maximumActive = 0
        var failure = false
        var onNavigate: (() -> Void)?
        func start() async throws {}
        func stop() { stopped = true }
        func call(_ tool: String, _ arguments: [String: Any]) async throws -> [String: Any] {
            guard !stopped else { throw CancellationError() }
            calls.append((tool, arguments))
            if tool == "browser_prepare" { return ["prepared": true, "prepared_pid": 123, "side_effects": ["copied_profile_data": false]] }
            if tool == "list_windows" { return ["windows": [["pid": 123, "window_id": 456]]] }
            if tool == "end_session" { return ["active": false] }
            if tool == "get_browser_state", arguments["pid"] != nil {
                return ["binding_quality": "exact", "target_id": "owned-target", "tabs": [["tab_id": "owned-tab"]]]
            }
            active += 1; maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            if tool == "browser_navigate" { onNavigate?() }
            try await Task.sleep(for: delay)
            guard !stopped else { throw CancellationError() }
            if failure { throw CuaDriverClientError.toolFailed("synthetic refusal") }
            if tool == "get_browser_state" {
                return ["page": ["title": "Fixture", "url": "https://fixture.test"], "outline": "Fixture content",
                    "refs": [["ref": "p1:0", "role": "textbox", "name": "Name", "actions": ["type"]],
                             ["ref": "p1:1", "role": "button", "name": "Send", "actions": ["click"]],
                             ["ref": "p1:2", "role": "textbox", "name": "Password", "actions": ["type"]]]]
            }
            return ["effect": "confirmed"]
        }
    }

    private func tab(_ text: String) -> Int {
        Int(text.components(separatedBy: "Isolated tab ").last?.prefix(while: { $0.isNumber }) ?? "") ?? 0
    }
    private func ref(_ text: String, named name: String) -> Int {
        let line = text.components(separatedBy: "\n").first { $0.contains("“\(name)”") } ?? ""
        return Int(line.dropFirst().prefix(while: { $0.isNumber })) ?? 0
    }
    private func open(_ pool: IsolatedBrowserWorkers, _ owner: String, scope: String = "turn") async -> (text: String, isError: Bool) {
        await pool.perform(arguments: ["op": "open", "url": "https://fixture.test"], owner: owner, scope: scope) { _, _ in true }
    }

    @Test func independentWorkersProgressWhileAnotherWorkerIsBlocked() async throws {
        let first = Driver(), second = Driver()
        first.delay = .milliseconds(500)
        var made = 0
        let pool = IsolatedBrowserWorkers(factory: { made += 1; return made == 1 ? first : second }, mode: { .fullAccess })
        let slow = Task { await open(pool, "mate-a/chat-a") }
        while first.calls.filter({ $0.0 == "browser_navigate" }).isEmpty { await Task.yield() }
        let fast = await open(pool, "mate-b/chat-b")
        #expect(!fast.isError)
        #expect(first.active == 1) // Actual overlap; no wall-clock speed assertion.
        let result = await slow.value
        #expect(!result.isError)
        #expect(tab(result.text) != tab(fast.text))
        #expect(first.calls.first?.1["session"] as? String != second.calls.first?.1["session"] as? String)
        for owner in ["mate-a/chat-a", "mate-b/chat-b"] { pool.finishTurn(owner: owner, scope: "turn", cancelled: true) }
    }

    @Test func sameWorkerCommandsSerializeAndForeignTabsAndRefsNeverReachDriver() async throws {
        let a = Driver(), b = Driver(); var made = 0
        let pool = IsolatedBrowserWorkers(factory: { made += 1; return made == 1 ? a : b }, mode: { .fullAccess })
        let pageA = await open(pool, "a"), pageB = await open(pool, "b")
        let before = b.calls.count
        let foreignTab = await pool.perform(arguments: ["op": "snapshot", "tab_id": tab(pageA.text)], owner: "b", scope: "turn") { _, _ in true }
        let foreignRef = await pool.perform(arguments: ["op": "type", "tab_id": tab(pageB.text), "ref": ref(pageA.text, named: "Name"), "text": "wrong"], owner: "b", scope: "turn") { _, _ in true }
        #expect(foreignTab.isError && foreignRef.isError)
        #expect(b.calls.count == before)
        async let one = pool.perform(arguments: ["op": "snapshot", "tab_id": tab(pageA.text)], owner: "a", scope: "turn", approve: { _, _ in true })
        async let two = pool.perform(arguments: ["op": "extract", "tab_id": tab(pageA.text)], owner: "a", scope: "turn", approve: { _, _ in true })
        _ = await (one, two)
        #expect(a.maximumActive == 1)
        let stale = await pool.perform(arguments: ["op": "type", "tab_id": tab(pageA.text), "ref": ref(pageA.text, named: "Name"), "text": "stale"], owner: "a", scope: "turn") { _, _ in true }
        #expect(stale.isError)
        for owner in ["a", "b"] { pool.finishTurn(owner: owner, scope: "turn", cancelled: true) }
    }

    @Test func approvalGrantsAndExternalActionFloorStayWithinOwner() async throws {
        let a = Driver(), b = Driver(); var made = 0; var ordinary = 0; var external = 0
        let pool = IsolatedBrowserWorkers(factory: { made += 1; return made == 1 ? a : b }, mode: { .askMe })
        let approve: (String, Bool) async -> Bool = { _, every in if every { external += 1 } else { ordinary += 1 }; return true }
        let page = await pool.perform(arguments: ["op": "open", "url": "https://fixture.test"], owner: "a", scope: "turn", approve: approve)
        _ = await pool.perform(arguments: ["op": "open", "url": "https://fixture.test/next"], owner: "a", scope: "turn", approve: approve)
        _ = await pool.perform(arguments: ["op": "open", "url": "https://fixture.test"], owner: "b", scope: "turn", approve: approve)
        #expect(ordinary == 2)
        let current = await pool.perform(arguments: ["op": "snapshot", "tab_id": tab(page.text)], owner: "a", scope: "turn", approve: approve)
        _ = await pool.perform(arguments: ["op": "click", "tab_id": tab(page.text), "ref": ref(current.text, named: "Send")], owner: "a", scope: "turn", approve: approve)
        #expect(external == 1)
        let fresh = await pool.perform(arguments: ["op": "snapshot", "tab_id": tab(page.text)], owner: "a", scope: "turn", approve: approve)
        let secret = await pool.perform(arguments: ["op": "type", "tab_id": tab(page.text), "ref": ref(fresh.text, named: "Password"), "text": "must-not-type"], owner: "a", scope: "turn", approve: approve)
        #expect(secret.isError)
        #expect(!a.calls.contains { $0.0 == "browser_type" })
        for owner in ["a", "b"] { pool.finishTurn(owner: owner, scope: "turn", cancelled: true) }
    }

    @Test func cancellationStopsOnlyOwnedDriverAndQueuedActionsNeverRun() async throws {
        let a = Driver(), b = Driver(); var made = 0
        a.delay = .milliseconds(500)
        let pool = IsolatedBrowserWorkers(factory: { made += 1; return made == 1 ? a : b }, mode: { .fullAccess })
        let first = Task { await open(pool, "a") }
        while a.active == 0 { await Task.yield() }
        let queued = Task { await open(pool, "a") }
        let pageB = await open(pool, "b")
        first.cancel()
        #expect(await first.value.isError)
        #expect(await queued.value.isError)
        #expect(a.stopped && !b.stopped)
        #expect(a.calls.filter { $0.0 == "browser_navigate" }.count == 1)
        #expect(!pageB.isError)
        pool.finishTurn(owner: "b", scope: "turn", cancelled: true)
    }

    @Test func capacityKeepRebindAndExpiredScopes() async throws {
        let driver = Driver()
        let pool = IsolatedBrowserWorkers(maximum: 1, factory: { driver }, mode: { .fullAccess })
        let page = await open(pool, "a")
        #expect(await open(pool, "b").isError)
        _ = await pool.perform(arguments: ["op": "keep", "tab_id": tab(page.text), "why": "waiting"], owner: "a", scope: "turn") { _, _ in true }
        pool.finishTurn(owner: "a", scope: "turn", cancelled: false)
        pool.beginTurn(owner: "a", scope: "next")
        pool.finishTurn(owner: "a", scope: "turn", cancelled: true)
        #expect(!driver.stopped)
        let resumed = await pool.perform(arguments: ["op": "snapshot", "tab_id": tab(page.text)], owner: "a", scope: "next") { _, _ in true }
        #expect(!resumed.isError)
        let stale = await pool.perform(arguments: ["op": "snapshot", "tab_id": tab(page.text)], owner: "a", scope: "turn") { _, _ in true }
        #expect(stale.isError)
        pool.finishTurn(owner: "a", scope: "next", cancelled: true)
        #expect(driver.stopped)
    }

    @Test func idleExpiryAndDeclinedLaunchLeaveNoLiveDriver() async throws {
        let driver = Driver()
        let pool = IsolatedBrowserWorkers(idle: .milliseconds(40), factory: { driver }, mode: { .fullAccess })
        _ = await open(pool, "a")
        try await Task.sleep(for: .milliseconds(150))
        #expect(driver.stopped)
        let declined = Driver()
        let askPool = IsolatedBrowserWorkers(factory: { declined }, mode: { .askMe })
        let result = await askPool.perform(arguments: ["op": "open", "url": "https://fixture.test"], owner: "a", scope: "turn") { _, _ in false }
        #expect(result.isError)
        #expect(declined.calls.isEmpty)
        #expect(declined.stopped)
    }

    @Test func explicitEndWaitsForConfirmedCleanupAndDriverFailureDoesNotClaimSuccess() async throws {
        let driver = Driver()
        let pool = IsolatedBrowserWorkers(factory: { driver }, mode: { .fullAccess })
        _ = await open(pool, "a")
        let ended = await pool.perform(arguments: ["op": "end"], owner: "a", scope: "turn") { _, _ in true }
        #expect(!ended.isError)
        #expect(driver.calls.last?.0 == "end_session")
        #expect(driver.stopped)
        let failing = Driver(); failing.failure = true
        let failedPool = IsolatedBrowserWorkers(factory: { failing }, mode: { .fullAccess })
        #expect(await open(failedPool, "a").isError)
        #expect(failing.stopped)
    }
}
