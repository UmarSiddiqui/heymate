import Foundation
import Testing
@testable import HeyMate

@MainActor
struct CuaDriverClientTests {
    @Test func structuredRefusalIsNotReportedAsSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cua-refusal-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("driver.py")
        try """
        #!/usr/bin/env python3
        import json, sys
        for line in sys.stdin:
            message = json.loads(line)
            if 'id' not in message: continue
            result = {'tools': []} if message['method'] == 'tools/list' else {}
            if message['method'] == 'tools/call':
                result = {'structuredContent': {'effect': 'refused', 'summary': 'stale test reference'}}
            print(json.dumps({'jsonrpc':'2.0','id':message['id'],'result':result}), flush=True)
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = CuaDriverClient(executable: executable)
        defer { client.stop() }
        try await client.start()
        do {
            _ = try await client.call("browser_click", [:])
            Issue.record("structured refusal returned as success")
        } catch let error as CuaDriverClientError {
            #expect(error.localizedDescription == "stale test reference")
        }
    }

    @Test func cancelledCallCannotPerformItsLateEffect() async throws {
        try await assertNoLateEffect(timeout: nil)
    }

    @Test func timedOutCallCannotPerformItsLateEffect() async throws {
        try await assertNoLateEffect(timeout: .seconds(2))
    }

    private func assertNoLateEffect(timeout: Duration?) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cua-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("driver.py")
        try """
        #!/usr/bin/env python3
        import json, sys, time
        from pathlib import Path
        root = Path(__file__).parent
        for line in sys.stdin:
            message = json.loads(line)
            if 'id' not in message: continue
            method = message['method']
            result = {'tools': []} if method == 'tools/list' else {}
            if method == 'tools/call':
                (root/'started').write_text('yes')
                time.sleep(\(timeout == nil ? 0.8 : 3.0))
                (root/'late-effect').write_text('must not happen')
                result = {'structuredContent': {'effect': 'confirmed'}}
            print(json.dumps({'jsonrpc':'2.0','id':message['id'],'result':result}), flush=True)
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = CuaDriverClient(executable: executable, timeout: timeout)
        defer { client.stop() }
        try await client.start()
        let work = Task { try await client.call("click", [:]) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("started").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("started").path))
        if timeout == nil { work.cancel() }
        do {
            _ = try await work.value
            Issue.record("cancelled call returned success")
        } catch is CancellationError {
            // Expected: cancelling the caller must also stop its owned runtime.
            #expect(timeout == nil)
        } catch let error as CuaDriverClientError {
            #expect(timeout != nil)
            #expect(error.localizedDescription.contains("timed out"))
        }
        try await Task.sleep(for: timeout == nil ? .milliseconds(950) : .milliseconds(1200))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("late-effect").path))
    }
}
