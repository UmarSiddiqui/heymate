import Darwin
import FluidAudio
import Foundation

/// Core ML can trap below Swift's error boundary. Keep that failure outside
/// the GUI process; the parent can then speak using the system voice.
@main
enum HeyMateSpeechRunnerMain {
    static func main() async {
        _ = setpgid(0, 0)
        signal(SIGPIPE, SIG_IGN)
        AppLogger.mirrorsToConsole = false
        let manager = KokoroAneManager(defaultVoice: "af_heart")
        let server = PhononServer()
        // Ollama creates its own process group. Forward helper termination to
        // that group instead of abandoning the model runner on cancellation.
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termination.setEventHandler { server.stop(); exit(0) }
        termination.resume()
        defer { termination.cancel(); server.stop() }
        var loaded = false
        while let line = readLine() {
            let reply: SpeechRunnerReply
            do {
                guard line.utf8.count <= 262_144 else { throw RunnerError.invalidRequest }
                let request = try JSONDecoder().decode(SpeechRunnerRequest.self, from: Data(line.utf8))
                if request.operation == "servePhonon" {
                    guard let directory = request.modelDirectory, directory.hasPrefix("/") else {
                        throw RunnerError.invalidRequest
                    }
                    let port = try await server.start(models: directory)
                    var bytes = try JSONEncoder().encode(SpeechRunnerReply(port: port, service: server.identity))
                    bytes.append(10)
                    try FileHandle.standardOutput.write(contentsOf: bytes)
                    continue
                }
                guard ["prepare", "synthesize"].contains(request.operation),
                      request.speed.isFinite, (0.5...2).contains(request.speed) else { throw RunnerError.invalidRequest }
                if !loaded {
                    try await manager.initialize()
                    loaded = true
                }
                if request.operation == "synthesize" {
                    let audio = try await manager.synthesizeDetailed(text: request.text, voice: request.voice, speed: request.speed)
                    guard !audio.samples.isEmpty, audio.samples.count <= 24_000 * 120,
                          audio.samples.allSatisfy({ $0.isFinite }), audio.sampleRate == 24_000 else {
                        throw RunnerError.invalidAudio
                    }
                    reply = SpeechRunnerReply(samples: audio.samples.withUnsafeBytes { Data($0) }, sampleRate: audio.sampleRate)
                } else {
                    reply = SpeechRunnerReply()
                }
            } catch {
                reply = SpeechRunnerReply(error: error.localizedDescription)
            }
            do {
                var bytes = try JSONEncoder().encode(reply)
                bytes.append(10)
                try FileHandle.standardOutput.write(contentsOf: bytes)
            } catch { return } // Parent exited; never leave an orphan inference loop.
        }
        await manager.cleanup()
    }

    enum RunnerError: LocalizedError {
        case invalidRequest, invalidAudio
        var errorDescription: String? { "The local voice returned invalid data." }
    }
}

/// Parent stdin is a lifetime lease. GUI exit closes it, then this helper
/// terminates its private server. No system Ollama service is used or changed.
final class PhononServer: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var port: Int?
    var identity: SpeechOwnedProcess? {
        lock.withLock { process.flatMap { SpeechOwnedProcess.snapshot($0.processIdentifier) } }
    }

    func stop() {
        let child = lock.withLock { let child = process; process = nil; return child }
        if let child, child.isRunning {
            child.terminationHandler = nil
            if getpgid(child.processIdentifier) == child.processIdentifier {
                kill(-child.processIdentifier, SIGTERM)
            }
            child.terminate()
            let deadline = Date().addingTimeInterval(2)
            while child.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if child.isRunning {
                if getpgid(child.processIdentifier) == child.processIdentifier { kill(-child.processIdentifier, SIGKILL) }
                kill(child.processIdentifier, SIGKILL)
            }
            child.waitUntilExit()
        }
    }

    func start(models: String) async throws -> Int {
        if let port, lock.withLock({ process?.isRunning == true }) { return port }
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw HeyMateSpeechRunnerMain.RunnerError.invalidRequest }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) }
        }
        close(socketFD)
        guard bound == 0, named == 0 else { throw HeyMateSpeechRunnerMain.RunnerError.invalidRequest }
        let port = Int(UInt16(bigEndian: address.sin_port))
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/PhononRuntime/ollama")
        let child = Process()
        child.executableURL = executable
        child.arguments = ["serve"]
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_HOST"] = "127.0.0.1:\(port)"
        environment["OLLAMA_MODELS"] = models
        environment["OLLAMA_NO_CLOUD"] = "1"
        environment["OLLAMA_NOPRUNE"] = "1"
        environment["OLLAMA_MAX_LOADED_MODELS"] = "1"
        environment["OLLAMA_NUM_PARALLEL"] = "1"
        environment["OLLAMA_KEEP_ALIVE"] = "-1"
        child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.standardError
        child.terminationHandler = { _ in exit(1) }
        try lock.withLock { try child.run(); process = child }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline, child.isRunning {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/version")!)
            request.timeoutInterval = 1
            if let (_, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                self.port = port
                return port
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        stop()
        throw HeyMateSpeechRunnerMain.RunnerError.invalidRequest
    }
}
