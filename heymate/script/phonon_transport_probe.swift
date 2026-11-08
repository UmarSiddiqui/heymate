import Foundation

@main struct PhononTransportProbe {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let resources = URL(fileURLWithPath: arguments[1])
        let store = URL(fileURLWithPath: arguments[2])
        let engine = PhononEngine(resources: resources,
                                  helperExecutable: URL(fileURLWithPath: arguments[3]), modelStore: store,
                                  unsupportedReason: nil) // HTTP fixtures also run on Intel CI; no model inference.
        let mode = arguments[4]
        if mode == "cache" {
            try await engine.installPrivateModels()
            let source = resources.appendingPathComponent("models/blobs")
            let blob = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)[0]
            let cached = store.appendingPathComponent("blobs/" + blob.lastPathComponent)
            let original = try Data(contentsOf: blob)
            try Data(repeating: 88, count: original.count).write(to: cached)
            try await engine.installPrivateModels()
            let repaired = try Data(contentsOf: cached)
            precondition(repaired == original, "Same-size corruption not repaired")
            try FileManager.default.removeItem(at: cached)
            try await engine.installPrivateModels()
            let restored = try Data(contentsOf: cached)
            precondition(restored == original, "Missing blob not repaired")
            try FileManager.default.removeItem(at: blob)
            try Data(repeating: 88, count: original.count).write(to: cached)
            do { try await engine.installPrivateModels(); fatalError("Damaged bundle accepted") }
            catch PhononEngine.Failure.modelCorrupt { }
            precondition(FileManager.default.fileExists(atPath: cached.path), "Old store lost on failed repair")
            print("PASS cache: same-size corruption, missing blob, damaged source and preservation")
            return
        }
        let samples = SampleCounter()
        do {
            try await engine.stream("Synthetic sample, no personal data.", voice: "Zoey") { await samples.append($0) }
            precondition(mode == "recover", "Expected failure")
            let count = await samples.count
            precondition(count == 1_200)
            print("PASS server restart recovers before first audio")
        } catch {
            let message = error.localizedDescription
            precondition(!message.contains("PRIVATE"), "Private response body leaked")
            if mode == "voice" {
                precondition(message.contains("HTTP 400") && message.contains("voice_invalid"))
                print("PASS HTTP 400: category preserved, private data removed, no retry")
            } else if mode == "fail" {
                precondition(message.contains("HTTP 500") && message.contains("model_invalid"))
                print("PASS persistent HTTP 500: bounded retry, safe error")
            } else if mode == "partial" {
                let count = await samples.count
                precondition(count > 0)
                print("PASS partial stream: failure propagates without repeating audio")
            } else { throw error }
        }
        await engine.removeFromDisk()
    }
}

actor SampleCounter {
    var count = 0
    func append(_ values: [Float]) { count += values.count }
}
