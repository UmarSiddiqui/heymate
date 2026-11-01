import Foundation

/// Which Pi harness permission cards Full access answers on its own. The
/// harness asks for every write, edit and shell command; before this the
/// card showed in both modes, so Full access never applied to chat work.
/// The floor still asks: anything that sends, deletes, pays, touches
/// credentials, publishes, reaches the network or changes the system.
nonisolated enum MateAgentApprovalPolicy {
    /// Programs that leave the folder or the Mac, or change the system.
    /// Matched only where a command starts, so `Image.open(p)` inside a
    /// script is not the `open` command.
    static let shellTriggers: Set<String> = [
        "sudo", "curl", "wget", "ssh", "scp", "sftp", "rsync", "nc", "osascript", "mail", "sendmail",
        "kill", "killall", "pkill", "chmod", "chown", "shutdown", "reboot", "launchctl", "defaults", "tccutil",
        "security", "codesign", "dd", "mkfs", "diskutil", "open",
    ]

    static func autoAllows(_ params: [String: JSONValue], mode: ApprovalMode) -> Bool {
        guard mode == .fullAccess, let tool = toolName(params), let subject = subject(params, tool: tool) else { return false }
        switch tool {
        case "write", "edit":
            return ApprovalFloor.reasonPlanNeedsHuman(subject) == nil
        case "bash":
            return ApprovalFloor.reasonPlanNeedsHuman(subject) == nil && !runsTriggeredProgram(subject)
        default:
            return false
        }
    }

    /// The harness titles each card "Allow <tool>?".
    static func toolName(_ params: [String: JSONValue]) -> String? {
        if case .string(let tool) = params["tool"], !tool.isEmpty { return tool }
        guard case .string(let title) = params["title"], title.hasPrefix("Allow "), title.hasSuffix("?") else { return nil }
        let name = title.dropFirst("Allow ".count).dropLast()
        return name.isEmpty ? nil : String(name)
    }

    /// The command or path, whole. The card's description is cut at 3,500
    /// characters, so a long script would otherwise never parse and always ask.
    private static func subject(_ params: [String: JSONValue], tool: String) -> String? {
        if case .string(let subject) = params["subject"], !subject.isEmpty { return subject }
        guard case .string(let description) = params["description"], let data = description.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let value = args[tool == "bash" ? "command" : "path"] as? String
        return value?.isEmpty == false ? value : nil
    }

    /// The program at the start of each command segment, plus `git push`.
    static func runsTriggeredProgram(_ command: String) -> Bool {
        let separators = CharacterSet(charactersIn: ";&|\n`(")
        for segment in command.components(separatedBy: separators) {
            let tokens = segment.split(whereSeparator: \.isWhitespace).map { String($0).lowercased() }
            guard let first = tokens.first else { continue }
            let program = first.split(separator: "/").last.map(String.init) ?? first
            if shellTriggers.contains(program) { return true }
            if program == "git", tokens.dropFirst().contains("push") { return true }
        }
        return false
    }
}
