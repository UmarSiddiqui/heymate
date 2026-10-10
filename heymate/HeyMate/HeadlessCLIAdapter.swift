//
//  HeadlessCLIAdapter.swift
//  HeyMate
//
//  Argument builders + stdout parsers for each CLI. Launch/kill lives in
//  HeadlessAgentLauncher so the two adapters stay data-in / events-out.
//

import Foundation

struct HeadlessCLILaunchSpec {
    let executableName: String
    let arguments: [String]
    let currentDirectoryURL: URL
    /// Environment variables to remove from the child, so an executor running
    /// on a subscription sign-in never sees a provider API key.
    let environmentKeysToRemove: [String]
    /// Runtime-only values such as loopback bridge address and token. Kept
    /// out of process arguments so secrets never appear in command listings.
    let environmentOverrides: [String: String]
    /// Process-private scratch configuration roots. The process owner removes
    /// these after exit (or a failed launch) so one job cannot seed another.
    let temporaryDirectoriesToRemove: [URL]
    /// Whether the child reads stdin. Only attached jobs do — they answer tool
    /// approvals over `--input-format stream-json`. A sandbox job handed an
    /// idle pipe makes `claude -p` wait for input that is never coming, so
    /// those get /dev/null instead.
    let usesDuplexStandardInput: Bool
}

nonisolated enum OpenCodeRuntimeIsolation {
    static func makeConfigurationHome(
        fileManager: FileManager = .default
    ) -> URL {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("com.heymate.app", isDirectory: true)
            .appendingPathComponent("opencode-config", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        // OpenCode can create a missing root itself, but creating it here lets
        // us guarantee private permissions before any config lookup happens.
        try? fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    /// OpenCode keeps subscription/provider auth plus resumable sessions in
    /// XDG data, while config discovery also probes `~/.opencode`. Give the
    /// child an isolated HOME/config root but keep explicit data/state/cache
    /// locations so a plan can resume after approval without loading legacy
    /// home configuration.
    static func persistentRuntimeEnvironment(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        guard let home = processEnvironment["HOME"], home.hasPrefix("/") else {
            return [:]
        }

        let fallbacks = [
            "XDG_DATA_HOME": ".local/share",
            "XDG_STATE_HOME": ".local/state",
            "XDG_CACHE_HOME": ".cache"
        ]
        return fallbacks.reduce(into: [:]) { result, entry in
            let inherited = processEnvironment[entry.key]
            if let inherited, inherited.hasPrefix("/") {
                result[entry.key] = inherited
            } else {
                result[entry.key] = URL(fileURLWithPath: home, isDirectory: true)
                    .appendingPathComponent(entry.value, isDirectory: true)
                    .path
            }
        }
    }
}

protocol HeadlessCLIAdapter {
    var executor: HeadlessExecutor { get }

    /// True when HeyMate chooses the session id and passes it in, false when
    /// the CLI assigns one and we have to read it back off the stream.
    var preassignsSessionIdentifier: Bool { get }

    func launchSpec(
        workspaceURL: URL,
        leg: AgentRunLeg,
        origin: AgentRunOrigin,
        title: String,
        sessionIdentifier: String
    ) -> HeadlessCLILaunchSpec

    func events(fromStdoutLine line: String) -> [AgentEvent]
    func stdinPayloadForApproval(id: String, approve: Bool) -> Data?
}

/// The instruction leg two is given. Deliberately short: the plan is already
/// in the session, so re-stating it would only give the model a chance to
/// drift from the text the user actually approved.
///
/// The second sentence exists because a CLI exits 0 whether or not the work
/// got done: an agent refused a write says so in prose and still finishes
/// cleanly. A fixed first-line marker is the one signal HeyMate can read
/// without parsing free text.
let headlessAgentBlockedMarker = "HEYMATE_BLOCKED:"

let headlessAgentExecuteInstruction = "Execute the approved plan now. Do not expand its scope. If any part of the plan could not be completed, such as a permission refusal or a missing tool, begin your final message with \(headlessAgentBlockedMarker) and a one-line reason."

/// True when an agent's final message reports that it could not finish.
func headlessAgentReportsBlocked(_ finalMessage: String) -> Bool {
    finalMessage
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .hasPrefix(headlessAgentBlockedMarker)
}

struct OpenCodeRunAdapter: HeadlessCLIAdapter {
    let executor: HeadlessExecutor = .openCode

    /// OpenCode normally merges global, legacy-home, and project configuration
    /// even with `--pure`. HeyMate jobs instead get an isolated HOME and XDG
    /// configuration root, disable project discovery, and install a late
    /// permission override.
    /// This makes the first leg a real write-free plan rather than a
    /// convention that a project hook or custom agent can bypass.
    private static let emptyConfigurationJSON = #"{"mcp":{},"plugin":[]}"#
    private static let planningPermissionsJSON = #"{"*":"deny","read":"allow","glob":"allow","grep":"allow","list":"allow","lsp":"allow"}"#
    private static let executionPermissionsJSON = #"{"*":"deny","read":"allow","edit":"allow","glob":"allow","grep":"allow","list":"allow","bash":"deny","task":"deny","todowrite":"allow","lsp":"allow","external_directory":"deny","webfetch":"deny","websearch":"deny","question":"deny","doom_loop":"deny","skill":"deny","heymate_*":"allow"}"#

    /// OpenCode mints its own `ses_…` id, so leg one has to be run without a
    /// session argument and the id read out of the event stream.
    let preassignsSessionIdentifier = false

    /// `provider/model`, taken from the model the user picked in Settings.
    /// Without it `opencode run` silently falls back to whatever its own
    /// default is — usually a free model, never the one on screen.
    let modelIdentifier: String?

    let mcpConfigurationJSON: String?
    let mcpChildEnvironment: [String: String]
    /// Test-only fixed path. Production leaves this nil and gets a fresh
    /// private directory for every process leg.
    let isolatedConfigurationHomePath: String?

    func launchSpec(
        workspaceURL: URL,
        leg: AgentRunLeg,
        origin: AgentRunOrigin,
        title: String,
        sessionIdentifier: String
    ) -> HeadlessCLILaunchSpec {
        var arguments = [
            "run",
            "--pure",
            "--dir", workspaceURL.path,
            "--format", "json",
            "--title", title
        ]
        if let modelIdentifier, !modelIdentifier.isEmpty {
            arguments.append(contentsOf: ["--model", modelIdentifier])
        }
        if !sessionIdentifier.isEmpty {
            arguments.append(contentsOf: ["--session", sessionIdentifier])
        }

        let message: String
        switch leg {
        case .plan(let prompt):
            message = """
            \(AgentPlanBrief.planningContract)

            Task:
            \(prompt)
            """
        case .replan(let feedback):
            message = """
            \(AgentPlanBrief.replanContract)

            Feedback:
            \(feedback)
            """
        case .followUp(let instruction):
            message = """
            \(AgentPlanBrief.followUpContract)

            New request:
            \(instruction)
            """
        case .execute:
            _ = origin
            message = headlessAgentExecuteInstruction
        }
        arguments.append(message)

        let isolatedConfigurationHomeURL = isolatedConfigurationHomePath.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? OpenCodeRuntimeIsolation.makeConfigurationHome()
        var environmentOverrides = OpenCodeRuntimeIsolation
            .persistentRuntimeEnvironment()
        environmentOverrides.merge([
            // `XDG_CONFIG_HOME` blocks normal global config; HOME also blocks
            // OpenCode's independent legacy `~/.opencode` lookup. Its internal
            // test overrides are set too: inherited values can otherwise
            // redirect home or managed configuration into a writable folder.
            "HOME": isolatedConfigurationHomeURL.path,
            "XDG_CONFIG_HOME": isolatedConfigurationHomeURL.path,
            "OPENCODE_TEST_HOME": isolatedConfigurationHomeURL.path,
            "OPENCODE_TEST_MANAGED_CONFIG_DIR": isolatedConfigurationHomeURL
                .appendingPathComponent("managed", isDirectory: true)
                .path,
            "OPENCODE_DISABLE_PROJECT_CONFIG": "true",
            "OPENCODE_DISABLE_CLAUDE_CODE": "true",
            "OPENCODE_DISABLE_EXTERNAL_SKILLS": "true",
            "OPENCODE_DISABLE_DEFAULT_PLUGINS": "true",
            "OPENCODE_CONFIG_CONTENT": Self.emptyConfigurationJSON,
            "OPENCODE_PERMISSION": leg.isReadOnly
                ? Self.planningPermissionsJSON
                : Self.executionPermissionsJSON
        ]) { _, isolatedValue in isolatedValue }
        if case .execute = leg {
            environmentOverrides = mcpChildEnvironment
                .merging(environmentOverrides) { _, isolatedValue in isolatedValue }
            if let mcpConfigurationJSON, !mcpConfigurationJSON.isEmpty {
                environmentOverrides["OPENCODE_CONFIG_CONTENT"] = mcpConfigurationJSON
            }
        }

        return HeadlessCLILaunchSpec(
            executableName: executor.executableName,
            arguments: arguments,
            currentDirectoryURL: workspaceURL,
            environmentKeysToRemove: executor.environmentKeysToRemove,
            environmentOverrides: environmentOverrides,
            temporaryDirectoriesToRemove: isolatedConfigurationHomePath == nil
                ? [isolatedConfigurationHomeURL]
                : [],
            usesDuplexStandardInput: false
        )
    }

    func events(fromStdoutLine line: String) -> [AgentEvent] {
        OpenCodeRunParser.events(fromStdoutLine: line)
    }

    func stdinPayloadForApproval(id: String, approve: Bool) -> Data? {
        // OpenCode's non-interactive permission stdin is not a stable public
        // contract. Deny cancels the process instead of guessing a payload.
        _ = id
        _ = approve
        return nil
    }
}

struct ClaudePrintAdapter: HeadlessCLIAdapter {
    let executor: HeadlessExecutor = .claudeCode
    private static let emptyMCPConfigurationJSON = #"{"mcpServers":{}}"#

    /// `--session-id` takes a UUID of our choosing, so HeyMate never has to
    /// scrape an id out of the stream to resume.
    let preassignsSessionIdentifier = true

    /// Alias passed as `--model` (sonnet / opus / haiku). Nil keeps the CLI's
    /// own default, which is what we want until the user picks a chip.
    let modelIdentifier: String?

    /// `--effort` level. Nil keeps the CLI's default.
    var effort: String? = nil

    /// HeyMate's loopback server as an `--mcp-config` payload. Attached to
    /// working legs only, and only when it can actually run.
    var mcpConfigurationJSON: String? = nil
    /// Allow-list for that server. `acceptEdits` auto-approves file edits
    /// only, so without it every MCP call stalls as an ungranted permission.
    var mcpAllowedToolNames: [String] = []
    /// Bridge URL and token for the server, carried in the environment so
    /// they never appear on the child's command line.
    var mcpChildEnvironment: [String: String] = [:]

    func launchSpec(
        workspaceURL: URL,
        leg: AgentRunLeg,
        origin: AgentRunOrigin,
        title: String,
        sessionIdentifier: String
    ) -> HeadlessCLILaunchSpec {
        var arguments: [String] = []

        switch leg {
        case .plan(let prompt):
            arguments.append(contentsOf: ["-p", prompt])
        case .replan(let feedback):
            arguments.append(contentsOf: ["-p", feedback])
        case .followUp(let instruction):
            arguments.append(contentsOf: ["-p", instruction])
        case .execute:
            arguments.append(contentsOf: ["-p", headlessAgentExecuteInstruction])
        }

        arguments.append(contentsOf: [
            "--output-format", "stream-json",
            "--verbose",
            "--name", title,
            // User/project settings can install hooks before a model ever
            // gets a tool decision. HeyMate supplies no ambient setting
            // source; working legs add only reviewed MCP below.
            "--setting-sources", ""
        ])
        // Current Claude safe mode also disables explicitly supplied MCP, so a
        // working leg that carries HeyMate's server has to leave it off or the
        // mate loses its connected apps. `--setting-sources ""` still keeps
        // user and project hooks out, and `--strict-mcp-config` below keeps
        // every other MCP server out. Legs without the server stay safe.
        let workingMCPConfigurationJSON: String? = {
            guard case .execute = leg,
                  let mcpConfigurationJSON,
                  !mcpConfigurationJSON.isEmpty else { return nil }
            return mcpConfigurationJSON
        }()
        if workingMCPConfigurationJSON == nil {
            arguments.append("--safe-mode")
        }
        if let modelIdentifier, !modelIdentifier.isEmpty {
            arguments.append(contentsOf: ["--model", modelIdentifier])
        }
        if let effort, !effort.isEmpty {
            arguments.append(contentsOf: ["--effort", effort])
        }

        // A read-only leg is told what deal it is in. Plan mode enforces the
        // gate on its own — `ExitPlanMode` is disabled under `-p`, so the
        // model cannot let itself out — but a model that does not know why
        // its write tools are refusing spends the turn saying so instead of
        // planning.
        if let contract = AgentPlanBrief.contract(for: leg) {
            arguments.append(contentsOf: ["--append-system-prompt", contract])
        }

        arguments.append(contentsOf: [
            "--mcp-config", workingMCPConfigurationJSON ?? Self.emptyMCPConfigurationJSON,
            "--strict-mcp-config"
        ])
        if workingMCPConfigurationJSON != nil, !mcpAllowedToolNames.isEmpty {
            // A connector call still passes HeyMate's own approval gate on the
            // far side of the bridge; this only stops Claude asking twice.
            arguments.append(contentsOf: ["--allowedTools", mcpAllowedToolNames.joined(separator: ",")])
        }

        switch leg {
        case .plan:
            // First leg of the session, so the id is assigned rather than
            // resumed.
            if !sessionIdentifier.isEmpty {
                arguments.append(contentsOf: ["--session-id", sessionIdentifier])
            }
            arguments.append(contentsOf: ["--permission-mode", "plan"])
        case .replan, .followUp:
            arguments.append(contentsOf: ["--resume", sessionIdentifier])
            arguments.append(contentsOf: ["--permission-mode", "plan"])
        case .execute:
            arguments.append(contentsOf: ["--resume", sessionIdentifier])
            switch origin {
            case .sandbox:
                arguments.append(contentsOf: ["--permission-mode", "acceptEdits"])
            case .attached:
                // Someone else's repo still asks per tool, on top of the plan
                // the user already approved.
                arguments.append(contentsOf: [
                    "--permission-mode", "manual",
                    "--input-format", "stream-json"
                ])
            }

        }

        return HeadlessCLILaunchSpec(
            executableName: executor.executableName,
            arguments: arguments,
            currentDirectoryURL: workspaceURL,
            environmentKeysToRemove: executor.environmentKeysToRemove,
            environmentOverrides: workingMCPConfigurationJSON == nil ? [:] : mcpChildEnvironment,
            temporaryDirectoriesToRemove: [],
            usesDuplexStandardInput: leg == .execute && origin == .attached
        )
    }

    func events(fromStdoutLine line: String) -> [AgentEvent] {
        ClaudeStreamJSONParser.events(fromStdoutLine: line)
    }

    func stdinPayloadForApproval(id: String, approve: Bool) -> Data? {
        ClaudeStreamJSONParser.controlResponseJSON(requestID: id, approve: approve)
    }
}

/// `codex exec --json` with a read-only sandbox on planning legs and
/// workspace-write after the user approves. Session resume is
/// `codex exec resume <thread>`.
struct CodexExecAdapter: HeadlessCLIAdapter {
    let executor: HeadlessExecutor = .codex
    let preassignsSessionIdentifier = false
    let modelIdentifier: String?
    let reasoningEffort: String?
    let mcpConfigurationArguments: [String]
    let mcpChildEnvironment: [String: String]

    func launchSpec(
        workspaceURL: URL,
        leg: AgentRunLeg,
        origin: AgentRunOrigin,
        title: String,
        sessionIdentifier: String
    ) -> HeadlessCLILaunchSpec {
        _ = title
        var arguments = [
            "exec",
            "--json",
            "--ignore-user-config",
            "--skip-git-repo-check",
            "--color", "never",
            "-C", workspaceURL.path
        ]
        if let modelIdentifier, !modelIdentifier.isEmpty {
            arguments.append(contentsOf: ["-m", modelIdentifier])
        }
        if let reasoningEffort, !reasoningEffort.isEmpty {
            arguments.append(contentsOf: [
                "-c", "model_reasoning_effort=\"\(reasoningEffort)\""
            ])
        }

        let sandbox: String
        switch (leg, origin) {
        case (.execute, .sandbox):
            sandbox = "workspace-write"
        case (.execute, .attached):
            sandbox = "workspace-write"
        case (.plan, _), (.replan, _), (.followUp, _):
            sandbox = "read-only"
        }
        arguments.append(contentsOf: ["--sandbox", sandbox])

        if case .execute = leg {
            arguments.append(contentsOf: mcpConfigurationArguments)
        }

        switch leg {
        case .plan(let prompt):
            arguments.append("""
            \(AgentPlanBrief.planningContract)

            Task:
            \(prompt)
            """)
        case .replan(let feedback):
            arguments.append(contentsOf: [
                "resume",
                sessionIdentifier,
                """
                \(AgentPlanBrief.replanContract)

                Feedback:
                \(feedback)
                """
            ])
        case .followUp(let instruction):
            arguments.append(contentsOf: [
                "resume",
                sessionIdentifier,
                """
                \(AgentPlanBrief.followUpContract)

                New request:
                \(instruction)
                """
            ])
        case .execute:
            arguments.append(contentsOf: [
                "resume",
                sessionIdentifier,
                headlessAgentExecuteInstruction
            ])
        }

        return HeadlessCLILaunchSpec(
            executableName: executor.executableName,
            arguments: arguments,
            currentDirectoryURL: workspaceURL,
            environmentKeysToRemove: executor.environmentKeysToRemove,
            environmentOverrides: leg.isReadOnly ? [:] : mcpChildEnvironment,
            temporaryDirectoriesToRemove: [],
            usesDuplexStandardInput: false
        )
    }

    func events(fromStdoutLine line: String) -> [AgentEvent] {
        CodexJSONLParser.events(fromStdoutLine: line)
    }

    func stdinPayloadForApproval(id: String, approve: Bool) -> Data? {
        _ = id
        _ = approve
        return nil
    }
}

enum HeadlessCLIAdapterFactory {
    static func adapter(
        for executor: HeadlessExecutor,
        openCodeModelIdentifier: String? = nil,
        claudeModelIdentifier: String? = nil,
        claudeEffort: String? = nil,
        codexModelIdentifier: String? = nil,
        codexReasoningEffort: String? = nil,
        openCodeMCPConfigurationJSON: String? = nil,
        claudeMCPConfigurationJSON: String? = nil,
        claudeMCPAllowedToolNames: [String] = [],
        codexMCPConfigurationArguments: [String] = [],
        mcpChildEnvironment: [String: String] = [:],
        openCodeIsolatedConfigurationHomePath: String? = nil
    ) -> HeadlessCLIAdapter {
        switch executor {
        case .openCode:
            return OpenCodeRunAdapter(
                modelIdentifier: openCodeModelIdentifier,
                mcpConfigurationJSON: openCodeMCPConfigurationJSON,
                mcpChildEnvironment: mcpChildEnvironment,
                isolatedConfigurationHomePath: openCodeIsolatedConfigurationHomePath
            )
        case .claudeCode:
            return ClaudePrintAdapter(
                modelIdentifier: claudeModelIdentifier,
                effort: claudeEffort,
                mcpConfigurationJSON: claudeMCPConfigurationJSON,
                mcpAllowedToolNames: claudeMCPAllowedToolNames,
                mcpChildEnvironment: mcpChildEnvironment
            )
        case .codex:
            return CodexExecAdapter(
                modelIdentifier: codexModelIdentifier,
                reasoningEffort: codexReasoningEffort,
                mcpConfigurationArguments: codexMCPConfigurationArguments,
                mcpChildEnvironment: mcpChildEnvironment
            )
        }
    }
}
