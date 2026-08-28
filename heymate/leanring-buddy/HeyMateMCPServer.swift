//
//  HeyMateMCPServer.swift
//  leanring-buddy
//
//  Lets a spawned agent reach back into HeyMate.
//
//  A headless CLI can already read and write the workspace folder. What it
//  cannot do is point at something on the user's screen, say a sentence out
//  loud, or look at what the user is looking at — and those are the things
//  that make an agent feel like it lives in the app rather than in a folder.
//
//  `HeyMateExternalControlBridge` already exposes exactly that surface, on
//  loopback, behind an optional token, with click/drag/type refused by
//  design. This type wraps it as a stdio MCP server so any CLI that speaks
//  MCP can call it.
//
//  The server ships as a small dependency-free script seeded into Application
//  Support (the same approach `DefaultSkillCatalog` uses for skills) rather
//  than as a bundled resource, so there is no build-phase to get wrong, and it
//  runs under whichever of `node` / `bun` is on the login PATH.
//

import Foundation

nonisolated enum HeyMateMCPServer {

    static let serverName = "heymate"
    private static let scriptFileName = "heymate-mcp.mjs"

    /// The tools the server exposes, in the order the script declares them.
    /// Kept here so the allow-list handed to a child cannot drift from what
    /// the server actually implements.
    static let toolNames = [
        "heymate_point",
        "heymate_caption",
        "heymate_speak",
        "heymate_screenshot",
        "heymate_clear"
    ]

    /// How Claude Code names an MCP tool once the server is loaded.
    ///
    /// These have to be allow-listed explicitly: `--permission-mode acceptEdits`
    /// auto-approves *file edits* only, so without this a spawned agent gets
    /// "Claude requested permissions to use mcp__heymate__heymate_point, but
    /// you haven't granted it yet" and the call never reaches the bridge.
    /// Verified against a live child.
    static func claudeCodeToolNames() -> [String] {
        // Composio's meta-tools ride the same allow-list. They are read from
        // storage rather than passed in because the adapter that builds the
        // argument list has no injection point; `ComposioAgentAttachment`
        // applies the same gate the config JSON does, so the two cannot
        // disagree about whether Composio is attached.
        toolNames.map { "mcp__\(serverName)__\($0)" } + ComposioAgentAttachment.claudeCodeToolNames()
    }

    /// Runtimes tried in order. Both are checked against the login PATH, so a
    /// GUI app's starved environment does not hide them.
    private static let candidateRuntimes = ["node", "bun"]

    // MARK: - Availability

    struct Availability: Equatable {
        var runtimeName: String
        var runtimeURL: URL
    }

    static func availableRuntime() -> Availability? {
        for runtimeName in candidateRuntimes {
            if let runtimeURL = LoginShellExecutableResolver.resolveExecutable(named: runtimeName) {
                return Availability(runtimeName: runtimeName, runtimeURL: runtimeURL)
            }
        }
        return nil
    }

    // MARK: - Seeding

    static func scriptURL() -> URL {
        supportDirectoryURL().appendingPathComponent(scriptFileName, isDirectory: false)
    }

    private static func supportDirectoryURL() -> URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupportDirectory
            .appendingPathComponent("heymate", isDirectory: true)
            .appendingPathComponent("mcp", isDirectory: true)
    }

    /// Writes the script if it is missing or stale. Rewriting on mismatch
    /// rather than only on absence means a HeyMate update cannot leave an old
    /// server behind talking a protocol the app no longer speaks.
    @discardableResult
    static func seedScript(fileManager: FileManager = .default) -> URL? {
        let directoryURL = supportDirectoryURL()
        let fileURL = directoryURL.appendingPathComponent(scriptFileName, isDirectory: false)

        let existingSource = try? String(contentsOf: fileURL, encoding: .utf8)
        if existingSource == serverSource { return fileURL }

        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try serverSource.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL
        } catch {
            return nil
        }
    }

    // MARK: - Child configuration

    /// Bridge values travel in child environment, never CLI arguments. A
    /// token embedded in `--mcp-config` or `-c` is visible to every process
    /// that can inspect the child command line.
    static func childEnvironment(
        bridgePort: UInt16 = HeyMateExternalControlBridge.resolvedPort(),
        bridgeToken: String? = HeyMateSecrets.lookup(HeyMateExternalControlAuth.secretsKey)
    ) -> [String: String] {
        var environment = [
            "HEYMATE_BRIDGE_URL": "http://127.0.0.1:\(bridgePort)"
        ]
        if let bridgeToken, !bridgeToken.isEmpty {
            environment[HeyMateExternalControlAuth.secretsKey] = bridgeToken
        }
        return environment
    }

    /// The `--mcp-config` payload handed to a Claude Code child.
    ///
    /// Returns nil when there is no JavaScript runtime or the script could not
    /// be written — the job then runs without the HeyMate tools rather than
    /// failing, because pointing at the screen is a bonus, not the work.
    static func claudeCodeConfigurationJSON(
        additionalServers: [String: Any]? = nil
    ) -> String? {
        var servers: [String: Any] = [:]
        if let runtime = availableRuntime(), let scriptURL = seedScript() {
            servers[serverName] = [
                "command": runtime.runtimeURL.path,
                "args": [scriptURL.path]
            ]
        }
        for (name, entry) in additionalServers ?? [:] {
            servers[name] = entry
        }
        // No servers at all is a normal answer: the job then runs without any
        // MCP tools rather than failing, and the caller omits the flag.
        guard !servers.isEmpty else { return nil }

        let configuration: [String: Any] = ["mcpServers": servers]
        guard let data = try? JSONSerialization.data(withJSONObject: configuration),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    /// Runtime-only OpenCode config. Inline config has highest local
    /// precedence, so this adds HeyMate without writing `opencode.json` into
    /// user projects. Environment values are references, not embedded
    /// secrets.
    static func openCodeConfigurationJSON(
        bridgeEnvironment: [String: String] = childEnvironment()
    ) -> String? {
        guard let runtime = availableRuntime(), let scriptURL = seedScript() else { return nil }
        var serverEnvironment: [String: String] = [:]
        for key in bridgeEnvironment.keys {
            serverEnvironment[key] = "{env:\(key)}"
        }
        let configuration: [String: Any] = [
            "mcp": [
                serverName: [
                    "type": "local",
                    "command": [runtime.runtimeURL.path, scriptURL.path],
                    "enabled": true,
                    "environment": serverEnvironment
                ]
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: configuration),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    /// `codex exec --ignore-user-config` prevents personal MCP servers and
    /// hooks leaking into a HeyMate job. These overrides add back only
    /// HeyMate's loopback server for write-enabled legs.
    static func codexConfigurationArguments(
        bridgeEnvironment: [String: String] = childEnvironment()
    ) -> [String] {
        guard let runtime = availableRuntime(), let scriptURL = seedScript() else { return [] }
        let command = jsonString(runtime.runtimeURL.path)
        let args = "[\(jsonString(scriptURL.path))]"
        let environmentVariables = bridgeEnvironment.keys.sorted().map(jsonString).joined(separator: ",")
        let tools = toolNames.map(jsonString).joined(separator: ",")
        return [
            "-c", "mcp_servers.\(serverName).command=\(command)",
            "-c", "mcp_servers.\(serverName).args=\(args)",
            "-c", "mcp_servers.\(serverName).env_vars=[\(environmentVariables)]",
            "-c", "mcp_servers.\(serverName).enabled_tools=[\(tools)]",
            "-c", "mcp_servers.\(serverName).default_tools_approval_mode=\"auto\""
        ]
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return encoded
    }

    // MARK: - The server

    /// Dependency-free MCP stdio server. Kept as source rather than a bundled
    /// file so seeding cannot depend on a Copy Files build phase.
    static let serverSource = #"""
    // heymate-mcp — a stdio MCP server that forwards to HeyMate's loopback
    // control bridge. Seeded by HeyMateMCPServer.swift; edit it there.
    //
    // The bridge deliberately refuses click, drag, and type. This server does
    // not add them back: an agent may show the user where something is and
    // say why, but it may not press it.

    import { createInterface } from "node:readline";

    const BRIDGE_URL = (process.env.HEYMATE_BRIDGE_URL || "http://127.0.0.1:18732").replace(/\/$/, "");
    const BRIDGE_TOKEN = process.env.HEYMATE_BRIDGE_TOKEN || "";
    const PROTOCOL_VERSION_FALLBACK = "2025-06-18";

    const TOOLS = [
      {
        name: "heymate_point",
        description:
          "Move HeyMate's on-screen cursor to a point and optionally caption it. Use this to show the user where something is. Coordinates are screen pixels with the origin at the top left. This only points — it cannot click.",
        inputSchema: {
          type: "object",
          properties: {
            x: { type: "number", description: "Screen x in pixels." },
            y: { type: "number", description: "Screen y in pixels." },
            caption: { type: "string", description: "Short label shown beside the cursor." },
            durationMs: { type: "number", description: "How long to stay visible. Default 4000." }
          },
          required: ["x", "y"]
        },
        path: "/cursor"
      },
      {
        name: "heymate_caption",
        description:
          "Show a short line of text on screen without moving the cursor. Good for narrating a step the user should watch for.",
        inputSchema: {
          type: "object",
          properties: {
            text: { type: "string" },
            x: { type: "number" },
            y: { type: "number" },
            durationMs: { type: "number" }
          },
          required: ["text"]
        },
        path: "/caption"
      },
      {
        name: "heymate_speak",
        description:
          "Say a sentence out loud in HeyMate's voice. Keep it to one sentence — this interrupts the user.",
        inputSchema: {
          type: "object",
          properties: { text: { type: "string" } },
          required: ["text"]
        },
        path: "/speak"
      },
      {
        name: "heymate_screenshot",
        description:
          "Ask HeyMate to capture the user's screen. Pass focused:true for just the frontmost window.",
        inputSchema: {
          type: "object",
          properties: {
            focused: { type: "boolean", description: "Frontmost window only. Default false." }
          }
        },
        path: "/screenshot"
      },
      {
        name: "heymate_clear",
        description: "Remove any cursor or caption this session put on screen.",
        inputSchema: { type: "object", properties: {} },
        path: "/clear"
      }
    ];

    function writeMessage(message) {
      process.stdout.write(JSON.stringify(message) + "\n");
    }

    function respond(id, result) {
      if (id === undefined || id === null) return;
      writeMessage({ jsonrpc: "2.0", id, result });
    }

    function respondError(id, code, message) {
      if (id === undefined || id === null) return;
      writeMessage({ jsonrpc: "2.0", id, error: { code, message } });
    }

    async function callBridge(path, body) {
      const headers = { "content-type": "application/json" };
      if (BRIDGE_TOKEN) headers.authorization = "Bearer " + BRIDGE_TOKEN;

      const response = await fetch(BRIDGE_URL + path, {
        method: "POST",
        headers,
        body: JSON.stringify(body || {})
      });

      const text = await response.text();
      if (!response.ok) {
        throw new Error("HeyMate bridge returned " + response.status + ": " + text.slice(0, 200));
      }
      return text;
    }

    async function handleToolCall(id, params) {
      const tool = TOOLS.find((candidate) => candidate.name === params?.name);
      if (!tool) {
        respondError(id, -32602, "Unknown tool: " + params?.name);
        return;
      }

      try {
        const body = { ...(params.arguments || {}) };
        await callBridge(tool.path, body);
        respond(id, {
          content: [{ type: "text", text: "ok" }]
        });
      } catch (error) {
        // Reported as a tool result, not a protocol error: a screen the agent
        // could not draw on is a fact about the world, not a broken call.
        respond(id, {
          content: [{ type: "text", text: String(error && error.message ? error.message : error) }],
          isError: true
        });
      }
    }

    async function handleMessage(message) {
      const { id, method, params } = message;

      switch (method) {
        case "initialize":
          respond(id, {
            protocolVersion: params?.protocolVersion || PROTOCOL_VERSION_FALLBACK,
            capabilities: { tools: {} },
            serverInfo: { name: "heymate", version: "1.0.0" }
          });
          return;
        case "notifications/initialized":
        case "notifications/cancelled":
          return;
        case "ping":
          respond(id, {});
          return;
        case "tools/list":
          respond(id, {
            tools: TOOLS.map(({ name, description, inputSchema }) => ({
              name,
              description,
              inputSchema
            }))
          });
          return;
        case "tools/call":
          await handleToolCall(id, params);
          return;
        default:
          respondError(id, -32601, "Method not found: " + method);
      }
    }

    const reader = createInterface({ input: process.stdin });
    reader.on("line", (line) => {
      const trimmed = line.trim();
      if (!trimmed) return;
      let message;
      try {
        message = JSON.parse(trimmed);
      } catch {
        return;
      }
      handleMessage(message).catch((error) => {
        respondError(message?.id, -32603, String(error && error.message ? error.message : error));
      });
    });
    reader.on("close", () => process.exit(0));
    """#
}
