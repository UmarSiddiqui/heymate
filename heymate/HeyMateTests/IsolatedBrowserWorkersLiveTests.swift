import AppKit
import Foundation
import Testing
@testable import HeyMate

/// Opt-in: production pool and MCP client, real Cua and disposable Chrome
/// profiles, loopback pages only. No HeyMate GUI, user profile or screenshots.
@MainActor
struct IsolatedBrowserWorkersLiveTests {
    private final class Driver: BrowserWorkerTransport {
        let client = CuaDriverClient(executable: URL(fileURLWithPath: "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"), cleanupOnStop: true)
        var pid: Int32?
        var session: String?
        var profile: String?
        func start() async throws { try await client.start() }
        func stop() { client.stop() }
        func call(_ tool: String, _ arguments: [String: Any]) async throws -> [String: Any] {
            let value = try await client.call(tool, arguments)
            if tool == "browser_prepare" {
                pid = (value["prepared_pid"] as? Int).map(Int32.init)
                session = arguments["session"] as? String
                if let pid {
                    let ps = Process(), pipe = Pipe()
                    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
                    ps.arguments = ["-p", String(pid), "-o", "command="]
                    ps.standardOutput = pipe
                    try ps.run()
                    let command = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    ps.waitUntilExit()
                    if let range = command.range(of: "--user-data-dir=") {
                        profile = String(command[range.upperBound...].prefix(while: { !$0.isNewline }).components(separatedBy: " --")[0]).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            return value
        }
    }
    private func tab(_ text: String) -> Int {
        Int(text.components(separatedBy: "Isolated tab ").last?.prefix(while: { $0.isNumber }) ?? "") ?? 0
    }
    private func ref(_ text: String, name: String) -> Int {
        let line = text.components(separatedBy: "\n").first { $0.contains("“\(name)”") } ?? ""
        return Int(line.dropFirst().prefix(while: { $0.isNumber })) ?? 0
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEYMATE_BROWSER_LIVE"] == "1"))
    func realProfilesHaveSeparateCookiesStorageAndIndependentLifetimes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heymate-browser-live-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", try #require(ProcessInfo.processInfo.environment["HEYMATE_BROWSER_FIXTURE"]), root.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate() } }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("port").path) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let port = try String(contentsOf: root.appendingPathComponent("port"), encoding: .utf8)
        let url = "http://127.0.0.1:\(port)/fixture"
        let a = Driver(), b = Driver(); var made = 0
        let pool = IsolatedBrowserWorkers(factory: { made += 1; return made == 1 ? a : b }, mode: { .fullAccess })
        defer { pool.stopAll() }
        async let pendingA = pool.perform(arguments: ["op": "open", "url": url + "?owner=A&seed=A"], owner: "mate-a/chat-a", scope: "turn", approve: { _, _ in true })
        async let pendingB = pool.perform(arguments: ["op": "open", "url": url + "?owner=B"], owner: "mate-b/chat-b", scope: "turn", approve: { _, _ in true })
        let (pageA, pageB) = await (pendingA, pendingB)
        try #require(!pageA.isError, Comment(rawValue: pageA.text))
        try #require(!pageB.isError, Comment(rawValue: pageB.text))
        try #require(a.pid != nil && b.pid != nil && a.pid != b.pid)
        try #require(a.session != b.session)
        try #require(tab(pageA.text) != tab(pageB.text))
        for driver in [a, b] {
            let profile = try #require(driver.profile)
            try #require(profile.contains("/CuaDriver/BrowserProfiles/isolated-"))
            try #require(FileManager.default.fileExists(atPath: profile))
        }
        func events() -> [[String: String]] {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("events.json")) else { return [] }
            return (try? JSONDecoder().decode([[String: String]].self, from: data)) ?? []
        }
        for _ in 0..<100 {
            if events().contains(where: { $0["owner"] == "B" && $0["storage"] != nil }) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(events().contains { $0["owner"] == "A" && $0["cookie"] == "worker=A" && $0["storage"] == "A" })
        try #require(events().contains { $0["owner"] == "B" && $0["cookie"] == "empty" && $0["storage"] == "empty" })
        let foreign = await pool.perform(arguments: ["op": "snapshot", "tab_id": tab(pageA.text)], owner: "mate-b/chat-b", scope: "turn") { _, _ in true }
        try #require(foreign.isError)
        let typed = await pool.perform(arguments: ["op": "type", "tab_id": tab(pageB.text), "ref": ref(pageB.text, name: "Benchmark name"), "text": "Worker B only"], owner: "mate-b/chat-b", scope: "turn") { _, _ in true }
        try #require(!typed.isError, Comment(rawValue: typed.text))
        let saved = await pool.perform(arguments: ["op": "click", "tab_id": tab(pageB.text), "ref": ref(typed.text, name: "Save fixture")], owner: "mate-b/chat-b", scope: "turn") { _, _ in true }
        try #require(!saved.isError, Comment(rawValue: saved.text))
        for _ in 0..<100 {
            if events().contains(where: { $0["saved"] != nil }) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(events().contains { $0["owner"] == "B" && $0["saved"] == "Worker B only" })
        let slow = Task { await pool.perform(arguments: ["op": "navigate", "tab_id": tab(pageA.text), "url": "http://127.0.0.1:\(port)/slow"], owner: "mate-a/chat-a", scope: "turn") { _, _ in true } }
        for _ in 0..<100 {
            if events().contains(where: { $0["navigation_started"] == "yes" }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(events().contains { $0["navigation_started"] == "yes" })
        slow.cancel()
        try #require(await slow.value.isError)
        pool.finishTurn(owner: "mate-a/chat-a", scope: "turn", cancelled: true)
        for _ in 0..<100 {
            if NSRunningApplication(processIdentifier: a.pid!) == nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(NSRunningApplication(processIdentifier: a.pid!) == nil)
        let alive = await pool.perform(arguments: ["op": "snapshot", "tab_id": tab(pageB.text)], owner: "mate-b/chat-b", scope: "turn") { _, _ in true }
        try #require(!alive.isError)
        let ended = await pool.perform(arguments: ["op": "end"], owner: "mate-b/chat-b", scope: "turn") { _, _ in true }
        try #require(!ended.isError)
        for _ in 0..<100 {
            if NSRunningApplication(processIdentifier: b.pid!) == nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(NSRunningApplication(processIdentifier: b.pid!) == nil)
        // Profiles must be positively discovered from our own launched PIDs.
        for driver in [a, b] {
            let profile = try #require(driver.profile)
            try #require(!FileManager.default.fileExists(atPath: profile))
        }
        try await Task.sleep(for: .milliseconds(2200))
        try #require(!events().contains { $0["late_effect"] == "yes" })
    }
}
