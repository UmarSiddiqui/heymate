//
//  TalkToolCatalog.swift
//  leanring-buddy
//
//  What the Talk model can call mid-answer, beyond text.
//
//  Four local actions are always available — start a timer, set a
//  reminder, open an app, change the volume — plus one entry per tool
//  every connected MCP connector currently exposes through
//  `ConnectorRuntime`. One catalog so the system prompt's "connected
//  tools" list, the JSON schema sent to the model, and
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

    /// Every tool available this turn: the four local actions, always
    /// present, plus one per tool from every connector `ConnectorRuntime`
    /// currently has a live MCP session for.
    @MainActor
    static func availableTools(connectorRuntime: ConnectorRuntime) -> [TalkTool] {
        var tools = localTools
        for namespacedTool in connectorRuntime.availableMCPTools {
            guard let connector = ConnectorCatalog.connector(withID: namespacedTool.connectorID) else { continue }
            tools.append(
                TalkTool(
                    toolDefinition: AssistantToolDefinition(
                        name: namespacedTool.id,
                        description: "[\(connector.displayName)] \(namespacedTool.tool.description)",
                        inputSchemaJSON: namespacedTool.tool.inputSchemaJSON
                    ),
                    origin: .connector(
                        connectorIdentifier: namespacedTool.connectorID,
                        connectorDisplayName: connector.displayName,
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

    private static let localTools: [TalkTool] = [
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
        )
    ]
}
