//
//  ClaudeStreamJSONParser.swift
//  leanring-buddy
//
//  Maps one `claude -p --output-format stream-json` line to zero or more
//  AgentEvents. Unknown / partial lines are ignored so a format bump cannot
//  crash the job — the process exit code is the backstop.
//

import Foundation

nonisolated enum ClaudeStreamJSONParser {

    static func events(fromStdoutLine line: String) -> [AgentEvent] {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty,
              let lineData = trimmedLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let type = json["type"] as? String else {
            return []
        }

        switch type {
        case "assistant":
            return assistantEvents(from: json)
        case "result":
            return resultEvents(from: json)
        case "control_request":
            return controlRequestEvents(from: json)
        case "system":
            return systemEvents(from: json)
        default:
            return []
        }
    }

    /// Stdin payload that answers a `control_request` so attached jobs can
    /// Approve / Deny without `--dangerously-skip-permissions`.
    static func controlResponseJSON(requestID: String, approve: Bool) -> Data? {
        let permissionResponse: [String: Any]
        if approve {
            permissionResponse = ["behavior": "allow", "updatedInput": [:] as [String: String]]
        } else {
            permissionResponse = ["behavior": "deny", "message": "User denied this tool from HeyMate"]
        }
        let payload: [String: Any] = [
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": requestID,
                "response": permissionResponse
            ] as [String: Any]
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    /// The `init` line echoes the session id back. HeyMate already knows it
    /// (it passed `--session-id`), but confirming it from the CLI is what
    /// makes leg two safe to resume — a mismatch here means the plan the user
    /// approved and the session about to run are not the same conversation.
    private static func systemEvents(from json: [String: Any]) -> [AgentEvent] {
        guard (json["subtype"] as? String) == "init",
              let sessionIdentifier = json["session_id"] as? String,
              !sessionIdentifier.isEmpty else { return [] }
        return [.sessionIdentified(sessionIdentifier)]
    }

    private static func assistantEvents(from json: [String: Any]) -> [AgentEvent] {
        let message = json["message"] as? [String: Any]
        let content = message?["content"] as? [[String: Any]] ?? []
        var events: [AgentEvent] = []
        for block in content {
            let blockType = block["type"] as? String
            if blockType == "tool_use" {
                let toolName = block["name"] as? String ?? "tool"
                let input = block["input"] as? [String: Any]
                events.append(.tool(summary: toolSummary(toolName: toolName, input: input)))
            } else if blockType == "text", let text = block["text"] as? String {
                let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedText.isEmpty {
                    events.append(.text(trimmedText))
                }
            }
        }
        return events
    }

    private static func resultEvents(from json: [String: Any]) -> [AgentEvent] {
        let isError = json["is_error"] as? Bool ?? false
        let resultText = (json["result"] as? String)
            ?? (json["error"] as? String)
            ?? ""
        let trimmedResult = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        if isError {
            return [.failed(message: trimmedResult.isEmpty ? "Claude Code reported an error" : trimmedResult)]
        }
        return [.finished(summary: trimmedResult)]
    }

    private static func controlRequestEvents(from json: [String: Any]) -> [AgentEvent] {
        let requestID = (json["request_id"] as? String) ?? ""
        guard !requestID.isEmpty else { return [] }
        let request = json["request"] as? [String: Any]
        let toolName = (request?["tool_name"] as? String) ?? "tool"
        let subtype = (request?["subtype"] as? String) ?? "permission"
        let summary = subtype == "can_use_tool"
            ? "Allow \(toolName)?"
            : "Claude Code needs approval (\(subtype))"
        return [.approvalRequested(id: requestID, summary: summary)]
    }

    private static func toolSummary(toolName: String, input: [String: Any]?) -> String {
        let lowerName = toolName.lowercased()
        if let path = filePath(from: input) {
            if lowerName.contains("write") || lowerName.contains("edit") || lowerName == "applypatch" {
                return "Writing \(path)"
            }
            if lowerName.contains("read") {
                return "Reading \(path)"
            }
            if lowerName.contains("bash") || lowerName == "shell" {
                return "Running \(path)"
            }
            return "\(toolName) \(path)"
        }
        if let command = input?["command"] as? String, !command.isEmpty {
            return "Running \(truncated(command))"
        }
        return toolName
    }

    private static func filePath(from input: [String: Any]?) -> String? {
        guard let input else { return nil }
        for key in ["file_path", "path", "filePath"] {
            if let value = input[key] as? String, !value.isEmpty {
                return (value as NSString).lastPathComponent
            }
        }
        return nil
    }

    private static func truncated(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        if collapsed.count <= 80 { return collapsed }
        return String(collapsed.prefix(77)) + "…"
    }
}
