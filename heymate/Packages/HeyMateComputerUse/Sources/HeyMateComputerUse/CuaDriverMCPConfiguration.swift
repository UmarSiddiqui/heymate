//
//  CuaDriverMCPConfiguration.swift
//  HeyMateComputerUse
//
//  How the Cua server is handed to a Claude Code or Codex child.
//

import Foundation

public enum CuaDriverMCPConfiguration {

    /// The server's name inside a child. Claude Code exposes its tools as
    /// `mcp__cua__<tool>`.
    public static let serverName = "cua"

    /// The `mcpServers` entry for a Claude Code `--mcp-config`.
    public static func claudeServerEntry(executable: URL) -> [String: Any] {
        ["command": executable.path, "args": ["mcp"]]
    }

    /// Claude Code's `--allowedTools` names for `tools`. Each tool is named
    /// on its own: the bare server name would allow every tool, including
    /// the refused ones and any a future release adds.
    public static func claudeAllowedToolNames(_ tools: [String] = CuaDriverToolPolicy.approvedLegTools) -> [String] {
        tools.map { "mcp__\(serverName)__\($0)" }
    }

    /// `codex exec -c` overrides that add the server with only `tools`
    /// enabled. `approve`, as for HeyMate's own server: under `codex exec`
    /// the approval policy is `never`, so anything else turns every call
    /// into a refusal. The leg itself was already approved by the user.
    public static func codexArguments(
        executable: URL,
        tools: [String] = CuaDriverToolPolicy.approvedLegTools
    ) -> [String] {
        let enabled = tools.map(quoted).joined(separator: ",")
        return [
            "-c", "mcp_servers.\(serverName).command=\(quoted(executable.path))",
            "-c", "mcp_servers.\(serverName).args=[\"mcp\"]",
            "-c", "mcp_servers.\(serverName).enabled_tools=[\(enabled)]",
            "-c", "mcp_servers.\(serverName).default_tools_approval_mode=\"approve\""
        ]
    }

    /// A TOML basic string. Paths and tool names never carry control
    /// characters; quotes and backslashes are escaped anyway.
    static func quoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
