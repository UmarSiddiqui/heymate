import Foundation

@main struct VoiceProcessProbe {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heymate-voice-process-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("worker")
        func install(_ body: String) throws {
            try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        }
        let request = SpeechRunnerRequest(operation: "prepare")
        let worker = KokoroSpeechProcess(executable: script)
        try install("while IFS= read -r line; do printf '%s\\n' '{}'; done\n")
        for _ in 0..<20 { _ = try await worker.request(request, timeout: .seconds(2)) }
        await worker.stop()
        print("PASS persistent worker: 20 sequential requests")

        try install("while IFS= read -r line; do printf '%s\\n' 'out of memory /Users/PRIVATE token PRIVATE' >&2; printf '%s\\n' '{}'; done\n")
        _ = try await worker.request(request, timeout: .seconds(2))
        var category = await worker.failureCategory()
        for _ in 0..<100 where category == .unknown {
            try await Task.sleep(for: .milliseconds(5))
            category = await worker.failureCategory()
        }
        precondition(category == .memory)
        await worker.stop()
        print("PASS stderr is drained into a fixed category without exposing private text")

        try install("read line\nkill -TRAP $$\n")
        do { _ = try await worker.request(request, timeout: .seconds(2)); fatalError("Worker crash was ignored") }
        catch KokoroSpeechProcess.Failure.interrupted { }
        print("PASS native trap contained; parent remains alive")

        try install("while IFS= read -r line; do printf '%s' '{\"sample'; printf '%s\\n' 'Rate\":24000}'; done\n")
        let recovered = try await worker.request(request, timeout: .seconds(2))
        guard recovered.sampleRate == 24_000 else { fatalError("Recovery or fragmented reply failed") }
        await worker.stop()
        print("PASS recovery and fragmented replies")

        try install("while IFS= read -r line; do sleep 5; done\n")
        do { _ = try await worker.request(request, timeout: .milliseconds(100)); fatalError("Timeout was ignored") }
        catch KokoroSpeechProcess.Failure.timedOut { }
        let pending = Task { try await worker.request(request, timeout: .seconds(2)) }
        try await Task.sleep(for: .milliseconds(50))
        pending.cancel()
        do { _ = try await pending.value; fatalError("Cancellation was ignored") }
        catch is CancellationError { }
        print("PASS timeout and cancellation release pending request")

        try install("while IFS= read -r line; do printf '%s\\n' 'invalid-json'; done\n")
        do { _ = try await worker.request(request, timeout: .seconds(2)); fatalError("Malformed reply was accepted") }
        catch KokoroSpeechProcess.Failure.invalidReply { }
        try install("while IFS= read -r line; do printf '%s\\n' '{}'; done\n")
        _ = try await worker.request(request, timeout: .seconds(2))
        await worker.stop()
        print("PASS malformed reply rejection and final recovery")
    }
}
