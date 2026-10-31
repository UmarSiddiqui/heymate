//
//  DriveEngine.swift
//  HeyMate
//
//  The contract of a drive: one literal goal for one app window, worked
//  toward one step at a time.
//
//  Each step snapshots the window's accessibility tree, projects it to the
//  named, enabled, interactive elements, gives each a short token, and asks
//  the model for exactly one next step. The step is checked in code before
//  anything acts on it, and the loop re-snapshots after every action, so
//  the model never reasons about a screen it has not just seen.
//
//  The shape follows the drive loop recovered from HeyClicky's REA pack
//  (goal, never-press labels enforced in code before and after the model
//  answers, typed values, a step cap, a deterministic done check, and a
//  typed status when control comes back). Only the contract was recovered;
//  everything here is HeyMate's own implementation.
//

import CoreGraphics
import Foundation

/// One element the model may act on. `token` is stable for one snapshot only.
nonisolated struct DriveElement: Equatable, Sendable {
    let token: Int
    let role: String
    let label: String
    let value: String?
    /// AppKit global coordinates (bottom-left origin).
    let frame: CGRect
    let isFocused: Bool

    var isTextEntry: Bool {
        ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
    }

    /// One line the model reads: `[12] button "Send"`.
    var promptLine: String {
        let kind = role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role.lowercased()
        var line = "[\(token)] \(kind) \"\(DriveEngine.clipped(label, to: 80))\""
        if let value, !value.isEmpty, value != label {
            line += " value=\"\(DriveEngine.clipped(value, to: 60))\""
        }
        if isFocused { line += " (focused)" }
        return line
    }
}

/// What the window looked like at the start of a step.
nonisolated struct DriveSnapshot: Equatable, Sendable {
    let applicationName: String
    let processIdentifier: pid_t
    let windowTitle: String?
    let elements: [DriveElement]
    /// Every label and value in the window, for the deterministic done check.
    let visibleStrings: [String]

    func element(withToken token: Int) -> DriveElement? {
        elements.first { $0.token == token }
    }
}

/// The one step the model chose.
nonisolated enum DriveDecision: Equatable, Sendable {
    case press(token: Int)
    case type(token: Int?, text: String, submit: Bool)
    case key(String)
    case scroll(direction: String)
    case openApplication(String)
    /// Pixel point in the attached screenshot (top-left origin).
    case clickPoint(CGPoint)
    /// Press on one element, carry it, and let go on another.
    case drag(fromToken: Int, toToken: Int)
    case wait
    case done(summary: String)
    case blocked(reason: String)
}

/// How a drive ended. Mirrors the typed statuses the recovered contract
/// hands back, so a caller can tell "finished" from "your turn".
nonisolated enum DriveStatus: Equatable, Sendable {
    case done(summary: String)
    case successContainsMatched
    case blocked(reason: String)
    case refusedControl(label: String)
    case needsText(field: String)
    case maxSteps
    case handedBack(reason: String)
    case untrustedAnswer(String)
    case actionFailed(String)
    case deadline
    case declined
    case cancelled

    var code: String {
        switch self {
        case .done: return "done"
        case .successContainsMatched: return "success_contains_matched"
        case .blocked: return "blocked"
        case .refusedControl: return "refused_control"
        case .needsText: return "needs_text"
        case .maxSteps: return "max_steps"
        case .handedBack: return "handed_back"
        case .untrustedAnswer: return "untrusted_answer"
        case .actionFailed: return "action_failed"
        case .deadline: return "deadline"
        case .declined: return "declined"
        case .cancelled: return "cancelled"
        }
    }

    var succeeded: Bool {
        switch self {
        case .done, .successContainsMatched: return true
        default: return false
        }
    }

    /// One sentence for the chat, the overlay, and a calling agent.
    var summary: String {
        switch self {
        case .done(let summary): return summary.isEmpty ? "Done." : summary
        case .successContainsMatched: return "Done: the window shows what the goal asked for."
        case .blocked(let reason): return "Stopped: \(reason)"
        case .refusedControl(let label): return "Stopped before pressing \"\(label)\". That one needs you."
        case .needsText(let field): return "Stopped: \"\(field)\" needs a value I wasn't given."
        case .maxSteps: return "Stopped after the step limit without finishing."
        case .handedBack(let reason): return reason
        case .untrustedAnswer(let detail): return "Stopped: the model's step didn't make sense here (\(detail))."
        case .actionFailed(let detail): return "Stopped: \(detail)"
        case .deadline: return "Stopped: the drive ran out of time."
        case .declined: return "You said not now, so I didn't take over."
        case .cancelled: return "Drive cancelled."
        }
    }
}

/// What a drive was asked to do.
nonisolated struct DriveRequest: Equatable, Sendable {
    var goal: String
    var applicationName: String?
    var targetBundleID: String?
    /// Labels that must never be pressed, as case-insensitive substrings.
    var neverPress: [String] = []
    /// Text to type, keyed by the field's label.
    var values: [String: String] = [:]
    /// Done as soon as every one of these appears in the window.
    var successContains: [String] = []
    var maxSteps: Int = DriveEngine.defaultMaxSteps
    /// Where the request came from, for the log: "talk", "agent", "bridge".
    var origin: String = "talk"
}

enum DriveEngine {
    nonisolated static let defaultMaxSteps = 25
    static let maximumAllowedSteps = 60
    static let maximumElementsInPrompt = 150
    /// A drive never outlives this, whatever the step count.
    static let defaultDeadline: TimeInterval = 300

    /// Irreversible controls refused on every drive, on top of the caller's
    /// own list. Pressing one ends the drive and hands it back.
    static let defaultNeverPress = [
        "Send", "Delete", "Pay", "Purchase", "Buy", "Place Order", "Checkout", "Empty Trash",
        "Erase", "Sign Out", "Log Out", "Unsubscribe", "Transfer", "Confirm Payment",
    ]

    nonisolated static func clipped(_ text: String, to limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
    }

    // MARK: Guards

    /// The never-press label this element would hit, if any. Matching is
    /// case-insensitive substring on the label, so "Send Now" is caught by
    /// "Send". A word-boundary check keeps "Sender" and "Resend" out.
    static func refusedLabel(for element: DriveElement, neverPress: [String]) -> String? {
        let haystack = AccessibilityElementFinder.normalize(element.label).lowercased()
        for entry in neverPress + defaultNeverPress {
            let needle = AccessibilityElementFinder.normalize(entry).lowercased()
            guard !needle.isEmpty else { continue }
            let pattern = "(^|[^a-z0-9])" + NSRegularExpression.escapedPattern(for: needle) + "($|[^a-z0-9])"
            if haystack.range(of: pattern, options: .regularExpression) != nil { return entry }
        }
        return nil
    }

    /// True when every required string is somewhere in the window.
    static func successContainsMatched(_ required: [String], in snapshot: DriveSnapshot) -> Bool {
        let wanted = required.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return false }
        let present = snapshot.visibleStrings.map { $0.lowercased() }
        return wanted.allSatisfy { needle in present.contains { $0.contains(needle.lowercased()) } }
    }

    /// The value supplied for this field, matched on its label.
    static func suppliedValue(for element: DriveElement, values: [String: String]) -> String? {
        let label = AccessibilityElementFinder.normalize(element.label).lowercased()
        return values.first { AccessibilityElementFinder.normalize($0.key).lowercased() == label }?.value
            ?? values.first { label.contains(AccessibilityElementFinder.normalize($0.key).lowercased()) }?.value
    }

    /// Checks a decision against the snapshot it was made from. Returns the
    /// status that ends the drive, or nil when the step may run.
    static func vet(_ decision: DriveDecision, snapshot: DriveSnapshot, request: DriveRequest, hasScreenshot: Bool) -> DriveStatus? {
        switch decision {
        case .press(let token):
            guard let element = snapshot.element(withToken: token) else {
                return .untrustedAnswer("there is no element \(token)")
            }
            if refusedLabel(for: element, neverPress: request.neverPress) != nil {
                return .refusedControl(label: element.label)
            }
            return nil
        case .type(let token, let text, _):
            if let token, snapshot.element(withToken: token) == nil {
                return .untrustedAnswer("there is no element \(token)")
            }
            if ComputerUseAction.looksLikeCredential(text) {
                return .handedBack(reason: "That field looks like it wants a password or key. Please type it yourself.")
            }
            return nil
        case .key(let combination):
            if ComputerUseAction.pressKeyCombination(combination).risk >= .destructive {
                return .refusedControl(label: combination)
            }
            return nil
        case .clickPoint:
            return hasScreenshot ? nil : .untrustedAnswer("a pixel click without a screenshot")
        case .drag(let fromToken, let toToken):
            // Dropping onto Trash or a Delete target is a delete, so the
            // never-press list guards both ends of a drag.
            for token in [fromToken, toToken] {
                guard let element = snapshot.element(withToken: token) else {
                    return .untrustedAnswer("there is no element \(token)")
                }
                if refusedLabel(for: element, neverPress: request.neverPress + ["Trash", "Bin"]) != nil {
                    return .refusedControl(label: element.label)
                }
            }
            return fromToken == toToken ? .untrustedAnswer("a drag onto itself") : nil
        case .scroll, .openApplication, .wait:
            return nil
        case .done(let summary):
            return .done(summary: summary)
        case .blocked(let reason):
            return .blocked(reason: reason)
        }
    }

    // MARK: Model contract

    static let systemPrompt = """
    You are HeyMate's drive engine. You operate ONE app window on the user's Mac toward a goal, one step per reply.
    Each turn you get the goal, the steps already taken, and a fresh list of the window's interactive elements as `[token] kind "label"`. Tokens change every turn; only use tokens from this turn's list.
    Reply with exactly ONE JSON object and nothing else. No prose, no code fences, no tool calls. Choose one:
    {"action":"press","element":12,"reason":"..."}
    {"action":"type","element":4,"text":"exact text","submit":false,"reason":"..."}   (element optional: types into the focused field)
    {"action":"key","keys":"cmd+n","reason":"..."}   (menus are reached by shortcut)
    {"action":"scroll","direction":"down","reason":"..."}
    {"action":"open_app","app":"Notes","reason":"..."}
    {"action":"click","x":640,"y":320,"reason":"..."}   (ONLY when a screenshot is attached; pixel coordinates in that image)
    {"action":"drag","from":7,"to":12,"reason":"..."}   (drag element 7 and drop it on element 12: move a file into a folder, reorder a row, move a slider to a mark)
    {"action":"wait","reason":"..."}   (something is loading)
    {"action":"done","summary":"one sentence of what is now true"}
    {"action":"blocked","reason":"a login wall, dialog, permission prompt, or missing information is in the way"}
    Rules:
    - Prefer press over click. Name nothing you cannot see in the list.
    - On a "press" you may add "plan":["label","label"], the exact labels of the next presses, when you are certain of them (calculator keys, a fixed sequence of buttons). They run one at a time, only while each label is still in the window and unique; a stale plan is dropped and you are asked again. Never plan past a step whose outcome you need to read, and never plan a control that sends, pays, or deletes.
    - Before "done", check the elements or the window text actually show the goal is met. Once they do, answer "done" at once; do not press anything else.
    - Never type passwords, card numbers, codes, or keys. Use "blocked" instead.
    - Do not repeat a step that the history shows already happened unless the window clearly did not change.
    - Never press anything that sends, pays, deletes, or signs out; those are the user's call. Use "blocked" and say what is left.
    """

    static func stepPrompt(
        request: DriveRequest,
        snapshot: DriveSnapshot,
        step: Int,
        history: [String],
        hasScreenshot: Bool
    ) -> String {
        var lines: [String] = []
        lines.append("Goal: \(request.goal)")
        lines.append("Step \(step + 1) of at most \(request.maxSteps).")
        let window = snapshot.windowTitle.map { " — window \"\(clipped($0, to: 80))\"" } ?? ""
        lines.append("App: \(snapshot.applicationName)\(window)")
        if !request.values.isEmpty {
            let pairs = request.values.map { "\"\($0.key)\": \"\($0.value)\"" }.sorted().joined(separator: ", ")
            lines.append("Values to type, by field label: {\(pairs)}")
        }
        let neverPress = request.neverPress + defaultNeverPress
        lines.append("Never press: \(neverPress.joined(separator: ", "))")
        if history.isEmpty {
            lines.append("History: nothing done yet.")
        } else {
            lines.append("History:")
            lines.append(contentsOf: history.suffix(12).map { "- \($0)" })
        }
        if snapshot.elements.isEmpty {
            lines.append("Elements: none named in the accessibility tree.")
        } else {
            lines.append("Elements:")
            lines.append(contentsOf: snapshot.elements.prefix(maximumElementsInPrompt).map(\.promptLine))
        }
        let readable = windowText(of: snapshot)
        if !readable.isEmpty {
            lines.append("Window text (not clickable; read it to check progress):")
            lines.append(readable)
        }
        lines.append(hasScreenshot
            ? "A screenshot of the screen is attached. Use \"click\" with its pixel coordinates only if no element fits."
            : "No screenshot this step.")
        lines.append("Reply with one JSON object.")
        return lines.joined(separator: "\n")
    }

    /// The window's text that is not already an element label: a result,
    /// a status line, a heading. This is how the model checks it is done.
    static func windowText(of snapshot: DriveSnapshot, characterBudget: Int = 3_000) -> String {
        let labels = Set(snapshot.elements.map(\.label))
        var seen = Set<String>()
        var lines: [String] = []
        var used = 0
        for text in snapshot.visibleStrings where !labels.contains(text) && seen.insert(text).inserted {
            let line = "- " + clipped(text, to: 160)
            guard used + line.count <= characterBudget else { break }
            lines.append(line)
            used += line.count
        }
        return lines.joined(separator: "\n")
    }

    /// Reads the first JSON object out of a model reply. Prose or fences
    /// around it are tolerated; anything that is not one of the documented
    /// actions is nil, never a guess.
    static func parseDecision(_ reply: String) -> DriveDecision? {
        guard let object = firstJSONObject(in: reply) else { return nil }
        let action = (object["action"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        let element = integer(object["element"])
        switch action {
        case "press", "click_element":
            return element.map { .press(token: $0) }
        case "type":
            guard let text = object["text"] as? String, !text.isEmpty else { return nil }
            return .type(token: element, text: text, submit: (object["submit"] as? Bool) ?? false)
        case "key", "keys":
            guard let keys = (object["keys"] ?? object["key"]) as? String, !keys.isEmpty else { return nil }
            return .key(keys)
        case "scroll":
            let direction = ((object["direction"] as? String) ?? "down").lowercased()
            return ["up", "down", "left", "right"].contains(direction) ? .scroll(direction: direction) : nil
        case "open_app", "open":
            guard let app = (object["app"] ?? object["name"]) as? String, !app.isEmpty else { return nil }
            return .openApplication(app)
        case "click", "click_point":
            if let element, object["x"] == nil { return .press(token: element) }
            guard let x = double(object["x"]), let y = double(object["y"]) else { return nil }
            return .clickPoint(CGPoint(x: x, y: y))
        case "drag", "drag_and_drop":
            guard let from = integer(object["from"] ?? object["element"]), let to = integer(object["to"]) else { return nil }
            return .drag(fromToken: from, toToken: to)
        case "wait":
            return .wait
        case "done":
            return .done(summary: (object["summary"] as? String) ?? (object["reason"] as? String) ?? "")
        case "blocked":
            return .blocked(reason: (object["reason"] as? String) ?? "something is in the way")
        default:
            return nil
        }
    }

    /// The labels a "press" reply planned for the steps after it. Empty when
    /// the reply has none, is not a press, or lists anything but strings.
    static func parsePlan(_ reply: String) -> [String] {
        guard let object = firstJSONObject(in: reply),
              ["press", "click_element"].contains(((object["action"] as? String) ?? "").lowercased()),
              let raw = object["plan"] as? [Any] else { return [] }
        let labels = raw.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return labels.count == raw.count ? Array(labels.prefix(DriveFastLane.maximumPlannedSteps)) : []
    }

    static func firstJSONObject(in text: String) -> [String: Any]? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"":
                if start != nil { inString = true }
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let begin = start {
                    let candidate = String(text[begin...index])
                    if let data = candidate.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        return object
                    }
                    start = nil
                }
            default:
                break
            }
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: return number
        case let number as Double: return Int(number)
        case let text as String: return Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")))
        default: return nil
        }
    }

    private static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: return number.isFinite ? number : nil
        case let number as Int: return Double(number)
        case let text as String: return Double(text)
        default: return nil
        }
    }

    /// One history line for a step that ran.
    static func historyLine(for decision: DriveDecision, snapshot: DriveSnapshot) -> String {
        switch decision {
        case .press(let token):
            return "pressed \"\(snapshot.element(withToken: token)?.label ?? "element \(token)")\""
        case .type(let token, let text, let submit):
            let field = token.flatMap { snapshot.element(withToken: $0)?.label }.map { " into \"\($0)\"" } ?? ""
            return "typed \"\(clipped(text, to: 40))\"\(field)\(submit ? " and pressed Return" : "")"
        case .key(let keys): return "pressed \(keys)"
        case .scroll(let direction): return "scrolled \(direction)"
        case .openApplication(let app): return "opened \(app)"
        case .clickPoint(let point): return "clicked at \(Int(point.x)),\(Int(point.y)) in the screenshot"
        case .drag(let from, let to):
            let source = snapshot.element(withToken: from)?.label ?? "element \(from)"
            let target = snapshot.element(withToken: to)?.label ?? "element \(to)"
            return "dragged \"\(source)\" onto \"\(target)\""
        case .wait: return "waited"
        case .done(let summary): return "done: \(summary)"
        case .blocked(let reason): return "blocked: \(reason)"
        }
    }
}
