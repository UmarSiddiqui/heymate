//
//  ClaudeWarmTalkPool.swift
//  leanring-buddy
//
//  Keeps one `claude` child already started, so a Talk question does not
//  pay for process boot, sign-in check, and tool load after the user stops
//  speaking.
//
//  `claude -p --input-format stream-json` boots and then waits on stdin for
//  the first message. Measured on this Mac: a child left idle for four
//  seconds emitted its `system init` 0.04 s after the message arrived. So
//  the pool starts a child when the user starts holding the Talk key — the
//  seconds they spend speaking cover the boot — and hands it the question
//  the moment the transcript is final.
//
//  One child answers exactly one question and then exits. Reusing a child
//  across turns would carry every earlier screenshot into the next answer's
//  context, which is slower, costs more of the plan, and leaks one turn's
//  screen into another. Fresh-per-turn keeps the isolation the one-shot
//  `claude -p` path had; only the wait moves earlier.
//
//  Launch arguments are fixed when the child starts, so anything that can
//  differ between turns — the system prompt, which matched skills and the
//  speaking mate change — travels inside the user message instead. See
//  `SubscriptionCLIVisionClient.warmUserMessageJSON`.
//

import Foundation

/// Everything that is decided at spawn time. A warm child is only handed a
/// turn whose launch matches exactly; otherwise it is thrown away.
nonisolated struct ClaudeWarmTalkLaunch: Equatable, Sendable {
    var executableURL: URL
    var arguments: [String]
    var environmentKeysToRemove: [String]
    var environmentOverrides: [String: String]
}

/// A started `claude` child waiting for its one message.
nonisolated final class ClaudeWarmTalkChild: @unchecked Sendable {
    let launch: ClaudeWarmTalkLaunch
    let process: Process
    let standardInput: FileHandle
    let standardOutput: FileHandle
    let workingDirectory: URL

    init(
        launch: ClaudeWarmTalkLaunch,
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

    /// Ends the child and removes its scratch folder. Closing stdin is the
    /// polite way out; a child that ignores it is terminated.
    func discard() {
        try? standardInput.close()
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: workingDirectory)
    }
}

nonisolated final class ClaudeWarmTalkPool: @unchecked Sendable {

    static let shared = ClaudeWarmTalkPool()

    /// A warm child nobody used is let go after this long. Long enough for a
    /// slow question, short enough that an idle Mac is not holding a CLI
    /// open for hours.
    static let idleLifetime: TimeInterval = 5 * 60

    private let lock = NSLock()
    private var warmChild: ClaudeWarmTalkChild?
    private var idleReaper: DispatchWorkItem?

    /// Starts a child for `launch` unless a matching one is already waiting.
    /// Cheap to call repeatedly — every Talk key press does.
    func prewarm(_ launch: ClaudeWarmTalkLaunch) {
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
    func takeChild(for launch: ClaudeWarmTalkLaunch) -> ClaudeWarmTalkChild? {
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

    private func scheduleIdleReaper(for child: ClaudeWarmTalkChild) {
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

    private static func spawn(_ launch: ClaudeWarmTalkLaunch) -> ClaudeWarmTalkChild? {
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
        return ClaudeWarmTalkChild(
            launch: launch,
            process: process,
            standardInput: standardInput.fileHandleForWriting,
            standardOutput: standardOutput.fileHandleForReading,
            workingDirectory: workingDirectory
        )
    }
}
