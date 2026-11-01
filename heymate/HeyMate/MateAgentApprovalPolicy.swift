import Foundation

/// Which Pi harness permission cards Full access answers on its own. The
/// harness asks for every write, edit and shell command; before this the
/// card showed in both modes, so Full access never applied to chat work.
/// The floor still asks: anything that sends, deletes, pays, touches
/// credentials, publishes, reaches the network or changes the system.
nonisolated enum MateAgentApprovalPolicy {
    /// Shell words that leave the folder or the Mac, or change the system.
    static let shellTriggers: Set<String> = [
        "push", "sudo", "curl", "wget", "ssh", "scp", "sftp", "rsync", "nc", "osascript", "mail", "sendmail",
        "kill", "killall", "pkill", "chmod", "chown", "shutdown", "reboot", "launchctl", "defaults", "tccutil",
        "security", "codesign", "dd", "mkfs", "diskutil", "open",
    ]

    static func autoAllows(_ params: [String: JSONValue], mode: ApprovalMode) -> Bool {
        guard mode == .fullAccess, let tool = toolName(params),
              case .string(let description) = params["description"],
              let data = description.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        switch tool {
        case "write", "edit":
            guard let path = args["path"] as? String, !path.isEmpty else { return false }
            return ApprovalFloor.reasonPlanNeedsHuman(path) == nil
        case "bash":
            guard let command = args["command"] as? String, !command.isEmpty else { return false }
            return ApprovalFloor.reasonPlanNeedsHuman(command) == nil && !words(in: command).contains { shellTriggers.contains($0) }
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

    private static func words(in text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .filter { !$0.isEmpty })
    }
}
