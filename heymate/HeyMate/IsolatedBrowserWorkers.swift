import AppKit
import Foundation

/// Only trusted application code can prepare a profile. Models receive page
/// operations, never a driver, profile path, native PID, or raw MCP capability.
@MainActor
protocol BrowserWorkerTransport: AnyObject {
    func start() async throws
    func call(_ tool: String, _ arguments: [String: Any]) async throws -> [String: Any]
    func stop()
}

extension CuaDriverClient: BrowserWorkerTransport {}

@MainActor
final class IsolatedBrowserWorkers {
    private struct Rejected: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    static let shared = IsolatedBrowserWorkers()
    static let supportedOperations: Set<String> = ["tabs", "open", "navigate", "snapshot", "extract", "click", "type", "scroll", "wait_for", "show", "keep", "close", "end"]

    private final class Worker {
        let owner: String
        let session = "heymate-browser-" + UUID().uuidString
        let tabID: Int
        let transport: any BrowserWorkerTransport
        var scope: String
        var valid = true
        var ready = false
        var pid: Int32?
        var target: [String: Any] = [:]
        var refs: [Int: String] = [:]
        var elements: [Int: BrowserElement] = [:]
        var kept = false
        var grantedUntil: Date?
        var tail: Task<Void, Never>?
        var expiry: Task<Void, Never>?
        var activity = UUID()

        init(owner: String, scope: String, tabID: Int, transport: any BrowserWorkerTransport) {
            self.owner = owner; self.scope = scope; self.tabID = tabID; self.transport = transport
        }
    }

    private var workers: [String: Worker] = [:]
    private var nextTab = 1_000_000
    private var nextRef = 1
    private let maximum: Int
    private let idle: Duration
    private let factory: @MainActor () throws -> any BrowserWorkerTransport
    private let show: @MainActor (Int32) -> Bool
    private let mode: @MainActor () -> ApprovalMode

    init(maximum: Int = 4, idle: Duration = .seconds(240),
         factory: @escaping @MainActor () throws -> any BrowserWorkerTransport = {
             guard let executable = CuaDriverClient.installedExecutable else { throw CuaDriverClientError.notInstalled }
             return CuaDriverClient(executable: executable, cleanupOnStop: true)
         }, mode: @escaping @MainActor () -> ApprovalMode = { ApprovalMode.current() }, show: @escaping @MainActor (Int32) -> Bool = { pid in
             NSRunningApplication(processIdentifier: pid)?.activate(options: []) ?? false
         }) {
        self.maximum = maximum; self.idle = idle; self.factory = factory; self.show = show; self.mode = mode
    }

    static func ownerKey(_ owner: AgentChatOwner) -> String { owner.mateID.uuidString + "/" + owner.chatID.uuidString }

    /// A scope is the native turn capability, not an argument supplied by a model.
    func perform(arguments: [String: Any], owner: String, scope: String,
                 approve: @escaping (String, Bool) async -> Bool) async -> (text: String, isError: Bool) {
        guard !Task.isCancelled else { return ("Browser turn cancelled.", true) }
        let operation = (arguments["op"] as? String ?? "").lowercased()
        guard Self.supportedOperations.contains(operation),
              let command = try? BrowserCommand.make(arguments).get() else {
            return ("Isolated browser supports tabs, open, navigate, snapshot, extract, click, type, scroll, wait_for, show, keep, close and end. Use visible page controls instead of keyboard submission. File transfers use signed-in Chrome.", true)
        }
        if case .type(_, _, _, true) = command {
            return ("Use the page's visible submit button so its exact action can be approved.", true)
        }
        let worker: Worker
        if let existing = workers[owner] {
            guard existing.scope == scope else { return ("Previous browser turn is still finishing. Retry after it finishes.", true) }
            worker = existing
        } else {
            if operation == "tabs" { return ("No isolated browser open for this chat. Use open to start one.", false) }
            if operation == "end" { return ("No isolated browser open for this chat.", false) }
            guard operation == "open" else { return ("Open a page in this chat's isolated browser first.", true) }
            guard workers.count < maximum else { return ("All \(maximum) isolated browsers are in use. Finish one browser task, then retry.", true) }
            do {
                nextTab += 1
                worker = Worker(owner: owner, scope: scope, tabID: nextTab, transport: try factory())
                workers[owner] = worker
            } catch { return (error.localizedDescription, true) }
        }
        worker.expiry?.cancel()
        let activity = UUID()
        worker.activity = activity
        let previous = worker.tail
        let work = Task { @MainActor in
            await previous?.value
            guard worker.valid, worker.scope == scope, !Task.isCancelled else { return (text: "Browser turn expired.", isError: true) }
            do {
                let result = try await self.run(command, worker: worker, approve: approve)
                return (text: result, isError: false)
            } catch let error as Rejected {
                if !worker.ready { self.retire(worker, interrupt: true) }
                return (text: error.localizedDescription, isError: true)
            } catch {
                // Unknown action outcomes must not leave a reusable live driver.
                self.retire(worker, interrupt: true)
                return (text: "Isolated browser stopped: " + error.localizedDescription + ". Verify any external outcome before retrying.", isError: true)
            }
        }
        worker.tail = Task { _ = await work.value }
        return await withTaskCancellationHandler {
            let result = await work.value
            if worker.valid, worker.activity == activity { scheduleExpiry(worker) }
            return result
        } onCancel: {
            work.cancel()
            Task { @MainActor in self.retire(worker, interrupt: true) }
        }
    }

    /// Rebind kept pages only when the next native turn starts. Old turn cleanup
    /// cannot close a replacement worker or revoke a different mate's grant.
    func beginTurn(owner: String, scope: String) {
        guard let worker = workers[owner], worker.scope.isEmpty else { return }
        worker.scope = scope; worker.kept = false
        worker.grantedUntil = nil; worker.refs = [:]; worker.elements = [:]
    }

    func finishTurn(owner: String, scope: String, cancelled: Bool) {
        guard let worker = workers[owner], worker.scope == scope else { return }
        if cancelled || !worker.kept { retire(worker, interrupt: cancelled) }
        else { worker.scope = ""; worker.grantedUntil = nil; scheduleExpiry(worker) }
    }

    func stopAll() {
        for worker in Array(workers.values) { retire(worker, interrupt: true) }
    }

    private func check(_ worker: Worker) throws {
        try Task.checkCancellation()
        guard worker.valid else { throw CancellationError() }
    }

    private func prepare(_ worker: Worker) async throws {
        guard !worker.ready else { return }
        try check(worker)
        try await worker.transport.start()
        let prepared = try await worker.transport.call("browser_prepare", ["session": worker.session, "allow_launch": true, "profile": ["mode": "isolated_new"]])
        try check(worker)
        guard prepared["prepared"] as? Bool == true,
              let pid = prepared["prepared_pid"] as? Int,
              (prepared["side_effects"] as? [String: Any])?["copied_profile_data"] as? Bool == false else {
            throw CuaDriverClientError.malformed("an unverified isolated browser")
        }
        worker.pid = Int32(pid)
        // Window creation can precede CDP readiness. Retry reads only, never
        // launch again or attach a different process on an ambiguous match.
        var lastError: Error = CuaDriverClientError.malformed("no owned browser window")
        for _ in 0..<12 {
            try check(worker)
            let listing = try await worker.transport.call("list_windows", ["pid": pid])
            let windows = (listing["windows"] as? [[String: Any]] ?? []).filter { $0["pid"] as? Int == pid }
            if windows.count == 1, let windowID = windows[0]["window_id"] as? Int {
                do {
                    let bound = try await worker.transport.call("get_browser_state", ["session": worker.session, "pid": pid, "window_id": windowID])
                    guard bound["binding_quality"] as? String == "exact",
                          let targetID = bound["target_id"] as? String,
                          let tabID = (bound["tabs"] as? [[String: Any]])?.first?["tab_id"] as? String else {
                        throw CuaDriverClientError.malformed("an inexact browser binding")
                    }
                    worker.target = ["session": worker.session, "target_id": targetID, "tab_id": tabID]
                    worker.ready = true
                    return
                } catch { lastError = error }
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw lastError
    }

    private func run(_ command: BrowserCommand, worker: Worker,
                     approve: (String, Bool) async -> Bool) async throws -> String {
        try check(worker)
        if let tab = command.tabID, tab != worker.tabID { throw Rejected("That tab does not belong to this chat's isolated browser.") }
        let element: BrowserElement?
        switch command {
        case .click(_, let ref), .type(_, let ref, _, _):
            guard worker.refs[ref] != nil else { throw Rejected("Stale or foreign element ref. Snapshot this chat's page again.") }
            element = worker.elements[ref]
            if case .type = command, element?.editable != true { throw Rejected("This control is not an editable field.") }
        default: element = nil
        }
        let grant = worker.grantedUntil.map { $0 > Date() } ?? false
        switch BrowserApproval.decide(command, element: element, mode: mode(), hasGrant: grant) {
        case .allow: break
        case .refuse(let reason): throw Rejected(reason)
        case .askOnce:
            guard await approve("Use this chat's separate Chrome profile (no personal Chrome sign-ins are copied)", false) else { throw Rejected("Browser access declined.") }
            try check(worker)
            worker.grantedUntil = Date().addingTimeInterval(BrowserBridge.grantSeconds)
        case .askEveryTime(let summary):
            guard await approve(summary, true) else { throw Rejected("Browser step declined.") }
            try check(worker)
        }
        if command == .end || { if case .close = command { return true }; return false }() {
            let ended = try await worker.transport.call("end_session", ["session": worker.session])
            guard ended["active"] as? Bool == false else { throw CuaDriverClientError.malformed("unconfirmed session cleanup") }
            retire(worker, interrupt: true)
            return "Ended this chat's isolated browser and removed its temporary profile."
        }
        try await prepare(worker)
        try check(worker)
        var fields = worker.target
        switch command {
        case .tabs:
            return "Isolated tab \(worker.tabID) belongs only to this chat. Snapshot it to read its current page."
        case .open(let url), .navigate(_, let url):
            worker.refs = [:]; worker.elements = [:]
            fields["url"] = url.absoluteString
            _ = try await worker.transport.call("browser_navigate", fields)
        case .click(_, let ref):
            fields["ref"] = worker.refs[ref]
            _ = try await worker.transport.call("browser_click", fields)
        case .type(_, let ref, let text, _):
            fields["ref"] = worker.refs[ref]; fields["text"] = text; fields["replace"] = true
            _ = try await worker.transport.call("browser_type", fields)
        case .scroll(_, let up):
            fields.merge(["action": "scroll", "x": 100, "y": 250, "delta_y": up ? -500 : 500]) { _, new in new }
            _ = try await worker.transport.call("browser_pointer", fields)
        case .waitFor(_, let text, let url):
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            repeat {
                let page = try await snapshot(worker)
                if (text == nil || (page["text"] as? String ?? "").contains(text!)),
                   (url == nil || (page["url"] as? String ?? "").contains(url!)) { return format(page, worker: worker) }
                try await Task.sleep(for: .milliseconds(250))
            } while ContinuousClock.now < deadline
            throw Rejected("Timed out waiting for expected page. Snapshot once to inspect it.")
        case .show:
            guard let pid = worker.pid, show(pid) else { throw Rejected("Owned browser window is no longer available.") }
            return "Showing this chat's isolated Chrome window."
        case .keep:
            worker.kept = true
            return "Page kept for this chat. Temporary profile expires after four minutes without browser activity; sign-ins disappear when it closes."
        case .snapshot, .extract: break
        default: throw CuaDriverClientError.malformed("an unsupported browser command")
        }
        try check(worker)
        return format(try await snapshot(worker), worker: worker)
    }

    private func snapshot(_ worker: Worker) async throws -> [String: Any] {
        try check(worker)
        var fields = worker.target
        fields["snapshot_format"] = "semantic_v2"
        fields["include_screenshot"] = false
        let page = try await worker.transport.call("get_browser_state", fields)
        try check(worker)
        worker.refs = [:]; worker.elements = [:]
        var elements: [[String: Any]] = []
        for ref in page["refs"] as? [[String: Any]] ?? [] {
            guard let raw = ref["ref"] as? String else { continue }
            let id = nextRef; nextRef += 1
            let name = String((ref["name"] as? String ?? "Unlabelled control").prefix(240))
            let role = ref["role"] as? String ?? ""
            let editable = (ref["actions"] as? [String] ?? []).contains("type")
            let secret = ["password", "passcode", "secret", "card number", "security code", "one-time", "verification code", "credit card", "cvv", "cvc"].contains { name.lowercased().contains($0) }
            worker.refs[id] = raw
            worker.elements[id] = BrowserElement(ref: id, role: role, name: name, secret: secret, editable: editable)
            elements.append(["ref": id, "role": role, "name": name, "secret": secret, "editable": editable])
        }
        let metadata = page["page"] as? [String: Any] ?? [:]
        return ["tabId": worker.tabID, "title": metadata["title"] as? String ?? "", "url": metadata["url"] as? String ?? "",
                "text": String((page["outline"] as? String ?? "").prefix(12_000)), "elements": elements,
                "note": "Separate temporary profile; refs expire on each snapshot. One page per chat: open navigates this same page. Extract reads the current viewport; scroll to read more."]
    }

    private func format(_ page: [String: Any], worker: Worker) -> String {
        "Isolated tab \(worker.tabID) for this chat.\n" + BrowserResultText.format(["result": page])
    }

    private func scheduleExpiry(_ worker: Worker) {
        worker.expiry?.cancel()
        worker.expiry = Task { [weak self, weak worker] in
            guard let self, let worker else { return }
            do { try await Task.sleep(for: self.idle) } catch { return }
            self.retire(worker, interrupt: true)
        }
    }

    private func retire(_ worker: Worker, interrupt: Bool) {
        guard worker.valid else { return }
        worker.valid = false; worker.expiry?.cancel()
        if workers[worker.owner] === worker { workers[worker.owner] = nil }
        if interrupt { worker.transport.stop() }
        else {
            Task {
                _ = try? await worker.transport.call("end_session", ["session": worker.session])
                worker.transport.stop()
            }
        }
    }
}
