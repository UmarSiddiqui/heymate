// Vendored/adapted from vinzdg/codenotch, MIT. Revision 6522e9f3ee0fe35d46e428b441e6e80b586eacbb.
// Upstream: Sources/Providers/GitHubCopilotProvider.swift; see Codenotch-PROVENANCE.md for local changes.
import Foundation
nonisolated struct CNGitHubCopilotCredentials: Sendable {
    let token: String
    let username: String?
    let source: String

    static var hostsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/gh/hosts.yml")
    }

    static func load() throws -> CNGitHubCopilotCredentials {
        let environment = ProcessInfo.processInfo.environment
        let hosts = try? CNReadBudget.text(hostsURL)
        return try load(environment: environment, hosts: hosts, command: ghToken)
    }

    /// Injectable inputs keep credential discovery testable without touching a
    /// real token or starting GitHub CLI.
    static func load(environment: [String: String],
                     hosts: String?,
                     command: () -> String?) throws -> CNGitHubCopilotCredentials {
        let parsed = parseHosts(hosts)
        if let token = nonEmpty(environment["GH_TOKEN"] ?? environment["GITHUB_TOKEN"]) {
            return CNGitHubCopilotCredentials(token: token, username: parsed.username,
                                            source: "GitHub")
        }
        if let token = parsed.token {
            return CNGitHubCopilotCredentials(token: token, username: parsed.username,
                                            source: "GitHub CLI")
        }
        if let token = nonEmpty(command()) {
            return CNGitHubCopilotCredentials(token: token, username: parsed.username,
                                            source: "GitHub CLI")
        }
        throw CNUsageProviderError.needsAuth
    }

    static func account() -> CNProviderAccount? {
        guard let hosts = try? CNReadBudget.text(hostsURL),
              let username = parseHosts(hosts).username
        else { return nil }
        return CNProviderAccount(
            label: username,
            plan: nil,
            source: "GitHub",
            manageURL: URL(string: "https://github.com/settings/copilot")
        )
    }

    private static func ghToken() -> String? { nil } // Never invoke gh/Keychain on a polling timer.

    private static func parseHosts(_ text: String?) -> (username: String?, token: String?) {
        guard let text else { return (nil, nil) }
        let lines = text.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "github.com:"
        }) else { return (nil, nil) }

        var username: String?
        var token: String?
        for line in lines.dropFirst(start + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix(" ") && !line.hasPrefix("\t") { break }
            if let value = yamlValue(trimmed, key: "user") { username = value }
            if let value = yamlValue(trimmed, key: "oauth_token") { token = value }
        }
        return (username, token)
    }

    private static func yamlValue(_ line: String, key: String) -> String? {
        let prefix = "\(key):"
        guard line.hasPrefix(prefix) else { return nil }
        let value = String(line.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
        return nonEmpty(value)?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated enum CNGitHubCopilotUsage {
    private static let order = ["premium_interactions", "chat", "completions"]

    static func plan(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return ((root["copilot_plan"] as? String) ?? (root["plan"] as? String))?.nonEmptyPlan
    }

    static func windows(from data: Data) throws -> [CNLimitWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quotas = root["quota_snapshots"] as? [String: Any]
        else { throw CNUsageProviderError.badResponse(status: 0) }

        let keys = order + quotas.keys.filter { !order.contains($0) }.sorted()
        let windows = keys.compactMap { key -> CNLimitWindow? in
            guard let quota = quotas[key] as? [String: Any] else { return nil }
            return window(id: key, quota: quota, root: root)
        }
        guard !windows.isEmpty else {
            throw CNUsageProviderError.nothingMetered(CNL10n.t("GitHub Copilot reported no metered quotas"))
        }
        return windows
    }

    private static func window(id: String, quota: [String: Any], root: [String: Any]) -> CNLimitWindow? {
        if (quota["unlimited"] as? Bool) == true { return nil }

        let entitlement = number(quota["entitlement"])
        let remaining = number(quota["remaining"])
        let used = number(quota["used"])
        let reset = date(quota["reset_date"] ?? quota["reset_at"] ?? quota["resets_at"])
            ?? date(root["quota_reset_date"])

        if entitlement == 0 { return nil }
        if let entitlement, entitlement > 0 {
            guard used != nil || remaining != nil else { return nil }
            let consumed = used ?? max(0, entitlement - (remaining ?? entitlement))
            return CNLimitWindow(id: id, label: label(for: id),
                               usedFraction: max(0, consumed / entitlement), resetsAt: reset,
                               duration: monthlyDuration(endingAt: reset))
        }
        if let remaining, remaining >= 0, used == nil {
            return remaining == 0 && entitlement == 0 ? nil
                : CNLimitWindow(id: id, label: label(for: id),
                              remaining: Int(remaining.rounded()), resetsAt: reset)
        }
        if let used, used >= 0 {
            return CNLimitWindow(id: id, label: label(for: id),
                               used: Int(used.rounded()), resetsAt: reset)
        }
        return nil
    }

    /// Copilot allowances reset at midnight UTC on the first of each month.
    private static func monthlyDuration(endingAt reset: Date?) -> TimeInterval? {
        guard let reset else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.day, .hour, .minute, .second], from: reset)
        guard parts.day == 1, parts.hour == 0, parts.minute == 0, parts.second == 0,
              let previousMonth = calendar.date(byAdding: .second, value: -1, to: reset)
        else { return nil }
        return calendar.dateInterval(of: .month, for: previousMonth)?.duration
    }

    private static func number(_ value: Any?) -> Double? {
        CNNumber.read(value)
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return fractional.date(from: text) ?? plain.date(from: text)
    }

    private static func label(for id: String) -> String {
        switch id {
        case "premium_interactions": return "Premium requests"
        case "chat":                return "Chat requests"
        case "completions":         return "Completions"
        default:
            return id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
