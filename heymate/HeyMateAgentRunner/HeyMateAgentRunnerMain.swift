//
//  HeyMateAgentRunnerMain.swift
//  HeyMateAgentRunner
//
//  Command-line-only entrypoint. No AppKit, SwiftUI, LaunchServices, or
//  updater lifecycle is constructed in this process.
//
//  Chrome also starts this helper as HeyMate's native-messaging host, with
//  the extension origin as its first argument. In that mode it only relays
//  messages between Chrome and the running app; see BrowserNativeHost.
//

import Darwin
import Foundation

@main
nonisolated enum HeyMateAgentRunnerMain {
    static func main() {
        if CommandLine.arguments.dropFirst().first?.hasPrefix("chrome-extension://") == true {
            BrowserNativeHost.run()
        }
        guard let invocation = DetachedAgentRunnerInvocation() else {
            let message = "Invalid HeyMateAgentRunner invocation.\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            Darwin.exit(EX_USAGE)
        }
        DetachedAgentRunnerProgram.run(invocation: invocation)
    }
}

/// Relays Chrome's native-messaging port (4-byte little-endian length, then
/// JSON, on stdin/stdout) to the app's local socket (one JSON line each
/// way, wrapped as {"message": …}). It opens no pages and runs nothing.
nonisolated enum BrowserNativeHost {
    static let maximumMessage = 1_000_000

    static func run() -> Never {
        let socketPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("heymate/browser-bridge.sock").path
        guard let fd = connect(to: socketPath) else {
            // HeyMate isn't running: answer the hello so the extension knows.
            if let hello = readNative(), hello["type"] as? String == "hello" {
                writeNative(["type": "ready", "selected": false, "reason": "app-not-running"])
            }
            exit(0)
        }

        let pump = Thread {
            while let message = readNative() {
                guard let data = try? JSONSerialization.data(withJSONObject: ["from": "extension", "message": message]),
                      writeAll(fd, data + Data([10])) else { break }
            }
            shutdown(fd, SHUT_RDWR)
        }
        pump.start()

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            buffer.append(chunk, count: count)
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let envelope = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let message = envelope["message"] as? [String: Any] else { continue }
                writeNative(message)
            }
            if buffer.count > maximumMessage { break }
        }
        exit(0)
    }

    private static func connect(to path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { destination in
                for index in bytes.indices { destination[index] = bytes[index] }
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { close(fd); return nil }
        return fd
    }

    private static func readNative() -> [String: Any]? {
        guard let header = readExactly(4) else { return nil }
        let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length > 0, length <= maximumMessage, let body = readExactly(length) else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private static func readExactly(_ count: Int) -> Data? {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: min(count, 65_536))
        while data.count < count {
            let got = read(STDIN_FILENO, &chunk, min(chunk.count, count - data.count))
            if got <= 0 { return nil }
            data.append(chunk, count: got)
        }
        return data
    }

    private static let outputLock = NSLock()

    private static func writeNative(_ message: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: message), body.count <= maximumMessage else { return }
        var length = UInt32(body.count).littleEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        outputLock.lock()
        defer { outputLock.unlock() }
        _ = writeAll(STDOUT_FILENO, header + body)
    }

    @discardableResult
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }
}
