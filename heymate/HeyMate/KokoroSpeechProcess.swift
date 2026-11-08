import Foundation
import Darwin

/// A single persistent, signed helper owns Kokoro. EOF, native traps, invalid
/// output and timeouts become ordinary errors instead of taking down HeyMate.
actor KokoroSpeechProcess {
    enum Failure: LocalizedError {
        case unavailable, interrupted, invalidReply, timedOut, synthesis(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The local voice helper is unavailable."
            case .interrupted: return "The local voice helper stopped unexpectedly."
            case .invalidReply: return "The local voice helper returned invalid audio."
            case .timedOut: return "The local voice helper took too long."
            case .synthesis(let message): return message
            }
        }
    }

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var bytes = Data()
    private var pending: (id: UUID, continuation: CheckedContinuation<SpeechRunnerReply, Error>)?
    private var timer: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var diagnosticOutput: FileHandle?
    private var diagnosticReader: Task<Void, Never>?
    private var diagnosticTail = Data()
    private var diagnostic: SpeechFailureCategory = .unknown
    private let executable: URL
    private var ownedService: SpeechOwnedProcess?

    init(executable: URL = (Bundle.main.bundleURL.pathExtension == "app"
        ? Bundle.main.bundleURL : URL(fileURLWithPath: "/Applications/HeyMate.app"))
        .appendingPathComponent("Contents/Helpers/HeyMateSpeechRunner")) {
        self.executable = executable
    }

    func request(_ request: SpeechRunnerRequest, timeout: Duration = .seconds(45)) async throws -> SpeechRunnerReply {
        try Task.checkCancellation()
        guard pending == nil else { throw Failure.unavailable }
        try startIfNeeded()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = (id, continuation)
                timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.stop(requestID: id, error: Failure.timedOut)
                }
                do {
                    var data = try JSONEncoder().encode(request)
                    data.append(10)
                    try input?.write(contentsOf: data)
                } catch {
                    stop(requestID: id, error: error)
                }
            }
        } onCancel: {
            Task { await self.stop(requestID: id, error: CancellationError()) }
        }
    }

    func stop() {
        stop(requestID: nil, error: CancellationError())
    }

    func isRunning() -> Bool { process?.isRunning == true }
    func failureCategory() -> SpeechFailureCategory { diagnostic }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }
        if process != nil { stop(requestID: nil, error: Failure.interrupted) }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure.unavailable }
        let child = Process()
        let incoming = Pipe(), outgoing = Pipe(), errors = Pipe()
        child.executableURL = executable
        child.standardInput = incoming
        child.standardOutput = outgoing
        child.standardError = errors
        diagnostic = .unknown
        diagnosticTail.removeAll()
        diagnosticOutput = errors.fileHandleForReading
        let diagnostics = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(4)) { continuation in
            errors.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                continuation.yield(chunk)
                if chunk.isEmpty { continuation.finish() }
            }
        }
        diagnosticReader = Task { [weak self] in
            for await chunk in diagnostics {
                guard !Task.isCancelled else { return }
                await self?.receiveDiagnostic(chunk, from: child)
            }
        }
        child.terminationHandler = { [weak self] child in
            Task { await self?.terminated(child) }
        }
        process = child
        input = incoming.fileHandleForWriting
        output = outgoing.fileHandleForReading
        bytes.removeAll(keepingCapacity: false)
        let chunks = AsyncStream<Data> { continuation in
            outgoing.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                continuation.yield(chunk)
                if chunk.isEmpty { continuation.finish() }
            }
        }
        reader = Task { [weak self] in
            for await chunk in chunks {
                guard !Task.isCancelled else { return }
                await self?.receive(chunk, from: child)
            }
        }
        do { try child.run() }
        catch { stop(requestID: nil, error: error); throw error }
    }

    private func receive(_ data: Data, from child: Process) {
        guard process === child else { return }
        guard !data.isEmpty else { stop(requestID: nil, error: Failure.interrupted); return }
        bytes.append(data)
        guard bytes.count <= 16 * 1_024 * 1_024 else { stop(requestID: nil, error: Failure.invalidReply); return }
        guard let newline = bytes.firstIndex(of: 10) else { return }
        let line = Data(bytes[..<newline])
        bytes.removeSubrange(...newline)
        guard let pending, bytes.isEmpty,
              let reply = try? JSONDecoder().decode(SpeechRunnerReply.self, from: line) else {
            stop(requestID: nil, error: Failure.invalidReply)
            return
        }
        self.pending = nil
        if let service = reply.service { ownedService = service }
        timer?.cancel()
        timer = nil
        if let error = reply.error { pending.continuation.resume(throwing: Failure.synthesis(error)) }
        else { pending.continuation.resume(returning: reply) }
    }

    private func terminated(_ child: Process) {
        guard process === child else { return }
        stop(requestID: nil, error: Failure.interrupted)
    }

    private func receiveDiagnostic(_ data: Data, from child: Process) {
        guard process === child else { return }
        diagnosticTail.append(data.suffix(8_192))
        diagnosticTail = Data(diagnosticTail.suffix(8_192))
        let category = SpeechFailureCategory.classify(String(decoding: diagnosticTail, as: UTF8.self))
        if category != .unknown { diagnostic = category }
    }

    private func stop(requestID: UUID?, error: Error) {
        if let requestID, pending?.id != requestID { return }
        let child = process
        process = nil
        let service = ownedService
        ownedService = nil
        service?.terminate(executable: executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/PhononRuntime/ollama"))
        output?.readabilityHandler = nil
        diagnosticOutput?.readabilityHandler = nil
        try? diagnosticOutput?.close()
        diagnosticOutput = nil
        diagnosticReader?.cancel()
        diagnosticReader = nil
        diagnosticTail.removeAll()
        try? input?.close()
        try? output?.close()
        input = nil
        output = nil
        bytes.removeAll(keepingCapacity: false)
        timer?.cancel()
        timer = nil
        reader?.cancel()
        reader = nil
        let waiter = pending
        pending = nil
        if let child, child.isRunning {
            // The helper owns a process group, including Ollama's MLX runner.
            // Closing stdin handles normal parent exit; this handles cancellation.
            kill(-child.processIdentifier, SIGTERM)
            child.terminate()
        }
        waiter?.continuation.resume(throwing: error)
    }
}
