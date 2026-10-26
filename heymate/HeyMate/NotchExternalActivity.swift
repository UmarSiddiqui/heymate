import AppKit
import Foundation

nonisolated enum NotchExternalActivity {
    static func scan(enabled: Set<NotchUsageProvider>) async -> [NotchUsageProvider: [CNAgentSession]] {
        // Capture AppKit lifecycle evidence on its actor. Activity itself still
        // comes from session records, never merely from an app being open.
        let cursorLaunch = await MainActor.run {
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.todesktop.230313mzl4w4u92" }?.launchDate
        }
        let worker = Task.detached(priority: .utility) {
            read(enabled: enabled, cursorLaunch: cursorLaunch)
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    static func read(enabled: Set<NotchUsageProvider>, cursorLaunch: Date? = nil, now: Date = Date()) -> [NotchUsageProvider: [CNAgentSession]] {
        var result: [NotchUsageProvider: [CNAgentSession]] = [:]
        for provider in enabled {
            guard !Task.isCancelled else { break }
            // One provider exhausting its scan never blanks another provider.
            result[provider] = (try? CNReadBudget.scan {
                switch provider {
                case .gemini:
                    return CNGeminiCLIActivity.read(root: CNGeminiCLIUsage.sessionsRoot, staleAfter: 45, now: now)
                case .antigravity:
                    return CNAntigravityActivityMonitor.read(roots: CNAntigravityActivity.transcriptRoots, staleAfter: 45, now: now)
                case .kimi:
                    return CNKimiActivity.read(root: CNKimiActivity.root, staleAfter: 90, now: now)
                case .cursor:
                    let store = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
                    return CNCursorActivityMonitor.read(store: store, cursorLaunchedAt: cursorLaunch, staleAfter: 45, now: now)
                case .claude: return claude(now: now)
                case .codex: return codex(now: now)
                default: return []
                }
            }) ?? []
        }
        return result
    }

    static func claude(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> [CNAgentSession] {
        let root = home.appendingPathComponent(".claude/sessions")
        return ((try? CNReadBudget.directory(root)) ?? []).filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? CNReadBudget.data(url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let record = CNClaudeSessionRecord(json: json), record.reportsStatus,
                  !record.isFromSDK, CNProcessLiveness.isAlive(pid: record.pid, startedAt: record.startedAt),
                  !CNProcessLiveness.isStopped(pid: record.pid) else { return nil }
            // Busy/waiting registry entries are heartbeat signals. Dead or
            // suspended processes and old files never become permanent waits.
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) <= 90, modified <= now.addingTimeInterval(5) else { return nil }
            return record.session
        }
    }

    static func codex(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> [CNAgentSession] {
        let directory = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        // Codex rollout directories are UTC, independent of the user's zone.
        // Yesterday stays in scope for a turn spanning midnight.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let files = [now, now.addingTimeInterval(-86400)].flatMap { stamp in
            let components = calendar.dateComponents([.year, .month, .day], from: stamp)
            let day = String(format: "%04d/%02d/%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
            return (try? CNReadBudget.directory(directory.appendingPathComponent("sessions/\(day)"))) ?? []
        }
        return files.filter { $0.pathExtension == "jsonl" }.compactMap { file in
            guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(modified) <= 45, modified <= now.addingTimeInterval(5),
                  let state = CNCodexRolloutActivity.state(from: file) else { return nil }
            return CNAgentSession(id: "codex.\(file.lastPathComponent)", name: "Codex", detail: "Recent local rollout",
                                  state: state == .busy ? .busy : .success, waitingFor: nil, since: modified)
        }
    }
}

extension CNAgentSession.State {
    var label: String {
        switch self {
        case .busy: "Working"
        case .waiting: "Needs you"
        case .success: "Complete"
        case .idle: "Idle"
        }
    }
}
