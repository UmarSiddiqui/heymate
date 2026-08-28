//
//  OpenCodeRunParser.swift
//  leanring-buddy
//
//  Maps `opencode run --format json` lines to AgentEvents. The JSON shape
//  has moved between opencode versions, so this is defensive: recognize
//  tool / text / error / permission, ignore everything else.
//

import Foundation

nonisolated enum OpenCodeRunParser {

    static func events(fromStdoutLine line: String) -> [AgentEvent] {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else { return [] }

        if let lineData = trimmedLine.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: lineData) {
            var events: [AgentEvent] = []
            // OpenCode assigns its own `ses_…` id and stamps it on every
            // event. Leg two has nothing to resume without it, so it is read
            // off whichever event arrives first.
            if let dictionary = json as? [String: Any],
               let sessionIdentifier = dictionary["sessionID"] as? String,
               !sessionIdentifier.isEmpty {
                events.append(.sessionIdentified(sessionIdentifier))
            }
            events.append(contentsOf: self.events(fromJSON: json))
            return events
        }

        // `--format default` fallback: a plain tool-looking line still
        // becomes a latest-action, but we never treat prose as failure.
        if trimmedLine.count <= 120 {
            return [.tool(summary: trimmedLine)]
        }
        return []
    }

    static func events(fromJSON json: Any) -> [AgentEvent] {
        if let dictionary = json as? [String: Any] {
            return events(fromDictionary: dictionary)
        }
        return []
    }

    private static func events(fromDictionary dictionary: [String: Any]) -> [AgentEvent] {
        let type = ((dictionary["type"] as? String) ?? (dictionary["kind"] as? String) ?? "").lowercased()

        if type.contains("error") || dictionary["error"] != nil && type == "error" {
            let message = (dictionary["error"] as? String)
                ?? (dictionary["message"] as? String)
                ?? "OpenCode reported an error"
            return [.failed(message: message)]
        }

        if type.contains("permission") || type == "ask" || type == "question" {
            let requestID = (dictionary["id"] as? String)
                ?? (dictionary["permissionID"] as? String)
                ?? (dictionary["requestID"] as? String)
                ?? UUID().uuidString
            let summary = (dictionary["message"] as? String)
                ?? (dictionary["title"] as? String)
                ?? "OpenCode needs approval"
            return [.approvalRequested(id: requestID, summary: summary)]
        }

        if type.contains("tool") || type == "step_start" {
            let payload = (dictionary["part"] as? [String: Any]) ?? dictionary
            return [.tool(summary: toolSummary(from: payload))]
        }

        if type == "text" || type == "message" {
            if let text = textPayload(from: dictionary), !text.isEmpty {
                return [.text(text)]
            }
        }

        // `opencode run` is a one-shot process. Its clean process exit is the
        // authoritative end of the turn. Stream events such as `step_finish`
        // are not authoritative: one is emitted after every model step, and a
        // tool-using turn can emit several before the final response. Treating
        // any `complete`/`finish`-looking event as job completion kills the CLI
        // between tool calls. It also breaks on OpenCode versions that omit the
        // final `step_finish` event entirely. Keep these events informational
        // and let HeadlessAgentLauncher finish the run from process exit.
        if type == "step_finish"
            || type == "step-finish"
            || type == "finish"
            || type == "finished"
            || type == "complete"
            || type == "completed"
            || type == "message_complete"
            || type == "message_completed" {
            return []
        }

        if let part = dictionary["part"] as? [String: Any] {
            return events(fromDictionary: part)
        }
        return []
    }

    private static func toolSummary(from dictionary: [String: Any]) -> String {
        let name = (dictionary["name"] as? String)
            ?? (dictionary["tool"] as? String)
            ?? (dictionary["title"] as? String)
            ?? "Working"
        if let path = dictionary["path"] as? String, !path.isEmpty {
            return "\(name) \((path as NSString).lastPathComponent)"
        }
        if let input = dictionary["input"] as? [String: Any],
           let path = input["path"] as? String ?? input["file_path"] as? String {
            return "\(name) \((path as NSString).lastPathComponent)"
        }
        return name
    }

    private static func textPayload(from dictionary: [String: Any]) -> String? {
        if let text = dictionary["text"] as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let text = dictionary["message"] as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let text = dictionary["result"] as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return nil
    }
}
