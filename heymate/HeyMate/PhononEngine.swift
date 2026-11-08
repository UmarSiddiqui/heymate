import CryptoKit
import Foundation

/// Private Ollama service, owned by the signed speech helper. Inference and
/// its native libraries never run in the GUI process. Requests stay on loopback.
actor PhononEngine {
    static let shared = PhononEngine()
    private let helper: KokoroSpeechProcess
    private let resources: URL
    private let modelStore: URL
    private let platformUnsupportedReason: String?
    private var port: Int?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(resources: URL = PhononEngine.resourceURL, helperExecutable: URL? = nil,
         modelStore: URL = PhononEngine.modelsURL,
         unsupportedReason: String? = PhononEngine.unsupportedReason) {
        self.resources = resources
        self.modelStore = modelStore
        self.platformUnsupportedReason = unsupportedReason
        helper = helperExecutable.map { KokoroSpeechProcess(executable: $0) } ?? KokoroSpeechProcess()
    }

    nonisolated static var unsupportedReason: String? {
        #if arch(arm64)
        nil
        #else
        "On-device voice needs an Apple Silicon Mac."
        #endif
    }

    nonisolated static var resourceURL: URL {
        (Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL
         : URL(fileURLWithPath: "/Applications/HeyMate.app"))
            .appendingPathComponent("Contents/Resources/PhononRuntime")
    }

    nonisolated static var modelsURL: URL {
        HeyMateDataDirectory.url.appendingPathComponent("Phonon/models", isDirectory: true)
    }

    nonisolated static func modelsAreInstalled() -> Bool {
        unsupportedReason == nil && FileManager.default.fileExists(atPath: resourceURL
            .appendingPathComponent("models/manifests/registry.ollama.ai/library/phonon/latest").path)
    }

    func prepare() async throws {
        await enter()
        defer { leave() }
        try Task.checkCancellation()
        _ = try await serverPort()
    }

    func removeFromDisk() async {
        await enter()
        defer { leave() }
        await helper.stop()
        port = nil
        try? FileManager.default.removeItem(at: modelStore)
    }

    /// Audio is signed 16-bit little-endian PCM, mono, 24 kHz. Do not send a
    /// speed field: Ollama's speech API rejects it. Playback handles speed.
    func stream(_ text: String, voice: String,
                onChunk: @Sendable ([Float]) async throws -> Void) async throws {
        await enter()
        defer { leave() }
        try Task.checkCancellation()
        guard !text.isEmpty, text.count <= 4_096 else { throw Failure.invalidText }
        for attempt in 0...1 {
            var receivedAudio = false
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            do {
                let port = try await serverPort()
                try Task.checkCancellation()
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/audio/speech")!)
                request.httpMethod = "POST"
                request.timeoutInterval = 45
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "model": "phonon", "voice": voice, "input": text, "response_format": "pcm"
                ])
                try await withTaskCancellationHandler {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        // Bound the error body and project it into a fixed category.
                        // It may contain private text; neither retain nor log it.
                        var body = [UInt8]()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count == 8_192 { break }
                        }
                        throw Failure.http((response as? HTTPURLResponse)?.statusCode ?? 0,
                                           SpeechFailureCategory.classify(String(decoding: body, as: UTF8.self)))
                    }
                    var chunk = [UInt8]()
                    chunk.reserveCapacity(2_400)
                    var total = 0
                    for try await byte in bytes {
                        chunk.append(byte)
                        total += 1
                        guard total <= 24_000 * 2 * 120 else { throw Failure.invalidAudio }
                        if chunk.count == 2_400 {
                            try Task.checkCancellation()
                            receivedAudio = true
                            try await onChunk(Self.decodePCM(chunk))
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    try Task.checkCancellation()
                    guard total > 0, chunk.count % 2 == 0 else { throw Failure.invalidAudio }
                    if !chunk.isEmpty { receivedAudio = true; try await onChunk(Self.decodePCM(chunk)) }
                } onCancel: {
                    session.invalidateAndCancel()
                }
                return
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                let diagnostic = await helper.failureCategory()
                var reported = error
                if case Failure.http(let status, .unknown) = error, diagnostic != .unknown {
                    reported = Failure.http(status, diagnostic)
                } else if case KokoroSpeechProcess.Failure.interrupted = error, diagnostic != .unknown {
                    reported = Failure.helper(diagnostic)
                }
                // Failed model processes must not leave a cached dead endpoint.
                await helper.stop()
                port = nil
                if attempt == 0, !receivedAudio, let failure = error as? Failure,
                   case .http(let status, _) = failure, (500...599).contains(status) { continue }
                throw reported
            }
        }
    }

    nonisolated static func decodePCM(_ bytes: [UInt8]) -> [Float] {
        stride(from: 0, to: bytes.count - 1, by: 2).map {
            Float(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) / 32_768
        }
    }

    private func serverPort() async throws -> Int {
        if let reason = platformUnsupportedReason { throw Failure.unavailable(reason) }
        if let port, await helper.isRunning() { return port }
        guard FileManager.default.fileExists(atPath: resources
            .appendingPathComponent("models/manifests/registry.ollama.ai/library/phonon/latest").path) else {
            throw Failure.unavailable("The bundled speaking model is missing.")
        }
        try installPrivateModels()
        let reply = try await helper.request(SpeechRunnerRequest(
            operation: "servePhonon", modelDirectory: modelStore.path), timeout: .seconds(40))
        guard let port = reply.port, (1...65_535).contains(port) else { throw Failure.invalidServiceReply }
        self.port = port
        return port
    }

    func installPrivateModels() throws {
        let source = resources.appendingPathComponent("models")
        let relative = "manifests/registry.ollama.ai/library/phonon/latest"
        let manifest = try Data(contentsOf: source.appendingPathComponent(relative))
        let marker = modelStore.appendingPathComponent(".heymate-model-manifest")
        let digest = Data(SHA256.hash(data: manifest))
        if (try? Data(contentsOf: marker)) == digest,
           (try? Data(contentsOf: modelStore.appendingPathComponent(relative))) == manifest,
           Self.validModelBlobs(in: modelStore, manifest: manifest) { return }
        guard Self.validModelBlobs(in: source, manifest: manifest) else { throw Failure.modelCorrupt }
        // The server needs a writable model store. Never let it modify signed resources.
        let staging = modelStore.deletingLastPathComponent().appendingPathComponent("models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: staging)
        try digest.write(to: staging.appendingPathComponent(marker.lastPathComponent), options: .atomic)
        let backup = modelStore.deletingLastPathComponent().appendingPathComponent("models-backup-\(UUID().uuidString)")
        let hadStore = FileManager.default.fileExists(atPath: modelStore.path)
        if hadStore { try FileManager.default.moveItem(at: modelStore, to: backup) }
        do { try FileManager.default.moveItem(at: staging, to: modelStore) }
        catch {
            if hadStore { try? FileManager.default.moveItem(at: backup, to: modelStore) }
            throw error
        }
        if hadStore { try? FileManager.default.removeItem(at: backup) }
    }

    nonisolated private static func validModelBlobs(in root: URL, manifest: Data) -> Bool {
        struct Descriptor: Decodable { let digest: String; let size: Int }
        struct Manifest: Decodable { let config: Descriptor; let layers: [Descriptor] }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: manifest) else { return false }
        for blob in [manifest.config] + manifest.layers {
            let digest = String(blob.digest.dropFirst(7))
            guard blob.digest.hasPrefix("sha256:"), digest.count == 64,
                  digest.allSatisfy({ "0123456789abcdef".contains($0) }), blob.size >= 0 else { return false }
            let file = root.appendingPathComponent("blobs/sha256-" + digest)
            guard let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]),
                  values.isSymbolicLink != true, values.fileSize == blob.size,
                  let stream = try? FileHandle(forReadingFrom: file) else { return false }
            defer { try? stream.close() }
            var hash = SHA256()
            do {
                while let data = try stream.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            } catch { return false }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else { return false }
        }
        return true
    }

    private func enter() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    enum Failure: LocalizedError {
        case invalidText, invalidAudio, invalidServiceReply, modelCorrupt, unavailable(String)
        case http(Int, SpeechFailureCategory)
        case helper(SpeechFailureCategory)
        var errorDescription: String? {
            switch self {
            case .invalidText: "The text is too long for one speech segment."
            case .invalidAudio: "The local voice returned invalid audio."
            case .invalidServiceReply: "The local voice helper returned an invalid service port."
            case .modelCorrupt: "The bundled speaking model is damaged. Reinstall HeyMate to repair it."
            case .http(let status, let category): "The local voice request failed (HTTP \(status), \(category.rawValue))."
            case .helper(let category): "The local voice helper failed (\(category.rawValue))."
            case .unavailable(let reason): reason
            }
        }
    }
}

/// Hold silence at chunk boundaries until it is known to be interior silence.
/// Keeps 30 ms before speech and 170 ms after, without waiting for a full reply.
nonisolated struct PhononSilenceTrimmer: Sendable {
    private var pending = [Float]()
    private var started = false
    mutating func append(_ samples: [Float]) -> [Float] {
        pending.append(contentsOf: samples)
        guard let last = pending.lastIndex(where: { abs($0) > 0.01 }) else {
            if !started, pending.count > 720 { pending = Array(pending.suffix(720)) }
            return []
        }
        let first = started ? 0 : max(0, pending.firstIndex(where: { abs($0) > 0.01 })! - 720)
        let result = Array(pending[first...last])
        pending.removeFirst(last + 1)
        started = true
        return result
    }
    mutating func finish() -> [Float] {
        let result = started ? Array(pending.prefix(4_080)) : []
        pending.removeAll()
        return result
    }
}
