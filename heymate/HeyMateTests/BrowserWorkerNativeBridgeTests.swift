import Darwin
import Foundation
import Testing
@testable import HeyMate

/// Production app bridge and Unix socket, synthetic native host only. The
/// standalone runner supplies a disposable data root, never the app's socket.
@MainActor
struct BrowserWorkerNativeBridgeTests {
    private nonisolated final class Host: @unchecked Sendable {
        let fd: Int32
        let lock = NSLock()
        var messages: [[String: Any]] = []
        init(path: String) throws {
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8CString)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw CocoaError(.fileReadInvalidFileName) }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { target in
                    for i in bytes.indices { target[i] = bytes[i] }
                }
            }
            let status = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard status == 0 else { close(fd); throw CocoaError(.fileReadUnknown) }
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            Thread { [self] in
                var buffer = Data(), bytes = [UInt8](repeating: 0, count: 8192)
                while true {
                    let count = Darwin.read(fd, &bytes, bytes.count)
                    guard count > 0 else { break }
                    buffer.append(bytes, count: count)
                    while let newline = buffer.firstIndex(of: 10) {
                        let data = Data(buffer.prefix(upTo: newline)); buffer.removeSubrange(...newline)
                        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let message = object["message"] as? [String: Any] else { continue }
                        lock.lock(); messages.append(message); lock.unlock()
                        if message["type"] as? String == "command", message["op"] as? String != "wait_for" { reply(to: message) }
                    }
                }
            }.start()
        }
        func stop() { shutdown(fd, SHUT_RDWR); close(fd) }
        func observed() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return messages }
        func send(_ message: [String: Any]) {
            let data = (try? JSONSerialization.data(withJSONObject: ["message": message])) ?? Data()
            _ = (data + Data([10])).withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }
        func reply(to message: [String: Any]) {
            send(["type": "result", "id": message["id"]!, "ok": true,
                  "result": ["tabId": message["owner"] as? String == "a" ? 10 : 20,
                             "title": "Fixture", "url": "https://fixture.test", "text": "Fixture",
                             "elements": [["ref": 1, "role": "button", "name": "Send"]]]])
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HEYMATE_NATIVE_BROWSER_TEST"] == "1"))
    func realNativeBridgeScopesGrantsCancellationAndProtocol() async throws {
        let bridge = BrowserBridge.shared
        bridge.start()
        let path = HeyMateDataDirectory.url.appendingPathComponent("browser-bridge.sock").path
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let host = try Host(path: path)
        defer { host.stop() }
        host.send(["type": "hello", "protocol": 4, "version": "fixture"])
        for _ in 0..<100 { if bridge.isConnected { break }; try await Task.sleep(for: .milliseconds(10)) }
        try #require(bridge.isConnected)
        var ordinary: [String] = [], floor: [String] = []
        func perform(_ op: String, _ owner: String, _ fields: [String: Any] = [:]) async -> (text: String, isError: Bool) {
            var arguments = fields; arguments["op"] = op
            return await bridge.perform(arguments: arguments, owner: owner, scope: owner + "1", groupTitle: "HeyMate · " + owner, isActive: { true }) { _, every in
                if every { floor.append(owner) } else { ordinary.append(owner) }
                return true
            }
        }
        try #require(!(await perform("open", "a", ["url": "https://fixture.test"])).isError)
        try #require(!(await perform("open", "a", ["url": "https://fixture.test/next"])).isError)
        try #require(!(await perform("open", "b", ["url": "https://fixture.test"])).isError)
        try #require(ordinary == ["a", "b"])
        try #require(!(await perform("click", "a", ["tab_id": 10, "ref": 1])).isError)
        try #require(floor == ["a"])
        let waitA = Task { await perform("wait_for", "a", ["tab_id": 10, "text": "Never"]) }
        let waitB = Task { await perform("wait_for", "b", ["tab_id": 20, "text": "Never"]) }
        for _ in 0..<100 {
            if host.observed().filter({ $0["op"] as? String == "wait_for" }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        waitA.cancel()
        try #require(await waitA.value.isError)
        let requestB = try #require(host.observed().first { $0["op"] as? String == "wait_for" && $0["owner"] as? String == "b" })
        host.reply(to: requestB)
        try #require(!(await waitB.value).isError)
        for _ in 0..<100 {
            if host.observed().contains(where: { $0["type"] as? String == "cancel" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let cancel = try #require(host.observed().first { $0["type"] as? String == "cancel" })
        try #require(cancel["owner"] as? String == "a" && cancel["scope"] as? String == "a1")
        try #require(!(await perform("open", "b", ["url": "https://fixture.test"])).isError)
        try #require(ordinary == ["a", "b"])
        host.send(["type": "hello", "protocol": 3, "version": "legacy"])
        for _ in 0..<100 { if bridge.extensionVersion == "legacy" { break }; try await Task.sleep(for: .milliseconds(10)) }
        let legacy = await perform("open", "b", ["url": "https://fixture.test"])
        try #require(legacy.isError && legacy.text.contains("Reload"))
    }
}
