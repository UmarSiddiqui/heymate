//
//  OpenUILang.swift
//  HeyMate
//
//  A native reader for OpenUI Lang (openui.com), the compact, line-based
//  language models write generative UI in. A silent-mode reply may carry one
//  ```openui block; it is parsed here and drawn by `OpenUIView` with
//  HeyMate's own components, so nothing runs in a web view.
//
//  One statement per line, `name = Expression`. `root` is the entry; without
//  it the first component statement is. Arguments are positional. Names may
//  be used before they are defined, and the last definition wins.
//
//  Streaming: the reply arrives a few characters at a time, so an unfinished
//  last statement is closed off (open strings and brackets) and parsed as
//  far as it goes, and a name not defined yet renders as nothing.
//

import Foundation

nonisolated indirect enum OpenUIValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([OpenUIValue])
    case object([OpenUIField])
    /// `Name(args)`, a component.
    case component(OpenUIComponent)
    /// `@Name(args)`, an action such as `@ToAssistant("…")`.
    case action(OpenUIComponent)
    /// A bare name: another statement.
    case reference(String)
    /// `$name`: a state variable.
    case variable(String)

    var text: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            return value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    var number: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value):
            return Double(value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: ""))
        default: return nil
        }
    }

    var bool: Bool? {
        switch self {
        case .bool(let value): return value
        case .string(let value): return ["true", "yes", "ordered"].contains(value.lowercased())
        default: return nil
        }
    }

    var array: [OpenUIValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var isNull: Bool { self == .null }
}

nonisolated struct OpenUIField: Equatable {
    let key: String
    let value: OpenUIValue
}

nonisolated struct OpenUIComponent: Equatable {
    let name: String
    let args: [OpenUIValue]

    /// Positional argument `index`, or nil when missing or `null`.
    func arg(_ index: Int) -> OpenUIValue? {
        guard args.indices.contains(index), !args[index].isNull else { return nil }
        return args[index]
    }
}

nonisolated struct OpenUIDocument: Equatable {
    /// Statements in the order they were written; a later one with the same
    /// name replaces the earlier.
    private(set) var statements: [String: OpenUIValue] = [:]
    private(set) var order: [String] = []

    /// The entry, with every reference resolved. Nil until a component to
    /// draw has arrived.
    var root: OpenUIValue? {
        let entry = statements["root"].map { _ in "root" }
            ?? order.first { name in
                if case .component = statements[name] { return true }
                return false
            }
        guard let entry, let value = statements[entry] else { return nil }
        let resolved = resolve(value, depth: 0)
        return resolved.isNull ? nil : resolved
    }

    fileprivate mutating func define(_ name: String, _ value: OpenUIValue) {
        if statements[name] == nil { order.append(name) }
        statements[name] = value
    }

    private func resolve(_ value: OpenUIValue, depth: Int) -> OpenUIValue {
        guard depth < 32 else { return .null }
        switch value {
        case .reference(let name):
            return statements[name].map { resolve($0, depth: depth + 1) } ?? .null
        case .variable(let name):
            return statements["$" + name].map { resolve($0, depth: depth + 1) } ?? .null
        case .array(let items):
            return .array(items.map { resolve($0, depth: depth + 1) })
        case .object(let fields):
            return .object(fields.map { OpenUIField(key: $0.key, value: resolve($0.value, depth: depth + 1)) })
        case .component(let component):
            return .component(OpenUIComponent(name: component.name,
                                              args: component.args.map { resolve($0, depth: depth + 1) }))
        case .action(let component):
            return .action(OpenUIComponent(name: component.name,
                                           args: component.args.map { resolve($0, depth: depth + 1) }))
        default:
            return value
        }
    }
}

nonisolated enum OpenUILangParser {

    /// Fence languages that mark an OpenUI Lang block.
    static let fenceLanguages: Set<String> = ["openui", "openui-lang", "openuilang"]

    static func parse(_ source: String) -> OpenUIDocument {
        var document = OpenUIDocument()
        var pending = ""

        func commit(_ statement: String, closingOpenDelimiters: Bool) {
            var text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("//"), !text.hasPrefix("#") else { return }
            if closingOpenDelimiters { text += closers(for: text) }
            guard let (name, value) = statementParts(text) else { return }
            document.define(name, value)
        }

        for line in source.components(separatedBy: "\n") {
            pending += pending.isEmpty ? line : "\n" + line
            // A call may wrap across lines; keep reading until it closes.
            if closers(for: pending).isEmpty {
                commit(pending, closingOpenDelimiters: false)
                pending = ""
            }
        }
        if !pending.isEmpty { commit(pending, closingOpenDelimiters: true) }
        return document
    }

    private static func statementParts(_ text: String) -> (String, OpenUIValue)? {
        var scanner = Scanner(text)
        scanner.skipSpace()
        let isVariable = scanner.consume("$")
        guard let name = scanner.identifier() else { return nil }
        scanner.skipSpace()
        guard scanner.consume("=") else { return nil }
        guard let value = scanner.expression() else { return nil }
        scanner.skipSpace()
        guard scanner.isAtEnd else { return nil }
        return ((isVariable ? "$" : "") + name, value)
    }

    /// What closes the open strings and brackets at the end of `text`, so an
    /// unfinished statement mid-stream still parses. Empty when balanced.
    static func closers(for text: String) -> String {
        var stack: [Character] = []
        var isInsideString = false
        var isEscaped = false
        for character in text {
            if isInsideString {
                if isEscaped { isEscaped = false }
                else if character == "\\" { isEscaped = true }
                else if character == "\"" { isInsideString = false }
                continue
            }
            switch character {
            case "\"": isInsideString = true
            case "(": stack.append(")")
            case "[": stack.append("]")
            case "{": stack.append("}")
            case ")", "]", "}":
                if stack.last == character { stack.removeLast() }
            default: break
            }
        }
        return (isInsideString ? "\"" : "") + String(stack.reversed())
    }

    // MARK: - Expressions

    private struct Scanner {
        let characters: [Character]
        var index = 0

        init(_ text: String) { characters = Array(text) }

        var isAtEnd: Bool { index >= characters.count }
        var current: Character? { isAtEnd ? nil : characters[index] }

        mutating func skipSpace() {
            while let character = current, character.isWhitespace { index += 1 }
        }

        mutating func consume(_ character: Character) -> Bool {
            skipSpace()
            guard current == character else { return false }
            index += 1
            return true
        }

        mutating func identifier() -> String? {
            skipSpace()
            let start = index
            while let character = current,
                  character.isLetter || character.isNumber || character == "_" || character == "." {
                if index == start, character.isNumber { return nil }
                index += 1
            }
            return index > start ? String(characters[start..<index]) : nil
        }

        /// `primary ( + primary )*`, `+` joining text; or a ternary, which
        /// takes its first branch (state is not tracked).
        mutating func expression() -> OpenUIValue? {
            guard var value = primary() else { return nil }
            while consume("+") {
                guard let next = primary() else { return value }
                value = .string((value.text ?? "") + (next.text ?? ""))
            }
            if consume("?") {
                let whenTrue = expression()
                if consume(":") { _ = expression() }
                return whenTrue ?? value
            }
            return value
        }

        mutating func primary() -> OpenUIValue? {
            skipSpace()
            guard let character = current else { return nil }
            switch character {
            case "\"":
                return string()
            case "[":
                index += 1
                return .array(list(closing: "]"))
            case "{":
                index += 1
                return object()
            case "@":
                index += 1
                guard let name = identifier() else { return nil }
                return .action(OpenUIComponent(name: name, args: consume("(") ? list(closing: ")") : []))
            case "$":
                index += 1
                return identifier().map { .variable($0) }
            case "-", "0"..."9":
                return number()
            default:
                guard let name = identifier() else { return nil }
                switch name {
                case "true": return .bool(true)
                case "false": return .bool(false)
                case "null": return .null
                default: break
                }
                if consume("(") {
                    let args = list(closing: ")")
                    // `Action([...])` is the one action written without `@`.
                    let component = OpenUIComponent(name: name, args: args)
                    return name == "Action" ? .action(component) : .component(component)
                }
                return .reference(name)
            }
        }

        mutating func string() -> OpenUIValue? {
            index += 1
            var result = ""
            while let character = current {
                index += 1
                switch character {
                case "\"":
                    return .string(result)
                case "\\":
                    guard let escaped = current else { return .string(result) }
                    index += 1
                    switch escaped {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    default: result.append(escaped)
                    }
                default:
                    result.append(character)
                }
            }
            return .string(result)
        }

        mutating func number() -> OpenUIValue? {
            let start = index
            if current == "-" { index += 1 }
            while let character = current, character.isNumber || character == "." { index += 1 }
            return Double(String(characters[start..<index])).map { .number($0) }
        }

        /// Comma-separated values up to `closing`. A trailing comma is fine.
        mutating func list(closing: Character) -> [OpenUIValue] {
            var items: [OpenUIValue] = []
            while true {
                if consume(closing) || isAtEnd { return items }
                guard let item = expression() else {
                    // Skip whatever this is, so one bad value keeps the rest.
                    index += 1
                    continue
                }
                items.append(item)
                _ = consume(",")
            }
        }

        mutating func object() -> OpenUIValue {
            var fields: [OpenUIField] = []
            while true {
                if consume("}") || isAtEnd { return .object(fields) }
                skipSpace()
                let key: String?
                if current == "\"" { key = string()?.text } else { key = identifier() }
                guard let key, consume(":"), let value = expression() else {
                    index += 1
                    continue
                }
                fields.append(OpenUIField(key: key, value: value))
                _ = consume(",")
            }
        }
    }
}

// MARK: - Plain text

/// An OpenUI block written out as readable markdown, for copying and for
/// anywhere the block cannot be drawn (captions, the notch).
nonisolated enum OpenUIPlainText {

    static func markdown(for source: String) -> String {
        guard let root = OpenUILangParser.parse(source).root else { return "" }
        return lines(for: root).joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A table as tab-separated rows, which pastes into a spreadsheet as cells.
    static func tabSeparated(columns: [String], rows: [[String]]) -> String {
        ([columns] + rows)
            .filter { !$0.isEmpty }
            .map { $0.map { $0.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t") }
            .joined(separator: "\n")
    }

    static func markdownTable(columns: [String], rows: [[String]]) -> String {
        func row(_ cells: [String]) -> String {
            "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
        }
        let width = max(columns.count, rows.map(\.count).max() ?? 0)
        guard width > 0 else { return "" }
        let header = columns.isEmpty ? Array(repeating: "", count: width) : columns
        return ([row(header), row(Array(repeating: "---", count: header.count))] + rows.map(row))
            .joined(separator: "\n")
    }

    static func texts(_ value: OpenUIValue?) -> [String] {
        value?.array?.compactMap { item in
            if let text = item.text { return text }
            if let pair = item.array { return pair.compactMap(\.text).joined(separator: " — ") }
            return nil
        } ?? []
    }

    static func cells(_ value: OpenUIValue?) -> [[String]] {
        value?.array?.map { row in row.array?.map { $0.text ?? "" } ?? [row.text ?? ""] } ?? []
    }

    private static func lines(for value: OpenUIValue) -> [String] {
        switch value {
        case .array(let items):
            return items.flatMap(lines(for:))
        case .string, .number, .bool:
            return [value.text ?? ""]
        case .component(let component):
            return lines(for: component)
        default:
            return []
        }
    }

    private static func lines(for component: OpenUIComponent) -> [String] {
        let first = component.arg(0)?.text ?? ""
        switch component.name {
        case "Stack", "Row", "Buttons", "Grid":
            return (component.arg(0).map(lines(for:)) ?? []) + [""]
        case "Card":
            let title = component.arg(1)?.text.map { ["**\($0)**"] } ?? []
            return title + (component.arg(0).map(lines(for:)) ?? []) + [""]
        case "Header":
            return ["**\(first)**"] + (component.arg(1)?.text.map { [$0] } ?? []) + [""]
        case "TextContent", "Text":
            return component.arg(1)?.text == "heading" ? ["**\(first)**"] : [first, ""]
        case "Callout":
            let title = component.arg(2)?.text.map { "**\($0):** " } ?? ""
            return ["> " + title + first, ""]
        case "Table":
            return [markdownTable(columns: texts(component.arg(0)), rows: cells(component.arg(1))), ""]
        case "Stat":
            let detail = component.arg(2)?.text.map { " (\($0))" } ?? ""
            return ["\(first): **\(component.arg(1)?.text ?? "")**\(detail)"]
        case "KeyValue":
            return cells(component.arg(0)).map { pair in
                "- \(pair.first ?? ""): \(pair.dropFirst().joined(separator: " "))"
            } + [""]
        case "List":
            let ordered = component.arg(1)?.bool ?? false
            return texts(component.arg(0)).enumerated().map { index, item in
                (ordered ? "\(index + 1). " : "- ") + item
            } + [""]
        case "Steps":
            return texts(component.arg(0)).enumerated().map { "\($0 + 1). \($1)" } + [""]
        case "Tag":
            return [first]
        case "Tags":
            return [texts(component.arg(0)).joined(separator: " · "), ""]
        case "Progress":
            return ["\(first): \(OpenUIProgress.percentText(component))"]
        case "CodeBlock", "Code":
            return ["```" + (component.arg(1)?.text ?? ""), first, "```", ""]
        case "Divider":
            return ["---"]
        case "Link":
            let url = component.arg(1)?.text ?? ""
            return [url.isEmpty ? first : "[\(first)](\(url))"]
        case "Button":
            return []
        default:
            return component.args.flatMap(lines(for:))
        }
    }
}

nonisolated enum OpenUIProgress {
    /// 0...1, from a fraction, a percentage, or `value` of `max`.
    static func fraction(_ component: OpenUIComponent) -> Double {
        let value = component.arg(1)?.number ?? 0
        if let maximum = component.arg(2)?.number, maximum > 0 { return min(max(value / maximum, 0), 1) }
        return min(max(value > 1 ? value / 100 : value, 0), 1)
    }

    static func percentText(_ component: OpenUIComponent) -> String {
        "\(Int((fraction(component) * 100).rounded()))%"
    }
}

// MARK: - Replies

nonisolated enum ChatReplyText {

    /// The reply as markdown, with each OpenUI block written out as text.
    static func readableMarkdown(_ reply: String) -> String {
        ChatMarkdownParser.segments(from: reply).map { segment in
            switch segment {
            case .prose(let prose): return prose
            case .code(let code): return "```\n" + code + "\n```"
            case .ui(let source): return OpenUIPlainText.markdown(for: source)
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    /// The reply with markdown markers dropped, for pasting where they would
    /// show as stray asterisks.
    static func plainText(_ reply: String) -> String {
        readableMarkdown(reply)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .map { line in
                var text = line
                if text.hasPrefix("> ") { text.removeFirst(2) }
                if let heading = text.range(of: #"^#{1,6} "#, options: .regularExpression) {
                    text.removeSubrange(heading)
                }
                return String(ChatMarkdownParser.inlineAttributedString(from: text).characters)
            }
            .joined(separator: "\n")
    }
}
