//
//  CodexJSONLParser.swift
//  leanring-buddy
//
//  Maps one `codex exec --json` line to AgentEvents. The JSONL schema has
//  moved between Codex versions, so this is defensive: thread id, agent
//  text, tool names, and errors are recognized; everything else is ignored.
//

import Foundation

nonisolated enum CodexJSONLParser {

    static func events(fromStdoutLine line: String) -> [AgentEvent] {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty,
              let lineData = trimmedLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return []
        }
        return events(fromJSON: json)
    }

    static func events(fromJSON json: [String: Any]) -> [AgentEvent] {
        var parsed: [AgentEvent] = []
        if let sessionIdentifier = sessionIdentifier(in: json) {
            parsed.append(.sessionIdentified(sessionIdentifier))
        }

        let type = ((json["type"] as? String) ?? "").lowercased()
        if type == "error" || type.hasSuffix(".error") {
            let message = stringValue(json["message"])
                ?? stringValue(json["error"])
                ?? "Codex reported an error"
            parsed.append(.failed(message: message))
            return parsed
        }

        if let item = json["item"] as? [String: Any] {
            parsed.append(contentsOf: eventsFromItem(item, enclosingType: type))
        } else if let payload = json["payload"] as? [String: Any] {
            parsed.append(contentsOf: eventsFromItem(payload, enclosingType: type))
        } else if type.contains("agent_message") || type == "agent.message" {
            if let text = firstNonEmptyText(in: json) {
                parsed.append(.text(text))
            }
        }

        return parsed
    }

    /// Last assistant message in a Talk turn, where we accumulate rather
    /// than stream AgentEvents.
    static func agentMessageText(fromStdoutLine line: String) -> String? {
        let events = events(fromStdoutLine: line)
        for event in events.reversed() {
            if case .text(let text) = event { return text }
            if case .finished(let summary) = event { return summary }
        }
        return nil
    }

    private static func eventsFromItem(_ item: [String: Any], enclosingType: String) -> [AgentEvent] {
        let itemType = ((item["type"] as? String) ?? "").lowercased()
        let isCompletion = enclosingType.contains("completed") || enclosingType.contains("complete")

        if itemType.contains("command") || itemType.contains("tool") || itemType.contains("mcp")
            || itemType.contains("file_change") || itemType.contains("command_execution") {
            let name = stringValue(item["command"])
                ?? stringValue(item["name"])
                ?? stringValue(item["tool"])
                ?? "tool"
            return [.tool(summary: String(name.prefix(80)))]
        }

        if itemType.contains("agent_message") || itemType.contains("message") || itemType == "agentmessage" {
            guard let text = firstNonEmptyText(in: item) else { return [] }
            if isCompletion {
                return [.finished(summary: text)]
            }
            return [.text(text)]
        }

        if let text = firstNonEmptyText(in: item), enclosingType.contains("completed") {
            return [.text(text)]
        }
        return []
    }

    private static func sessionIdentifier(in json: [String: Any]) -> String? {
        let type = ((json["type"] as? String) ?? "").lowercased()
        let isThreadStart = type == "thread.started" || type == "thread_started" || type == "session_meta"
        let keys = ["thread_id", "threadId", "session_id", "sessionId"]
        for key in keys {
            if let value = json[key] as? String, !value.isEmpty {
                if isThreadStart || looksLikeSessionIdentifier(value) { return value }
            }
        }
        if let payload = json["payload"] as? [String: Any] {
            for key in keys {
                if let value = payload[key] as? String, !value.isEmpty {
                    if isThreadStart || looksLikeSessionIdentifier(value) { return value }
                }
            }
            if isThreadStart, let value = payload["id"] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// Codex thread ids are UUIDs; a generic `"id": "item_…"` must not steal
    /// the session slot or resume will point at a tool call.
    private static func looksLikeSessionIdentifier(_ value: String) -> Bool {
        if value.count < 8 { return false }
        if value.hasPrefix("item") { return false }
        return value.contains("-") || value.hasPrefix("thread")
    }

    private static func firstNonEmptyText(in json: [String: Any]) -> String? {
        let keys = ["text", "message", "content"]
        for key in keys {
            if let value = json[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        return nil
    }
}
