import Foundation
import Security

/// Owns one persistent, loopback-only MateAgent serve process. It never attaches
/// to a discovered/shared backend or sends a model request during startup.
@MainActor
final class MateAgentServeBackend {
    static let shared = MateAgentServeBackend()

    nonisolated enum Failure: Error, LocalizedError, Equatable {
        case invalidConfiguration, alreadyRunningDifferentProfile, startupTimedOut, processExited
        case invalidReadiness, authenticationFailed, identityMismatch, homeMismatch, versionMismatch
        case invalidResponse, notRunning, unsupportedRuntime
        case httpStatus(Int)
        var errorDescription: String? {
            switch self {
            case .invalidConfiguration: return "HeyMate Agent serve needs a trusted executable and an existing isolated profile."
            case .alreadyRunningDifferentProfile: return "Another HeyMate agent profile is already owned by this backend. Stop it before changing profiles."
            case .startupTimedOut: return "HeyMate Agent serve did not become ready within the startup time limit. Check the prepared isolated profile."
            case .processExited: return "The owned HeyMate Agent serve process stopped. No other backend was attached."
            case .invalidReadiness: return "HeyMate Agent serve returned an invalid loopback readiness announcement."
            case .authenticationFailed: return "HeyMate Agent serve rejected this owner's fresh session token."
            case .identityMismatch: return "The listener did not identify itself as this owned HeyMate Agent serve process."
            case .homeMismatch: return "HeyMate Agent serve is using a different profile home. The owned process was stopped."
            case .versionMismatch: return "HeyMate Agent serve did not report the expected supported version."
            case .invalidResponse: return "HeyMate Agent serve returned an invalid readiness or status response."
            case .unsupportedRuntime: return "This HeyMate agent profile selects a nested agent runtime. Choose HeyMate Agent native runtime before using it in HeyMate."
            case .notRunning: return "Start and verify the owned HeyMate Agent serve backend before opening a session."
            case .httpStatus(let status): return "The owned MateAgent backend rejected the HTTP request (status \(status))."
            }
        }
    }
    struct Identity: Equatable {
        let pid: Int32
        let port: Int
        let home: URL
        let version: String
        let commit: String?
        let protocolVersion: Int
    }
    private let processFactory: @MainActor () -> HeadlessCLIProcess
    private var process: HeadlessCLIProcess?
    private var configuration: MateAgentEngineLaunchConfiguration?
    private var startTask: Task<Identity, Error>?
    private var readiness: CheckedContinuation<Int, Error>?
    private var readinessTimeout: Task<Void, Never>?
    private var token: String?
    private var http: URLSession?
    private var directory: URL?
    private var stopped = false
    private var generation = UUID()
    private(set) var identity: Identity?
    private var sockets: [UUID: MateAgentServeWebSocket] = [:]
    var onStopped: (() -> Void)?

    init(processFactory: @escaping @MainActor () -> HeadlessCLIProcess = { HeadlessCLIProcess() }) {
        self.processFactory = processFactory
    }

    isolated deinit {
        readinessTimeout?.cancel()
        startTask?.cancel()
        sockets.values.forEach { $0.close() }
        process?.terminateThenKill()
        http?.invalidateAndCancel()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func start(configuration launch: MateAgentEngineLaunchConfiguration, expectedVersion: String? = nil,
               expectedCommit: String? = nil, timeout: Duration = .seconds(60)) async throws -> Identity {
        try Task.checkCancellation()
        let expectedCommit = expectedCommit ?? launch.expectedCommit
        // Revalidate the public launch value at the ownership boundary, including
        // launchers that override HEYMATE_AGENT_HOME. Attestation is not a substitute
        // for rejecting a known isolation override before it can start.
        _ = try MateAgentEngineConfiguration(executablePath: launch.executableURL.path,
            profilePath: launch.profileDirectoryURL.path).resolveLaunchConfiguration(
                loginPATH: { launch.environment["PATH"] ?? "" })
        guard timeout > .zero, timeout <= .seconds(120), launch.executableURL.isFileURL,
              launch.profileDirectoryURL.isFileURL,
              FileManager.default.isExecutableFile(atPath: launch.executableURL.path),
              FileManager.default.fileExists(atPath: launch.profileDirectoryURL.path),
              launch.profileDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
                != FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi").resolvingSymlinksInPath().standardizedFileURL else {
            throw Failure.invalidConfiguration
        }
        if stopped, process?.isProcessRunning == true { throw Failure.notRunning }
        if let configuration, configuration != launch { throw Failure.alreadyRunningDifferentProfile }
        if let identity, process?.isProcessRunning == true {
            if let expectedVersion, expectedVersion != identity.version { throw Failure.versionMismatch }
            if let expectedCommit, expectedCommit != identity.commit { throw Failure.versionMismatch }
            try await verifyMateAgentRuntime()
            return identity
        }
        if let startTask {
            let result = try await Self.awaitLeavingOnCancel(startTask)
            try Task.checkCancellation()
            if let expectedVersion, expectedVersion != result.version { throw Failure.versionMismatch }
            if let expectedCommit, expectedCommit != result.commit { throw Failure.versionMismatch }
            try await verifyMateAgentRuntime()
            return result
        }
        self.configuration = launch
        generation = UUID()
        stopped = false
        // Startup belongs to the shared backend, not the first chat that
        // happened to request it, so the task cleans up after itself.
        // Cancelling that chat must not stop other chats waiting for the
        // same process.
        let task = Task {
            do {
                let identity = try await self.launchAndVerify(launch, expectedVersion: expectedVersion, expectedCommit: expectedCommit, timeout: timeout)
                self.startTask = nil
                return identity
            } catch {
                self.startTask = nil
                self.stop()
                throw error
            }
        }
        startTask = task
        let result = try await Self.awaitLeavingOnCancel(task)
        try Task.checkCancellation()
        return result
    }

    /// Waits for shared startup, but a cancelled caller stops waiting at
    /// once with `CancellationError`. Startup keeps going for the others.
    private static func awaitLeavingOnCancel(_ task: Task<Identity, Error>) async throws -> Identity {
        let gate = StartupWaitGate<Identity>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                Task { gate.resume(with: await task.result) }
            }
        } onCancel: {
            gate.resume(with: .failure(CancellationError()))
        }
    }

    private func launchAndVerify(_ launch: MateAgentEngineLaunchConfiguration, expectedVersion: String?, expectedCommit: String?, timeout: Duration) async throws -> Identity {
        let ownedGeneration = generation
        let token = try Self.freshToken()
        self.token = token
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("heymate-pi-sessions-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        directory = work
        let child = processFactory()
        process = child
        var environment = launch.environment
        environment["HEYMATE_AGENT_HOME"] = launch.profileDirectoryURL.resolvingSymlinksInPath().path
        environment["PYTHONPYCACHEPREFIX"] = launch.profileDirectoryURL
            .appendingPathComponent("cache/heymate-python", isDirectory: true).path
        environment["HEYMATE_AGENT_DASHBOARD_SESSION_TOKEN"] = token
        environment["HEYMATE_AGENT_DISABLE_LAZY_INSTALLS"] = "1"
        environment["HEYMATE_AGENT_DESKTOP"] = "1"
        let port = try await withCheckedThrowingContinuation { continuation in
            readiness = continuation
            readinessTimeout = Task { [weak self] in
                do { try await ContinuousClock().sleep(for: timeout) } catch { return }
                self?.finishReadiness(.failure(Failure.startupTimedOut))
            }
            do {
                try child.start(executableURL: launch.executableURL,
                    arguments: ["serve", "--isolated", "--host", "127.0.0.1", "--port", "0", "--no-open"],
                    currentDirectoryURL: work, environmentKeysToRemove: HeadlessExecutor.codex.environmentKeysToRemove,
                    environmentOverrides: environment,
                    onLine: { [weak self] line in
                        guard let self, self.generation == ownedGeneration else { return }
                        self.receiveReadiness(line)
                    },
                    onExit: { [weak self] _ in
                        guard let self, self.generation == ownedGeneration else { return }
                        self.processDidExit()
                    })
            } catch { finishReadiness(.failure(error)) }
        }
        try Task.checkCancellation()
        guard !stopped, child.isProcessRunning else { throw Failure.processExited }
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 5
        settings.timeoutIntervalForResource = 30
        settings.connectionProxyDictionary = [:]
        settings.httpCookieStorage = nil
        settings.urlCache = nil
        let http = URLSession(configuration: settings, delegate: MateAgentServeNoRedirectDelegate(), delegateQueue: nil)
        self.http = http
        let root = URL(string: "http://127.0.0.1:\(port)")!
        let proof = try await fetch(root.appendingPathComponent("api/host/identity"), session: http, token: token)
        guard proof["ok"] == .bool(true), proof["protocolVersion"] == .number(1),
              proof["pid"] == .number(Double(child.processIdentifier)), proof["servesSpa"] == .bool(false),
              case .string(let role) = proof["role"], ["serve", "desktop-serve"].contains(role) else {
            throw Failure.identityMismatch
        }
        let health = try await fetch(root.appendingPathComponent("api/health"), session: http, token: token)
        guard health["ok"] == .bool(true) else { throw Failure.invalidResponse }
        let status = try await fetch(root.appendingPathComponent("api/status"), session: http, token: token)
        guard case .string(let home) = status["agent_home"], home.hasPrefix("/"),
              URL(fileURLWithPath: home).resolvingSymlinksInPath().standardizedFileURL.path
                == launch.profileDirectoryURL.resolvingSymlinksInPath().standardizedFileURL.path else { throw Failure.homeMismatch }
        let version = try Self.validatedVersion(health: health, status: status, expectedVersion: expectedVersion,
                                                expectedCommit: expectedCommit)
        let commit: String?
        if case .string(let value) = health["commit"] { commit = value }
        else { commit = nil }
        try Task.checkCancellation()
        guard !stopped, child.isProcessRunning else { throw Failure.processExited }
        let verified = Identity(pid: child.processIdentifier, port: port,
                                home: launch.profileDirectoryURL.resolvingSymlinksInPath().standardizedFileURL,
                                version: version, commit: commit, protocolVersion: 1)
        identity = verified
        try await verifyMateAgentRuntime()
        return verified
    }

    static func validatedVersion(health: [String: JSONValue], status: [String: JSONValue],
                                 expectedVersion: String? = nil, expectedCommit: String? = nil) throws -> String {
        guard let base = health["version"], base == status["version"] else { throw Failure.versionMismatch }
        let commit: String?
        if case .string(let value) = health["commit"] { commit = value } else { commit = nil }
        guard expectedCommit == nil || expectedCommit == commit else { throw Failure.versionMismatch }
        let version: String
        if case .string(let value) = base, value.count <= 128,
           value.range(of: #"^[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:[-+._a-zA-Z0-9]*)$"#, options: .regularExpression) != nil {
            version = value
        } else {
            // Official sealed commit-builds deliberately keep baseVersion unknown.
            // Their display identity is accepted only when tied to the booted commit.
            let display = health["displayVersion"] ?? base
            guard base == .null || base == .string("unknown") || base == display,
                  case .string(let value) = display,
                  value.range(of: #"^git\.[0-9a-f]{7,40}$"#, options: .regularExpression) != nil,
                  let commit, commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil,
                  commit.hasPrefix(String(value.dropFirst(4))) else { throw Failure.versionMismatch }
            version = value
        }
        guard expectedVersion == nil || expectedVersion == version else { throw Failure.versionMismatch }
        return version
    }

    private func fetch(_ url: URL, session: URLSession, token: String) async throws -> [String: JSONValue] {
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-HeyMate-Agent-Token")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard response.statusCode != 401, response.statusCode != 403 else { throw Failure.authenticationFailed }
        guard response.statusCode == 200, data.count <= 262_144,
              case .object(let fields) = try JSONDecoder().decode(JSONValue.self, from: data) else { throw Failure.invalidResponse }
        return fields
    }

    /// Bounded authenticated REST access for native setup, limited to relative
    /// API routes on this attested loopback owner. No redirects or token URLs.
    func requestHTTP(path: String, method: String = "GET", body: JSONValue? = nil,
                     queryItems: [URLQueryItem] = [], timeout: Duration = .seconds(10)) async throws -> JSONValue {
        let components = timeout.components
        let timeoutSeconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        guard timeoutSeconds > 0, timeoutSeconds <= 30 else { throw Failure.invalidConfiguration }
        guard let identity, let token, let http, process?.isProcessRunning == true, !stopped else { throw Failure.notRunning }
        guard path.hasPrefix("/api/"), !path.contains("//"), !path.contains("\\"), !path.contains("%"),
              path.range(of: #"^/api/[a-zA-Z0-9_/-]+$"#, options: .regularExpression) != nil,
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(method) else { throw Failure.invalidConfiguration }
        guard queryItems.count <= 16, queryItems.allSatisfy({ item in
            let name = item.name.lowercased()
            return !name.isEmpty && name.count <= 128 && (item.value?.utf8.count ?? 0) <= 4_096
                && !["token", "authorization", "password", "secret", "api_key", "apikey"].contains(where: name.contains)
                && !item.name.unicodeScalars.contains(where: { $0.value < 32 })
                && !(item.value ?? "").unicodeScalars.contains(where: { $0.value < 32 })
        }) else { throw Failure.invalidConfiguration }
        var urlComponents = URLComponents(string: "http://127.0.0.1:\(identity.port)" + path)!
        if !queryItems.isEmpty { urlComponents.queryItems = queryItems }
        var request = URLRequest(url: urlComponents.url!)
        request.httpMethod = method
        request.timeoutInterval = timeoutSeconds
        request.setValue(token, forHTTPHeaderField: "X-HeyMate-Agent-Token")
        if let body {
            let data = try JSONEncoder().encode(body)
            guard data.count <= 262_144 else { throw Failure.invalidResponse }
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await http.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw Failure.httpStatus(response.statusCode) }
        guard data.count <= 1_024 * 1_024 else { throw Failure.invalidResponse }
        if data.isEmpty, response.statusCode == 204 { return .null }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func openSession() throws -> MateAgentServeSession {
        let session = MateAgentServeSession(connection: try openWebSocket(), reconnect: { [weak self] in
            guard let self else { throw Failure.notRunning }
            return try self.openWebSocket()
        }, stopOwner: { [weak self] in
            await self?.shutdown() ?? true
        }, runtimeGuard: { [weak self] in
            guard let self else { throw Failure.notRunning }
            try await self.verifyMateAgentRuntime()
        }, recoverDurable: { [weak self] storedID, userRowID in
            guard let self else { throw Failure.notRunning }
            return try await self.recoverDurableResult(storedID: storedID, userRowID: userRowID)
        })
        return session
    }

    func verifyMateAgentRuntime() async throws {
        try Self.validateMateAgentRuntime(try await requestHTTP(path: "/api/config"))
    }
    static func validateMateAgentRuntime(_ config: JSONValue) throws {
        guard case .object(let fields) = config else { throw Failure.invalidResponse }
        guard let model = fields["model"] else { return }
        if case .string = model { return } // Legacy model-name scalar uses native defaults.
        guard case .object(let values) = model else { throw Failure.invalidResponse }
        for key in ["openai_runtime", "api_mode"] {
            if case .string(let value) = values[key],
               value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "codex_app_server" {
                throw Failure.unsupportedRuntime
            }
        }
    }

    /// Read-only reconciliation after the replay epoch died. Never calls session.resume:
    /// MateAgent can auto-continue a durable interrupted marker during resume.
    func recoverDurableResult(storedID: String, userRowID: Int) async throws -> MateAgentServeSession.Result? {
        guard let identity, userRowID > 0,
              storedID.range(of: "^[A-Za-z0-9_-]{1,256}$", options: .regularExpression) != nil else {
            throw Failure.invalidConfiguration
        }
        let markerURL = identity.home.appendingPathComponent("desktop/interrupted_turns.json")
        if FileManager.default.fileExists(atPath: markerURL.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: markerURL.path)
            guard let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 4 * 1_024 * 1_024,
                  case .object(let markers) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: markerURL)),
                  markers[storedID] == nil else { return nil }
        }
        let page = try await requestHTTP(path: "/api/sessions/\(storedID)/messages/around", queryItems: [
            URLQueryItem(name: "row_id", value: String(userRowID)), URLQueryItem(name: "limit", value: "120")
        ])
        return Self.durableResult(page: page, userRowID: userRowID)
    }

    /// Require an exact durable prompt boundary and a provider's terminal stop row.
    /// Missing, compressed, tool-pending, error, or truncated history remains unresolved.
    static func durableResult(page: JSONValue, userRowID: Int) -> MateAgentServeSession.Result? {
        guard case .object(let page) = page, case .array(let rows) = page["messages"],
              rows.count >= 2, rows.count <= 120, case .object(let pagination) = page["pagination"],
              pagination["has_newer"] == .bool(false),
              let firstRow = rows.first, case .object(let first) = firstRow, first["id"] == .number(Double(userRowID)),
              first["role"] == .string("user"), first["_compressed_summary"] != .bool(true) else { return nil }
        for row in rows.dropFirst() {
            guard case .object(let fields) = row, fields["role"] != .string("user"),
                  fields["_compressed_summary"] != .bool(true) else { return nil }
        }
        guard let lastRow = rows.last, case .object(let last) = lastRow, last["role"] == .string("assistant"),
              last["finish_reason"] == .string("stop"), last["display_kind"] != .string("failed_turn"),
              case .number(let finalRowID) = last["id"], finalRowID > Double(userRowID), finalRowID.rounded() == finalRowID,
              last["tool_calls"] == nil || last["tool_calls"] == .null || last["tool_calls"] == .array([]),
              case .string(let text) = last["content"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 1_048_576 else { return nil }
        return .init(text: text, status: "complete")
    }

    func openWebSocket() throws -> MateAgentServeWebSocket {
        guard let identity, let token, let http, process?.isProcessRunning == true, !stopped else { throw Failure.notRunning }
        let id = UUID()
        let socket = MateAgentServeWebSocket(baseURL: URL(string: "ws://127.0.0.1:\(identity.port)/api/ws")!, token: token, session: http)
        socket.onClosed = { [weak self] in self?.sockets.removeValue(forKey: id) }
        sockets[id] = socket
        socket.connect()
        return socket
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        finishReadiness(.failure(CancellationError()))
        startTask?.cancel()
        for socket in Array(sockets.values) { socket.close() }
        sockets.removeAll()
        process?.terminateThenKill()
        http?.invalidateAndCancel()
        http = nil
        token = nil
        identity = nil
        configuration = nil
        onStopped?()
    }

    @discardableResult
    func shutdown() async -> Bool {
        stop()
        let exited = await process?.terminateAndWait() ?? true
        if exited {
            process = nil
            if let directory { try? FileManager.default.removeItem(at: directory) }
            directory = nil
        }
        return exited
    }

    private func receiveReadiness(_ line: String) {
        guard readiness != nil, line.hasPrefix("HEYMATE_AGENT_BACKEND_READY") else { return }
        let prefix = "HEYMATE_AGENT_BACKEND_READY port="
        guard line.hasPrefix(prefix), let port = Int(line.dropFirst(prefix.count)), (1...65_535).contains(port) else {
            finishReadiness(.failure(Failure.invalidReadiness)); return
        }
        finishReadiness(.success(port))
    }
    private func finishReadiness(_ result: Result<Int, Error>) {
        let waiting = readiness
        readiness = nil
        readinessTimeout?.cancel()
        readinessTimeout = nil
        waiting?.resume(with: result)
    }
    private func processDidExit() {
        finishReadiness(.failure(Failure.processExited))
        stop()
    }
    private nonisolated static func freshToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.invalidConfiguration }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private nonisolated final class MateAgentServeNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Resumes one waiter exactly once, with whichever comes first: the shared
/// startup's result or the waiter's own cancellation.
nonisolated final class StartupWaitGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var early: Result<Value, Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let early {
            lock.unlock()
            continuation.resume(with: early)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with result: Result<Value, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        guard let continuation else {
            early = result
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
