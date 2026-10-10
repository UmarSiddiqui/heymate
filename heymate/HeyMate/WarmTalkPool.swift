//
//  WarmTalkPool.swift
//  HeyMate
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
//  A child stays with one conversation. Once it has answered, it goes back
//  to the pool tagged with that chat, and the next question in the same chat
//  continues the same CLI session: no boot, no history replayed as text, and
//  the reply streams. Measured on a Codex thread, a follow-up's first token
//  arrived in 1.2 s against 2.8 s for the opening turn.
//
//  The isolation the old one-question-per-child rule bought is kept where
//  it matters. A different chat or mate never reuses a child, and neither
//  does a chat whose history no longer matches what the child saw (a message
//  was edited or deleted). Screenshots do accumulate inside one chat, so a
//  child is retired after `maximumImageTurns` screen turns or
//  `maximumTurns` turns in all, and the next turn starts fresh with the
//  history replayed.
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

    /// The chat this child is carrying, once it has answered in one. Nil
    /// while it is still waiting for its first question.
    var conversationKey: String?
    /// The chat's message count a continuing turn must arrive with. Any
    /// other count means the child's memory and the chat have drifted apart.
    var nextConversationPosition = 0
    var completedTurns = 0
    var imageTurns = 0
    /// The per-turn instructions last sent, so an unchanged block is not
    /// pasted into the session again on every follow-up.
    var lastInstructions: String?
    /// JSON-RPC ids on a Codex child; 1 and 2 belong to the handshake.
    private var nextCodexRequestID = 3

    func takeCodexRequestID() -> Int {
        defer { nextCodexRequestID += 1 }
        return nextCodexRequestID
    }

    /// Whether this child can take the next turn of `conversationKey`.
    func canContinue(conversationKey: String?, position: Int) -> Bool {
        guard let conversationKey, self.conversationKey == conversationKey else { return false }
        return position == nextConversationPosition
            && completedTurns < WarmTalkPool.maximumTurns
            && imageTurns < WarmTalkPool.maximumImageTurns
    }

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
    static let idleLifetime: TimeInterval = 10 * 60

    /// A conversation child is retired after this many turns, or this many
    /// turns that carried a screenshot, whichever comes first.
    static let maximumTurns = 24
    static let maximumImageTurns = 4

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

    /// The waiting child for `launch`, or a freshly started one, and
    /// whether it is continuing `conversationKey` (so the history must not
    /// be replayed). The caller owns the child until it hands it back with
    /// `checkIn` or ends it with `discard()`.
    func takeChild(
        for launch: WarmTalkLaunch,
        conversationKey: String? = nil,
        position: Int = 0
    ) -> (child: WarmTalkChild, isContinuing: Bool)? {
        lock.lock()
        let candidate = warmChild
        if conversationKey == nil, candidate?.conversationKey != nil {
            // A one-off question leaves the open chat's session alone.
            lock.unlock()
            return Self.spawn(launch).map { ($0, false) }
        }
        warmChild = nil
        idleReaper?.cancel()
        idleReaper = nil
        lock.unlock()

        if let candidate, candidate.launch == launch, candidate.isRunning {
            if candidate.canContinue(conversationKey: conversationKey, position: position) {
                return (candidate, true)
            }
            if candidate.conversationKey == nil {
                return (candidate, false)
            }
        }
        candidate?.discard()
        return Self.spawn(launch).map { ($0, false) }
    }

    /// Returns a child that has just answered, so the next turn of the same
    /// chat continues it. A child past its limits is retired instead and a
    /// fresh one started in its place.
    func checkIn(_ child: WarmTalkChild) {
        guard child.isRunning,
              child.completedTurns < Self.maximumTurns,
              child.imageTurns < Self.maximumImageTurns else {
            child.discard()
            prewarm(child.launch)
            return
        }
        lock.lock()
        let replaced = warmChild
        warmChild = child
        scheduleIdleReaper(for: child)
        lock.unlock()
        if replaced !== child { replaced?.discard() }
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
    static func turnEvent(fromLine line: String, requestID: Int = 3) -> TurnEvent? {
        guard let json = jsonObject(line) else { return nil }
        if json["id"] as? Int == requestID, let error = json["error"] as? [String: Any] {
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

    /// The next piece of the answer while it streams, from an
    /// `item/agentMessage/delta` notification. Nil for every other line.
    static func textDelta(fromLine line: String) -> String? {
        guard line.contains("item/agentMessage/delta"),
              let json = jsonObject(line),
              json["method"] as? String == "item/agentMessage/delta",
              let delta = (json["params"] as? [String: Any])?["delta"] as? String else { return nil }
        return delta
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
    static func turnStartJSON(threadID: String, systemPrompt: String, prompt: String, imagePaths: [(path: String, label: String)], requestID: Int = 3) -> Data? {
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
            "id": requestID,
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
