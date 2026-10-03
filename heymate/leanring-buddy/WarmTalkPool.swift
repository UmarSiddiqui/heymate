//
//  WarmTalkPool.swift
//  leanring-buddy
//
//  Keeps one Talk engine already started, so a question does not pay for
//  process boot, sign-in check, and tool load after the user stops
//  speaking.
//
//  Claude: `claude -p --input-format stream-json` boots and then waits on
//  stdin for its first message. Measured on this Mac, a child left idle for
//  four seconds emitted `system init` 0.04 s after the message arrived, and
//  a screen question went from ~10 s to ~4 s.
//
//  Codex: `codex app-server` speaks JSON-RPC on stdio. The pool runs
//  `initialize` and `thread/start` while the user is still speaking, so the
//  question is a single `turn/start`. Smaller win (~7 s to ~4–7 s) because
//  the model itself is most of a Codex answer.
//
//  The pool starts a child when the user starts holding the Talk key — the
//  seconds they spend speaking cover the boot — and hands it the question
//  the moment the transcript is final.
//
//  One child answers exactly one question and then exits. Reusing a child
//  across turns would carry every earlier screenshot into the next answer's
//  context, which is slower, costs more of the plan, and leaks one turn's
//  screen into another. Fresh-per-turn keeps the isolation the one-shot path
//  had; only the wait moves earlier.
//
//  Launch arguments are fixed when the child starts, so anything that can
//  differ between turns — the system prompt, which matched skills and the
//  speaking mate change — travels inside the user message instead.
//

import Foundation

/// Everything that is decided at spawn time. A warm child is only handed a
/// turn whose launch matches exactly; otherwise it is thrown away.
nonisolated struct WarmTalkLaunch: Equatable, Sendable {
    var executableURL: URL
    var arguments: [String]
    var environmentKeysToRemove: [String]
    var environmentOverrides: [String: String]
    /// Codex only: the `thread/start` params, run during warm-up so the
    /// question needs nothing but `turn/start`. Nil for Claude.
    var codexThreadStartParamsJSON: String? = nil
}

/// A started Talk child waiting for its one question.
nonisolated final class WarmTalkChild: @unchecked Sendable {
    let launch: WarmTalkLaunch
    let process: Process
    let workingDirectory: URL
    /// Set once a Codex child's `thread/start` has answered.
    fileprivate(set) var codexThreadID: String?

    private let standardInput: FileHandle
    private let standardOutput: FileHandle
    private var unreadOutput = Data()

    init(
        launch: WarmTalkLaunch,
        process: Process,
        standardInput: FileHandle,
        standardOutput: FileHandle,
        workingDirectory: URL
    ) {
        self.launch = launch
        self.process = process
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.workingDirectory = workingDirectory
    }

    var isRunning: Bool { process.isRunning }

    func write(_ data: Data) throws {
        try standardInput.write(contentsOf: data)
    }

    /// The next stdout line, blocking until it arrives. Nil once the child
    /// has closed stdout — it exited, or `discard()` ended it.
    func readLine() -> String? {
        while true {
            if let newline = unreadOutput.firstIndex(of: 0x0A) {
                let lineData = unreadOutput[unreadOutput.startIndex..<newline]
                unreadOutput.removeSubrange(unreadOutput.startIndex...newline)
                return String(decoding: lineData, as: UTF8.self)
            }
            let chunk = standardOutput.availableData
            if chunk.isEmpty { return nil }
            unreadOutput.append(chunk)
        }
    }

    /// Ends the child and removes its scratch folder. Closing stdin is the
    /// polite way out; a child that ignores it is terminated.
    func discard() {
        try? standardInput.close()
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: workingDirectory)
    }
}

nonisolated final class WarmTalkPool: @unchecked Sendable {

    static let shared = WarmTalkPool()

    /// A warm child nobody used is let go after this long. Long enough for a
    /// slow question, short enough that an idle Mac is not holding a CLI
    /// open for hours.
    static let idleLifetime: TimeInterval = 5 * 60

    /// How long a Codex child gets to finish `initialize` + `thread/start`.
    static let codexHandshakeTimeout: TimeInterval = 20

    private let lock = NSLock()
    private var warmChild: WarmTalkChild?
    private var idleReaper: DispatchWorkItem?

    /// Starts a child for `launch` unless a matching one is already waiting.
    /// Cheap to call repeatedly — every Talk key press does.
    func prewarm(_ launch: WarmTalkLaunch) {
        lock.lock()
        if let warmChild, warmChild.launch == launch, warmChild.isRunning {
            lock.unlock()
            return
        }
        let stale = warmChild
        warmChild = nil
        lock.unlock()
        stale?.discard()

        guard let child = Self.spawn(launch) else { return }

        lock.lock()
        let replaced = warmChild
        warmChild = child
        scheduleIdleReaper(for: child)
        lock.unlock()
        replaced?.discard()
    }

    /// The waiting child for `launch`, or a freshly started one. The caller
    /// owns it from here and must `discard()` it when the turn ends.
    func takeChild(for launch: WarmTalkLaunch) -> WarmTalkChild? {
        lock.lock()
        let candidate = warmChild
        warmChild = nil
        idleReaper?.cancel()
        idleReaper = nil
        lock.unlock()

        if let candidate, candidate.launch == launch, candidate.isRunning {
            return candidate
        }
        candidate?.discard()
        return Self.spawn(launch)
    }

    /// Drops whatever is waiting — the brain, model, or sign-in changed.
    func drain() {
        lock.lock()
        let child = warmChild
        warmChild = nil
        idleReaper?.cancel()
        idleReaper = nil
        lock.unlock()
        child?.discard()
    }

    private func scheduleIdleReaper(for child: WarmTalkChild) {
        idleReaper?.cancel()
        let reaper = DispatchWorkItem { [weak self, weak child] in
            guard let self, let child else { return }
            self.lock.lock()
            let isStillWaiting = self.warmChild === child
            if isStillWaiting { self.warmChild = nil }
            self.lock.unlock()
            if isStillWaiting { child.discard() }
        }
        idleReaper = reaper
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.idleLifetime, execute: reaper)
    }

    private static func spawn(_ launch: WarmTalkLaunch) -> WarmTalkChild? {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-talk-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = HeadlessChildEnvironment.build(
            stripping: launch.environmentKeysToRemove,
            overrides: launch.environmentOverrides
        )
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: workingDirectory)
            return nil
        }
        // If HeyMate goes away, the pipe closes and the child reads EOF and
        // exits on its own — no orphaned CLI.
        let child = WarmTalkChild(
            launch: launch,
            process: process,
            standardInput: standardInput.fileHandleForWriting,
            standardOutput: standardOutput.fileHandleForReading,
            workingDirectory: workingDirectory
        )

        if let threadStartParamsJSON = launch.codexThreadStartParamsJSON {
            guard let threadID = codexHandshake(child, threadStartParamsJSON: threadStartParamsJSON) else {
                child.discard()
                return nil
            }
            child.codexThreadID = threadID
        }
        return child
    }

    /// `initialize` then `thread/start`, returning the new thread's id. A
    /// child that is signed out or on an unsupported CLI fails here, during
    /// warm-up, and the turn falls back to the one-shot path.
    private static func codexHandshake(_ child: WarmTalkChild, threadStartParamsJSON: String) -> String? {
        let watchdog = DispatchWorkItem { child.discard() }
        DispatchQueue.global().asyncAfter(deadline: .now() + codexHandshakeTimeout, execute: watchdog)
        defer { watchdog.cancel() }

        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"heymate","version":"1.0"}}}"#
        let threadStart = #"{"jsonrpc":"2.0","id":2,"method":"thread/start","params":"# + threadStartParamsJSON + "}"
        do {
            try child.write(Data((initialize + "\n").utf8))
            guard CodexAppServerProtocol.awaitResponse(id: 1, from: child) != nil else { return nil }
            try child.write(Data((threadStart + "\n").utf8))
        } catch {
            return nil
        }
        guard let response = CodexAppServerProtocol.awaitResponse(id: 2, from: child) else { return nil }
        return CodexAppServerProtocol.threadID(fromThreadStartResponse: response)
    }
}

/// The few `codex app-server` messages Talk needs, as pure functions so
/// they can be tested without a CLI.
nonisolated enum CodexAppServerProtocol {

    /// Reads lines until the JSON-RPC response with `id`, skipping the
    /// notifications that arrive in between. Nil on EOF or an error reply.
    static func awaitResponse(id: Int, from child: WarmTalkChild) -> [String: Any]? {
        while let line = child.readLine() {
            guard let json = jsonObject(line), json["id"] as? Int == id else { continue }
            return json["error"] == nil ? json : nil
        }
        return nil
    }

    static func threadID(fromThreadStartResponse response: [String: Any]) -> String? {
        ((response["result"] as? [String: Any])?["thread"] as? [String: Any])?["id"] as? String
    }

    enum TurnEvent: Equatable {
        case answered(String)
        case failed(String)
    }

    /// The turn's end, read from one app-server line, or nil for the lines
    /// before it. The final `agentMessage` is the answer; an `error` the CLI
    /// will not retry, a failed `turn/completed`, or an error reply to
    /// `turn/start` (id 3) ends the turn without one.
    static func turnEvent(fromLine line: String) -> TurnEvent? {
        guard let json = jsonObject(line) else { return nil }
        if json["id"] as? Int == 3, let error = json["error"] as? [String: Any] {
            return .failed(error["message"] as? String ?? "Codex refused the question.")
        }
        let params = json["params"] as? [String: Any] ?? [:]
        switch json["method"] as? String {
        case "item/completed":
            guard let item = params["item"] as? [String: Any],
                  item["type"] as? String == "agentMessage",
                  (item["phase"] as? String ?? "final_answer") == "final_answer",
                  let text = item["text"] as? String,
                  !text.isEmpty else { return nil }
            return .answered(text)
        case "error":
            guard params["willRetry"] as? Bool != true else { return nil }
            let raw = (params["error"] as? [String: Any])?["message"] as? String ?? "Codex reported an error."
            return .failed(innerErrorMessage(raw))
        case "turn/completed":
            let status = (params["turn"] as? [String: Any])?["status"] as? String
            return status == "completed" ? nil : .failed("Codex stopped before it answered.")
        default:
            return nil
        }
    }

    /// Codex wraps the API's error JSON inside its own message string;
    /// surface the readable part ("…not supported when using Codex with a
    /// ChatGPT account.") rather than the envelope.
    static func innerErrorMessage(_ raw: String) -> String {
        guard let json = jsonObject(raw),
              let message = (json["error"] as? [String: Any])?["message"] as? String else { return raw }
        return message
    }

    /// One `turn/start` request: per-turn instructions and the question as
    /// text, each screenshot as a local image file the child reads itself.
    static func turnStartJSON(threadID: String, systemPrompt: String, prompt: String, imagePaths: [(path: String, label: String)]) -> Data? {
        var input: [[String: Any]] = []
        if !systemPrompt.isEmpty {
            input.append(textInput("<heymate-instructions>\n\(systemPrompt)\n</heymate-instructions>"))
        }
        for (index, image) in imagePaths.enumerated() {
            input.append(textInput("Screenshot \(index + 1) (\(image.label)):"))
            input.append(["type": "localImage", "path": image.path])
        }
        input.append(textInput(prompt.isEmpty ? "(no words, only the screen)" : prompt))
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "turn/start",
            "params": ["threadId": threadID, "input": input]
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        data.append(0x0A)
        return data
    }

    private static func textInput(_ text: String) -> [String: Any] {
        ["type": "text", "text": text, "text_elements": [] as [Any]]
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
