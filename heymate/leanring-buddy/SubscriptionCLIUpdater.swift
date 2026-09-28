//
//  SubscriptionCLIUpdater.swift
//  leanring-buddy
//
//  Claude, Codex, and OpenCode models come from the CLIs on this Mac.
//  HeyMate updates those installs in place. It does not keep its own copies.
//

import Foundation

nonisolated enum SubscriptionCLIUpdatePreference {
    static let enabledKey = "keepSubscriptionCLIsUpdated"
    static let lastAutomaticUpdateKey = "subscriptionCLILastAutomaticUpdate"
    static let automaticInterval: TimeInterval = 24 * 60 * 60

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) == nil { return true }
        return defaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }

    static func shouldUpdateAutomatically(
        now: Date = Date(),
        in defaults: UserDefaults = .standard
    ) -> Bool {
        guard isEnabled(in: defaults) else { return false }
        guard let last = defaults.object(forKey: lastAutomaticUpdateKey) as? Date else { return true }
        return now.timeIntervalSince(last) >= automaticInterval
    }

    static func markAutomaticUpdateFinished(
        at date: Date = Date(),
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(date, forKey: lastAutomaticUpdateKey)
    }
}

nonisolated struct SubscriptionCLIUpdateCommand: Equatable {
    let cliName: String
    let versionExecutableURL: URL
    let updateExecutableURL: URL
    let updateArguments: [String]
}

nonisolated enum SubscriptionCLIUpdatePlan: Equatable {
    case command(SubscriptionCLIUpdateCommand)
    case skipped(name: String, reason: String)
}

nonisolated enum SubscriptionCLIUpdatePlanner {
    static func plans(resolving resolve: (String) -> URL?) -> [SubscriptionCLIUpdatePlan] {
        [
            claudePlan(resolving: resolve),
            codexPlan(resolving: resolve),
            openCodePlan(resolving: resolve)
        ]
    }

    private static func claudePlan(resolving resolve: (String) -> URL?) -> SubscriptionCLIUpdatePlan {
        guard let claude = resolve("claude") else {
            return .skipped(name: "Claude", reason: "not installed")
        }
        return .command(SubscriptionCLIUpdateCommand(
            cliName: "Claude",
            versionExecutableURL: claude,
            updateExecutableURL: claude,
            updateArguments: ["update"]
        ))
    }

    private static func codexPlan(resolving resolve: (String) -> URL?) -> SubscriptionCLIUpdatePlan {
        guard let codex = resolve("codex") else {
            return .skipped(name: "Codex", reason: "not installed")
        }
        let installed = codex.resolvingSymlinksInPath()
        if let prefix = npmPrefix(forCodexAt: installed) {
            guard let npm = resolve("npm") else {
                return .skipped(name: "Codex", reason: "npm is not available")
            }
            return .command(SubscriptionCLIUpdateCommand(
                cliName: "Codex",
                versionExecutableURL: codex,
                updateExecutableURL: npm,
                updateArguments: ["install", "-g", "--prefix", prefix, "@openai/codex@latest"]
            ))
        }
        if isHomebrewInstall(installed) {
            guard let brew = resolve("brew") else {
                return .skipped(name: "Codex", reason: "Homebrew is not available")
            }
            return .command(SubscriptionCLIUpdateCommand(
                cliName: "Codex",
                versionExecutableURL: codex,
                updateExecutableURL: brew,
                updateArguments: ["upgrade", "codex"]
            ))
        }
        guard let npm = resolve("npm") else {
            return .skipped(name: "Codex", reason: "npm is not available")
        }
        return .command(SubscriptionCLIUpdateCommand(
            cliName: "Codex",
            versionExecutableURL: codex,
            updateExecutableURL: npm,
            updateArguments: ["install", "-g", "@openai/codex@latest"]
        ))
    }

    private static func openCodePlan(resolving resolve: (String) -> URL?) -> SubscriptionCLIUpdatePlan {
        guard let opencode = resolve("opencode") else {
            return .skipped(name: "OpenCode", reason: "not installed")
        }
        let method = openCodeInstallMethod(for: opencode.resolvingSymlinksInPath())
        return .command(SubscriptionCLIUpdateCommand(
            cliName: "OpenCode",
            versionExecutableURL: opencode,
            updateExecutableURL: opencode,
            updateArguments: ["upgrade", "--method", method]
        ))
    }

    /// `~/.local/lib/node_modules/@openai/codex/...` updates with prefix `~/.local`.
    static func npmPrefix(forCodexAt executable: URL) -> String? {
        let path = executable.path
        let marker = "/node_modules/@openai/codex"
        guard let range = path.range(of: marker) else { return nil }
        var root = String(path[..<range.lowerBound])
        if root.hasSuffix("/lib") {
            root.removeLast(4)
        }
        return root.isEmpty ? nil : root
    }

    static func isHomebrewInstall(_ executable: URL) -> Bool {
        let path = executable.path
        return path.contains("/Cellar/") || path.contains("/homebrew/")
    }

    static func openCodeInstallMethod(for executable: URL) -> String {
        let path = executable.path
        if path.contains("/.bun/") { return "bun" }
        if path.contains("/pnpm/") { return "pnpm" }
        if isHomebrewInstall(executable) { return "brew" }
        if path.contains("/node_modules/") { return "npm" }
        return "curl"
    }
}

nonisolated struct SubscriptionCLIProcessResult: Equatable {
    let status: Int32
    let output: String
}

nonisolated struct SubscriptionCLIUpdateOutcome: Equatable {
    enum State: Equatable {
        case updated(String)
        case unchanged(String)
        case skipped(String)
        case failed(String)
    }

    let cliName: String
    let state: State

    var line: String {
        switch state {
        case .updated(let version):
            return "\(cliName) updated to \(version)"
        case .unchanged(let version):
            return "\(cliName) is current (\(version))"
        case .skipped(let reason):
            return "\(cliName) skipped: \(reason)"
        case .failed(let reason):
            return "\(cliName) failed: \(reason)"
        }
    }
}

nonisolated enum SubscriptionCLIUpdater {
    static let updateTimeout: TimeInterval = 180
    static let versionTimeout: TimeInterval = 20

    static func summary(of outcomes: [SubscriptionCLIUpdateOutcome]) -> String {
        outcomes.map(\.line).joined(separator: " · ")
    }

    static func updateInstalledCLIs(
        resolving resolve: (String) -> URL? = { LoginShellExecutableResolver.resolveExecutable(named: $0) },
        executing execute: (URL, [String], TimeInterval) -> SubscriptionCLIProcessResult = runProcess
    ) -> [SubscriptionCLIUpdateOutcome] {
        SubscriptionCLIUpdatePlanner.plans(resolving: resolve).map { plan in
            switch plan {
            case .skipped(let name, let reason):
                return SubscriptionCLIUpdateOutcome(cliName: name, state: .skipped(reason))
            case .command(let command):
                return run(command, executing: execute)
            }
        }
    }

    static func interpret(
        cliName: String,
        before: String?,
        after: String?,
        status: Int32,
        output: String
    ) -> SubscriptionCLIUpdateOutcome {
        if status != 0 {
            let reason = lastMeaningfulLine(in: output) ?? "update failed"
            return SubscriptionCLIUpdateOutcome(cliName: cliName, state: .failed(reason))
        }
        if let before, let after, before == after {
            return SubscriptionCLIUpdateOutcome(cliName: cliName, state: .unchanged(after))
        }
        if let after {
            return SubscriptionCLIUpdateOutcome(cliName: cliName, state: .updated(after))
        }
        if let before {
            return SubscriptionCLIUpdateOutcome(cliName: cliName, state: .unchanged(before))
        }
        return SubscriptionCLIUpdateOutcome(cliName: cliName, state: .updated("latest"))
    }

    static func versionToken(in text: String) -> String? {
        guard let match = text.range(of: #"\d+\.\d+(?:\.\d+)*"#, options: .regularExpression) else {
            return nil
        }
        return String(text[match])
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{001B}\\[[0-9;?]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
    }

    private static func run(
        _ command: SubscriptionCLIUpdateCommand,
        executing execute: (URL, [String], TimeInterval) -> SubscriptionCLIProcessResult
    ) -> SubscriptionCLIUpdateOutcome {
        let before = versionToken(in: execute(
            command.versionExecutableURL,
            ["--version"],
            versionTimeout
        ).output)
        let update = execute(command.updateExecutableURL, command.updateArguments, updateTimeout)
        let afterResult = execute(command.versionExecutableURL, ["--version"], versionTimeout)
        let after = versionToken(in: afterResult.output) ?? versionToken(in: update.output)
        return interpret(
            cliName: command.cliName,
            before: before,
            after: after,
            status: update.status,
            output: update.output
        )
    }

    private static func lastMeaningfulLine(in text: String) -> String? {
        let cleaned = stripANSI(text)
        let line = cleaned
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
        guard let line else { return nil }
        if line.count <= 160 { return line }
        return String(line.prefix(157)) + "..."
    }

    static func runProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) -> SubscriptionCLIProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = LoginShellExecutableResolver.loginPATH()
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let collected = PipeCollector()
        collected.drain(output.fileHandleForReading)
        collected.drain(errors.fileHandleForReading)

        do {
            try process.run()
        } catch {
            return SubscriptionCLIProcessResult(status: 1, output: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return SubscriptionCLIProcessResult(status: 1, output: "timed out")
        }
        return SubscriptionCLIProcessResult(status: process.terminationStatus, output: collected.text())
    }
}

private final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func drain(_ handle: FileHandle) {
        handle.readabilityHandler = { [weak self] source in
            let chunk = source.availableData
            if chunk.isEmpty {
                source.readabilityHandler = nil
                return
            }
            self?.append(chunk)
        }
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }
}
