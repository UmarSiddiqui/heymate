// Vendored/adapted from vinzdg/codenotch, MIT. Revision 6522e9f3ee0fe35d46e428b441e6e80b586eacbb.
// Upstream: Sources/Providers/ClaudeUsageCLI.swift; see Codenotch-PROVENANCE.md for local changes.
import Foundation

/// Claude Code's own `/usage`, asked of the binary rather than of the endpoint
/// behind it.
///
/// The OAuth usage endpoint answers 429 readily and its token sits in a
/// Keychain item Claude Code re-files on every rotation. `claude "/usage"`
/// reports the same figures off a credential the CLI already holds, needs no
/// Keychain access from HeyMate and keeps working while the endpoint is in
/// backoff. It costs a subprocess, so the store throttles it.
nonisolated struct CNClaudeUsageCLI: Sendable {
    let binary: URL

    /// Long enough for a cold Node start on a busy machine. A timeout kills it.
    static let timeout: TimeInterval = 20

    /// Print mode, no transcript, no MCP servers, no workspace-trust prompt.
    /// Telemetry stays on: the per-model weekly line sits behind a feature gate.
    static let arguments = ["--print", "--no-session-persistence", "--strict-mcp-config", "/usage"]

    /// One fixed working directory, so Claude Code never files a new project
    /// folder per poll.
    static var scratchLocation: URL {
        HeyMateDataDirectory.url.appendingPathComponent("usage-scratch", isDirectory: true)
    }

    /// `/usage` processes running right now. The session scan steps over them
    /// so the probe never shows up as an external Claude session.
    static var runningPIDs: Set<Int32> { running.all }
    private static let running = PIDRegistry()

    private final class PIDRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var pids: Set<Int32> = []
        var all: Set<Int32> { lock.lock(); defer { lock.unlock() }; return pids }
        func insert(_ pid: Int32) { lock.lock(); pids.insert(pid); lock.unlock() }
        func remove(_ pid: Int32) { lock.lock(); pids.remove(pid); lock.unlock() }
    }

    /// Every place Claude Code installs itself. Launched from Finder the app's
    /// PATH has none of these, so `which` is no help. The copy inside Claude
    /// Desktop keeps its own token store and is skipped.
    private static let searchPaths = [
        ".local/bin/claude",
        ".claude/local/claude",
        ".bun/bin/claude",
        ".volta/bin/claude",
        "Library/pnpm/claude",
        ".npm-global/bin/claude"
    ]
    private static let systemPaths = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]

    static func locate(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       fileManager: FileManager = .default) -> CNClaudeUsageCLI? {
        let versions = home.appendingPathComponent(".nvm/versions/node")
        let nvm = ((try? fileManager.contentsOfDirectory(atPath: versions.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { versions.appendingPathComponent($0).appendingPathComponent("bin/claude") }
        let candidates = searchPaths.map { home.appendingPathComponent($0) } + nvm + systemPaths.map(URL.init(fileURLWithPath:))
        guard let found = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
                && !$0.resolvingSymlinksInPath().path.contains("/Library/Application Support/Claude/")
        }) else { return nil }
        return CNClaudeUsageCLI(binary: found)
    }

    /// Runs `/usage` off the cooperative pool: reading the pipe blocks.
    func reading(now: Date = Date()) async throws -> NotchUsageReading {
        let text = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try self.run() })
            }
        }
        return NotchUsageReading(windows: try Self.parse(text, now: now), fetchedAt: now)
    }

    private func run() throws -> String {
        let scratch = Self.scratchLocation
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["PWD"] = scratch.path
        let process = Process()
        process.executableURL = binary
        process.arguments = Self.arguments
        process.currentDirectoryURL = scratch
        process.environment = environment
        // Never a terminal; an inherited stdin leaves `claude` waiting forever.
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        // Discarded: an unread stderr pipe fills at 64 KB and stalls the CLI.
        process.standardError = FileHandle.nullDevice
        try process.run()
        let pid = process.processIdentifier
        Self.running.insert(pid)
        defer { Self.running.remove(pid) }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.timeout, execute: watchdog)
        defer { watchdog.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // A non-zero exit means Claude Code has no login of its own.
        guard process.terminationStatus == 0 else { throw NotchUsageFailure.signIn }
        guard data.count <= 256 * 1024, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw NotchUsageFailure.unavailable
        }
        return text
    }

    /// The lines `/usage` leads with, e.g.
    ///
    ///     Current session: 38% used · resets Sep 7 at 2:59pm (Asia/Jakarta)
    ///     Current week (all models): 4% used · resets Sep 14 at 5:59am (Asia/Jakarta)
    ///
    /// The prose below them is approximate by its own admission and ignored.
    private static let line = try! NSRegularExpression(
        pattern: #"^Current (?:(session)|week \(([^)]+)\)):\s*(\d+(?:\.\d+)?)%\s*used(?:\s*·\s*resets\s*(.+?))?\s*$"#,
        options: [.anchorsMatchLines]
    )

    /// Window ids and titles match the endpoint reader, so cached readings and
    /// the headline/weekly lookups line up whichever source answered.
    static func parse(_ text: String, now: Date = Date()) throws -> [NotchUsageWindow] {
        let range = NSRange(text.startIndex..., in: text)
        var windows: [NotchUsageWindow] = []
        for match in line.matches(in: text, range: range) {
            func group(_ index: Int) -> String? {
                guard let found = Range(match.range(at: index), in: text) else { return nil }
                return String(text[found])
            }
            guard let percent = group(3).flatMap(Double.init), percent.isFinite, (0...100_000).contains(percent) else { continue }
            let id: String, title: String, duration: TimeInterval
            if group(1) != nil {
                (id, title, duration) = ("five_hour", "5 hours", 5 * 3600)
            } else {
                let name = group(2) ?? ""
                if name.lowercased() == "all models" {
                    (id, title) = ("seven_day", "Weekly")
                } else {
                    (id, title) = ("seven_day_" + name.lowercased().replacingOccurrences(of: " ", with: "_"), "\(name) weekly")
                }
                duration = 7 * 86400
            }
            guard !windows.contains(where: { $0.id == id }) else { continue }
            // A percentage that parsed is kept even when the date wording changed.
            windows.append(NotchUsageWindow(id: id, title: title, usedPercent: percent,
                                            resetsAt: group(4).flatMap { resetDate(from: $0, now: now) },
                                            duration: duration))
        }
        // No session window means no headline; let the endpoint path answer.
        guard windows.contains(where: { $0.id == "five_hour" }) else { throw NotchUsageFailure.unavailable }
        return windows
    }

    /// `Sep 7 at 2:59pm (Asia/Jakarta)` → a `Date`. No year is printed, so the
    /// candidate nearest `now` wins across last, this and next year.
    static func resetDate(from text: String, now: Date) -> Date? {
        var stamp = text.trimmingCharacters(in: .whitespaces)
        var zone = TimeZone.current
        // The zone comes off before the am/pm fix: `America/...` has an "am".
        if let open = stamp.lastIndex(of: "("), stamp.hasSuffix(")") {
            let name = String(stamp[stamp.index(after: open)...].dropLast())
            zone = TimeZone(identifier: name) ?? zone
            stamp = String(stamp[..<open]).trimmingCharacters(in: .whitespaces)
        }
        stamp = stamp.replacingOccurrences(of: "am", with: "AM").replacingOccurrences(of: "pm", with: "PM")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        // Minutes are dropped on the hour: `Sep 7 at 3pm`.
        guard let parsed = ["MMM d 'at' h:mma", "MMM d 'at' ha"].lazy.compactMap({ format -> Date? in
            formatter.dateFormat = format
            return formatter.date(from: stamp)
        }).first else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var parts = calendar.dateComponents([.month, .day, .hour, .minute], from: parsed)
        let year = calendar.component(.year, from: now)
        return [year - 1, year, year + 1].compactMap { candidate -> Date? in
            parts.year = candidate
            return calendar.date(from: parts)
        }.min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
    }
}
