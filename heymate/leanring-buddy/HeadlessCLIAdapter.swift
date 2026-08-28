//
//  HeadlessCLIAdapter.swift
//  leanring-buddy
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
    /// Whether the child reads stdin. Only attached jobs do — they answer tool
    /// approvals over `--input-format stream-json`. A sandbox job handed an
    /// idle pipe makes `claude -p` wait for input that is never coming, so
    /// those get /dev/null instead.
    let usesDuplexStandardInput: Bool
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
let headlessAgentExecuteInstruction = "Execute the approved plan now. Do not expand its scope."

struct OpenCodeRunAdapter: HeadlessCLIAdapter {
    let executor: HeadlessExecutor = .openCode

    /// OpenCode mints its own `ses_…` id, so leg one has to be run without a
    /// session argument and the id read out of the event stream.
    let preassignsSessionIdentifier = false

    /// `provider/model`, taken from the model the user picked in Settings.
    /// Without it `opencode run` silently falls back to whatever its own
    /// default is — usually a free model, never the one on screen.
    let modelIdentifier: String?
    let mcpConfigurationJSON: String?
    let mcpChildEnvironment: [String: String]

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

        switch leg {
        case .plan(let prompt):
            // The `plan` agent is read-only: it answers with a plan and calls
            // no write tools at all.
            arguments.append(contentsOf: ["--agent", "plan"])
            arguments.append(prompt)
        case .replan(let feedback):
            // The `plan` agent already knows how to plan; what it does not
            // know is that the text arriving is a rejection of its last one.
            arguments.append(contentsOf: ["--agent", "plan"])
            arguments.append("The person read your previous plan and asked for changes. Revise it to match: \(feedback)")
        case .followUp(let instruction):
            arguments.append(contentsOf: ["--agent", "plan"])
            arguments.append("The work you already planned and carried out in this session is done. The person now wants something further. Check the current state, then plan only the new work: \(instruction)")
        case .execute:
            // Sandbox: auto-approve file edits, because the user already
            // approved the plan that describes them. Attached: leave the CLI's
            // ask path in place — we never pass --auto on someone else's repo.
            if origin == .sandbox {
                arguments.append("--auto")
            }
            arguments.append(headlessAgentExecuteInstruction)
        }

        var environmentOverrides: [String: String] = [:]
        if case .execute = leg,
           let mcpConfigurationJSON,
           !mcpConfigurationJSON.isEmpty {
            environmentOverrides = mcpChildEnvironment
            environmentOverrides["OPENCODE_CONFIG_CONTENT"] = mcpConfigurationJSON
        }

        return HeadlessCLILaunchSpec(
            executableName: executor.executableName,
            arguments: arguments,
            currentDirectoryURL: workspaceURL,
            environmentKeysToRemove: executor.environmentKeysToRemove,
            environmentOverrides: environmentOverrides,
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

    /// `--session-id` takes a UUID of our choosing, so HeyMate never has to
    /// scrape an id out of the stream to resume.
    let preassignsSessionIdentifier = true

    /// Inline `--mcp-config` payload giving the child the HeyMate tools —
    /// point, caption, speak, screenshot. Nil when no JavaScript runtime is
    /// available, in which case the job runs without them.
    let mcpConfigurationJSON: String?
    let mcpChildEnvironment: [String: String]

    /// Alias passed as `--model` (sonnet / opus / haiku). Nil keeps the CLI's
    /// own default, which is what we want until the user picks a chip.
    let modelIdentifier: String?

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
            "--name", title
        ])
        if let modelIdentifier, !modelIdentifier.isEmpty {
            arguments.append(contentsOf: ["--model", modelIdentifier])
        }

        // A read-only leg is told what deal it is in. Plan mode enforces the
        // gate on its own — `ExitPlanMode` is disabled under `-p`, so the
        // model cannot let itself out — but a model that does not know why
        // its write tools are refusing spends the turn saying so instead of
        // planning.
        if let contract = AgentPlanBrief.contract(for: leg) {
            arguments.append(contentsOf: ["--append-system-prompt", contract])
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

            // HeyMate's own tools are attached to the working leg only. A
            // planning leg is supposed to be invisible, and speaking or moving
            // the cursor is the opposite of that.
            //
            // `--strict-mcp-config` matters as much as the config itself: without
            // it the child inherits every MCP server the user has configured
            // for their own Claude Code — Gmail, Stripe, Figma — which is both
            // clutter and a surface a sandbox job has no business touching.
            if let mcpConfigurationJSON, !mcpConfigurationJSON.isEmpty {
                arguments.append(contentsOf: ["--mcp-config", mcpConfigurationJSON])
                arguments.append("--strict-mcp-config")
                arguments.append("--allowedTools")
                arguments.append(contentsOf: HeyMateMCPServer.claudeCodeToolNames())
            }
        }

        return HeadlessCLILaunchSpec(
            executableName: executor.executableName,
            arguments: arguments,
            currentDirectoryURL: workspaceURL,
            environmentKeysToRemove: executor.environmentKeysToRemove,
            environmentOverrides: leg.isReadOnly ? [:] : mcpChildEnvironment,
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
            arguments.append(prompt)
        case .replan(let feedback):
            arguments.append(contentsOf: [
                "resume",
                sessionIdentifier,
                "The person read your previous plan and asked for changes. Revise it to match: \(feedback)"
            ])
        case .followUp(let instruction):
            arguments.append(contentsOf: [
                "resume",
                sessionIdentifier,
                "The work you already planned and carried out in this session is done. The person now wants something further. Check the current state, then plan only the new work: \(instruction)"
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
        codexModelIdentifier: String? = nil,
        codexReasoningEffort: String? = nil,
        mcpConfigurationJSON: String? = nil,
        openCodeMCPConfigurationJSON: String? = nil,
        codexMCPConfigurationArguments: [String] = [],
        mcpChildEnvironment: [String: String] = [:]
    ) -> HeadlessCLIAdapter {
        switch executor {
        case .openCode:
            return OpenCodeRunAdapter(
                modelIdentifier: openCodeModelIdentifier,
                mcpConfigurationJSON: openCodeMCPConfigurationJSON,
                mcpChildEnvironment: mcpChildEnvironment
            )
        case .claudeCode:
            return ClaudePrintAdapter(
                mcpConfigurationJSON: mcpConfigurationJSON,
                mcpChildEnvironment: mcpChildEnvironment,
                modelIdentifier: claudeModelIdentifier
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
