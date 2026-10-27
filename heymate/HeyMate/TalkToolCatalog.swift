//
//  TalkToolCatalog.swift
//  HeyMate
//
//  What the Talk model can call mid-answer, beyond text.
//
//  Local actions are always available — start a timer, set a reminder,
//  open an app, change the volume, start/continue durable work, inspect jobs
//  and owned results, open/reveal deliverables, and choose a conversation path —
//  plus one entry per tool every connected MCP connector currently
//  exposes through `ConnectorRuntime`. One catalog so the system prompt's
//  "connected tools" list, the JSON schema sent to the model, and
//  `CompanionManager`'s dispatcher all agree on what a tool name means.
//
//  Nothing here executes anything. Dispatch and the connector approval
//  gate live in `CompanionManager+TalkTools.swift`, next to the other
//  manager-owned stores a tool call needs (the timer store, the
//  connector runtime, the approval coordinator).
//

import Foundation

/// Where a tool's implementation lives, and — for a connector tool — the
/// risk level the approval gate should judge it against.
enum TalkToolOrigin {
    case local
    case connector(connectorIdentifier: String, connectorDisplayName: String, maximumRisk: ConnectorToolRisk)
}

/// One tool the model may call this turn, and where to route the call.
struct TalkTool {
    let toolDefinition: AssistantToolDefinition
    let origin: TalkToolOrigin
}

enum TalkToolCatalog {

    // MARK: Local tool names

    static let startTimerToolName = "start_timer"
    static let setReminderToolName = "set_reminder"
    static let openApplicationToolName = "open_app"
    static let setSystemVolumeToolName = "set_volume"
    static let startMateWorkToolName = HarnessToolName.startMateWork.rawValue
    static let sendToMateToolName = HarnessToolName.sendToMate.rawValue
    static let getMateStatusToolName = HarnessToolName.getMateStatus.rawValue
    static let answerRequestToolName = HarnessToolName.answerRequest.rawValue
    static let askDeeperToolName = HarnessToolName.askDeeper.rawValue

    /// Local tools a Pi turn also gets through the scoped bridge, so one mate
    /// can hand work to another. start_mate_work is left out on purpose: a
    /// Pi mate does its own work rather than spawning native runs for itself.
    static let piDelegationToolNames: Set<String> = [sendToMateToolName, getMateStatusToolName, answerRequestToolName]

    /// Every tool available this turn: the local actions, always present,
    /// plus one per tool from every connector `ConnectorRuntime` currently
    /// has a live MCP session for.
    @MainActor
    static func availableTools(connectorRuntime: ConnectorRuntime) -> [TalkTool] {
        var tools = localTools
        for namespacedTool in connectorRuntime.availableMCPTools {
            guard let connector = ConnectorCatalog.connector(withID: namespacedTool.connectorID) else { continue }
            tools.append(
                TalkTool(
                    toolDefinition: AssistantToolDefinition(
                        name: namespacedTool.id,
                        description: "[\(namespacedTool.connectorDisplayName)] \(namespacedTool.tool.description)",
                        inputSchemaJSON: namespacedTool.tool.inputSchemaJSON
                    ),
                    origin: .connector(
                        connectorIdentifier: namespacedTool.connectorID,
                        connectorDisplayName: namespacedTool.connectorDisplayName,
                        maximumRisk: connector.maximumRisk
                    )
                )
            )
        }
        return tools
    }

    static func tool(named toolName: String, in tools: [TalkTool]) -> TalkTool? {
        tools.first { $0.toolDefinition.name == toolName }
    }

    /// Parses one tool call's raw JSON arguments into a dictionary the
    /// dispatcher can read. An empty or malformed payload becomes an empty
    /// dictionary rather than throwing, so a missing-required-argument case
    /// is reported back to the model as a normal tool error instead of
    /// crashing the whole turn.
    static func arguments(fromInputArgumentsJSON inputArgumentsJSON: String) -> [String: Any] {
        guard let data = inputArgumentsJSON.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return parsed
    }

    /// Short, human-readable rendering of a tool call's arguments for the
    /// connector approval card — "to: sam@example.com, subject: Lunch?"
    /// rather than raw JSON.
    static func argumentsSummary(_ arguments: [String: Any]) -> String {
        guard !arguments.isEmpty else { return "No arguments." }
        return arguments
            .sorted { $0.key < $1.key }
            .map { key, value in "\(key): \(value)" }
            .joined(separator: ", ")
    }

    static let localTools: [TalkTool] = [
        TalkTool(toolDefinition: AssistantToolDefinition(
            name: HarnessToolName.continueWork.rawValue,
            description: "Revise or continue a persisted job owned by this exact chat, preserving its provider session and approval gate.",
            inputSchemaJSON: #"{"type":"object","properties":{"run_id":{"type":"string"},"instruction":{"type":"string"}},"required":["instruction"]}"#
        ), origin: .local),
        TalkTool(toolDefinition: AssistantToolDefinition(
            name: HarnessToolName.inspectWork.rawValue,
            description: "Inspect persisted jobs and readable artifact text owned by this exact chat. Use for prior findings, full paths, or missing files.",
            inputSchemaJSON: #"{"type":"object","properties":{"run_id":{"type":"string"}}}"#
        ), origin: .local),
        TalkTool(toolDefinition: AssistantToolDefinition(
            name: HarnessToolName.openArtifact.rawValue,
            description: "Ask macOS to open a verified artifact owned by this exact chat. Returns real success or failure.",
            inputSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string"},"run_id":{"type":"string"}}}"#
        ), origin: .local),
        TalkTool(toolDefinition: AssistantToolDefinition(
            name: HarnessToolName.revealArtifact.rawValue,
            description: "Ask Finder to reveal a verified artifact owned by this exact chat.",
            inputSchemaJSON: #"{"type":"object","properties":{"path":{"type":"string"},"run_id":{"type":"string"}}}"#
        ), origin: .local),
        TalkTool(
            toolDefinition: AssistantToolDefinition(
                name: startTimerToolName,
                description: "Start a countdown timer. Speaks the label aloud and shows a notch alert when it finishes.",
                inputSchemaJSON: """
                {"type":"object","properties":{"seconds":{"type":"integer","description":"Duration in seconds"},"label":{"type":"string","description":"What to say when the timer finishes, e.g. \\"pasta\\""}},"required":["seconds","label"]}
                """
            ),
            origin: .local
        ),
        TalkTool(
            toolDefinition: AssistantToolDefinition(
                name: setReminderToolName,
                description: "Remind the user of something after a delay. Same mechanism as start_timer — use this one when the user says \"remind me\" rather than \"timer\".",
                inputSchemaJSON: """
                {"type":"object","properties":{"seconds":{"type":"integer","description":"Delay in seconds before the reminder fires"},"reminder":{"type":"string","description":"What to remind the user of"}},"required":["seconds","reminder"]}
                """
            ),
            origin: .local
        ),
        TalkTool(
            toolDefinition: AssistantToolDefinition(
                name: openApplicationToolName,
                description: "Open or switch to a macOS application by name.",
                inputSchemaJSON: """
                {"type":"object","properties":{"name":{"type":"string","description":"Application name, e.g. \\"Safari\\""}},"required":["name"]}
                """
            ),
            origin: .local
        ),
        TalkTool(
            toolDefinition: AssistantToolDefinition(
                name: setSystemVolumeToolName,
                description: "Set the system output volume.",
                inputSchemaJSON: """
                {"type":"object","properties":{"percent":{"type":"integer","description":"0 to 100"}},"required":["percent"]}
                """
            ),
            origin: .local
        ),
        TalkTool(
            toolDefinition: AssistantToolDefinition(
                name: startMateWorkToolName,
                description: "Start durable work on a named agent. Creates an agent only when new_name is set and no agent already matches.",
                inputSchemaJSON: """
                {"type":"object","properties":{"agent":{"type":"string","description":"Existing agent name"},"task":{"type":"string","description":"What the agent should do"},"new_name":{"type":"string","description":"Name to create when no agent matches"}},"required":["task"]}
                """
            ),
            origin: .local
        ),
        TalkTool(
            toolDefinition: AssistantToolDefinition(
                name: getMateStatusToolName,
                description: "Read persisted job status and available final answers without starting or messaging an agent. Omit agent to inspect all agents. A succeeded status means the agent reported completion; review its evidence before claiming the task is verified.",
                inputSchemaJSON: """
                {"type":"object","properties":{"agent":{"type":"string","description":"Existing agent name; omit for all agents"}},"required":[]}
                """
            ),
            origin: .local
        ),
        TalkTool(
            toolDefinition: AssistantToolDefinition(
                name: sendToMateToolName,
                description: "Send a follow-up to an agent that is already running, or to an agent that already exists.",
                inputSchemaJSON: """
                {"type":"object","properties":{"agent":{"type":"string"},"message":{"type":"string"}},"required":["agent","message"]}
                """
            ),
            origin: .local
        ),
        TalkTool(
            toolDefinition: AssistantToolDefinition(
                name: answerRequestToolName,
                description: "Answer a question an agent is waiting on.",
                inputSchemaJSON: """
                {"type":"object","properties":{"agent":{"type":"string"},"answer":{"type":"string"}},"required":["agent","answer"]}
                """
            ),
            origin: .local
        ),
        TalkTool(
            toolDefinition: AssistantToolDefinition(
                name: askDeeperToolName,
                description: "Choose the fast text path when this turn has no images, or the configured brain when it does.",
                inputSchemaJSON: """
                {"type":"object","properties":{"task":{"type":"string","description":"The question to answer. Omit to use the user's words."}},"required":[]}
                """
            ),
            origin: .local
        )
    ]
}
