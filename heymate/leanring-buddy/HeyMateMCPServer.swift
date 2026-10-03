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
        "heymate_clear",
        "heymate_create_mate"
    ]

    /// How Claude Code names an MCP tool once the server is loaded.
    ///
    /// These have to be allow-listed explicitly: `--permission-mode acceptEdits`
    /// auto-approves *file edits* only, so without this a spawned agent gets
    /// "Claude requested permissions to use mcp__heymate__heymate_point, but
    /// you haven't granted it yet" and the call never reaches the bridge.
    /// Verified against a live child.
    static func claudeCodeToolNames() -> [String] {
        // The bare server name allows every tool this server exposes, which
        // is the only form that can cover the connector tools: those are
        // discovered from the user's live sessions at `tools/list` time and
        // have no names to enumerate when this list is built.
        ["mcp__\(serverName)"] + toolNames.map { "mcp__\(serverName)__\($0)" }
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
        bridgePort: UInt16 = HeyMateExternalControlBridge.processPort,
        bridgeToken: String? = HeyMateExternalControlAuth.resolvedToken()
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
        bridgeEnvironment: [String: String] = childEnvironment(),
        enabledTools: [String]? = toolNames
    ) -> [String] {
        guard let runtime = availableRuntime(), let scriptURL = seedScript() else { return [] }
        return codexConfigurationArguments(
            runtimeURL: runtime.runtimeURL,
            scriptURL: scriptURL,
            bridgeEnvironment: bridgeEnvironment,
            enabledTools: enabledTools
        )
    }

    /// Pure argument construction kept separate from runtime discovery and
    /// script seeding so the approval-to-execution boundary can be tested.
    /// `enabledTools: nil` omits the allow-list entirely, which is what a
    /// Talk turn needs: its connector tools are discovered from the user's
    /// live sessions when the child asks for `tools/list`, so naming them
    /// here would filter out exactly the ones the turn exists to reach.
    static func codexConfigurationArguments(
        runtimeURL: URL,
        scriptURL: URL,
        bridgeEnvironment: [String: String],
        enabledTools: [String]? = toolNames
    ) -> [String] {
        let command = jsonString(runtimeURL.path)
        let args = "[\(jsonString(scriptURL.path))]"
        let environmentVariables = bridgeEnvironment.keys.sorted().map(jsonString).joined(separator: ",")
        var arguments = [
            "-c", "mcp_servers.\(serverName).command=\(command)",
            "-c", "mcp_servers.\(serverName).args=\(args)",
            "-c", "mcp_servers.\(serverName).env_vars=[\(environmentVariables)]"
        ]
        if let enabledTools {
            let tools = enabledTools.map(jsonString).joined(separator: ",")
            arguments.append(contentsOf: ["-c", "mcp_servers.\(serverName).enabled_tools=[\(tools)]"])
        }
        // `approve`, not `auto`: under `codex exec` the approval policy is
        // `never`, and `auto` still asks — the call comes back "MCP tool call
        // requires approval, but approval policy is never" and never reaches
        // the bridge. Verified against a live child. Auto-approving here is
        // the codex layer only; a connector tool still passes HeyMate's own
        // approval gate on the far side of the bridge.
        arguments.append(contentsOf: [
            "-c", "mcp_servers.\(serverName).default_tools_approval_mode=\"approve\""
        ])
        return arguments
    }

    private static func jsonString(_ value: String) -> String {
        // JSONSerialization rejects a top-level String unless fragments are
        // explicitly enabled by throwing an Objective-C exception, which a
        // Swift `try?` cannot catch. That exception used to unwind the Approve
        // button after it persisted "starting work" but before Codex spawned.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(value),
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
      },
      {
        name: "heymate_create_mate",
        description:
          "Add a mate (a specialist with its own chat and workspace folder) to the user's HeyMate roster. This is the only way to create a mate: a job cannot edit HeyMate's own configuration files. Pass the mate's job in one sentence; name is optional and is generated from the job when omitted.",
        inputSchema: {
          type: "object",
          properties: {
            name: { type: "string", description: "Optional. Must be unique among the user's mates." },
            job: { type: "string", description: "What this mate does, in one sentence." }
          },
          required: ["job"]
        },
        path: "/mate/create",
        returnsResult: true
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

    // The user's connected apps, borrowed rather than re-opened. HeyMate
    // already holds one live session per connector; asking it what that
    // session exposes is what lets a turn reach Gmail or YouTube without
    // spawning a second server and paying a cold start for every question.
    async function fetchConnectorTools() {
      try {
        const parsed = JSON.parse(await callBridge("/connector/tools", {}));
        if (!parsed || !Array.isArray(parsed.tools)) return [];
        return parsed.tools
          .filter((tool) => tool && typeof tool.name === "string" && tool.name)
          .map((tool) => ({
            name: tool.name,
            description: tool.description || "",
            inputSchema: tool.inputSchema || { type: "object", properties: {} },
            connector: true
          }));
      } catch {
        // A HeyMate that is not listening, or a token this server was not
        // given, means no connected apps this turn — not a dead server. The
        // overlay tools still work.
        return [];
      }
    }

    async function handleToolCall(id, params) {
      const name = params?.name;
      const tool = TOOLS.find((candidate) => candidate.name === name);

      try {
        if (!tool) {
          const raw = await callBridge("/connector/call", {
            tool: name,
            arguments: JSON.stringify(params?.arguments || {})
          });
          const parsed = JSON.parse(raw);
          respond(id, {
            content: [{ type: "text", text: String(parsed.text ?? "") }],
            isError: parsed.isError === true
          });
          return;
        }

        const body = { ...(params.arguments || {}) };
        const raw = await callBridge(tool.path, body);
        // Overlay tools have nothing worth reading back. A tool that changes
        // the roster does: the agent needs the name HeyMate actually chose.
        respond(id, {
          content: [{ type: "text", text: tool.returnsResult ? raw : "ok" }]
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
        case "tools/list": {
          const connectorTools = await fetchConnectorTools();
          respond(id, {
            tools: TOOLS.concat(connectorTools).map(({ name, description, inputSchema }) => ({
              name,
              description,
              inputSchema
            }))
          });
          return;
        }
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
