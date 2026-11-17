//
//  MateApprovalRules.swift
//  HeyMate
//
//  Remembered approvals, per mate, in the style of OpenCode's permission
//  config: a rule is a tool (bash, write or edit), a pattern and a decision
//  (allow, ask or deny). "Always allow this" on an approval card stores an
//  allow rule for that mate. Rules live in HeyMate's data directory.
//
//  The floor never moves: a command or path that sends, deletes, handles
//  money or credentials, publishes, or runs a network or system program
//  still asks, whatever the rules say. A shell command that chains or
//  substitutes (`;`, `&`, `|`, backticks, `$(`, newlines, process
//  substitution) or redirects output outside the mate's folders never
//  matches an allow rule. Deny rules still apply to every part of it.
//

import Foundation
import Combine
import SwiftUI

nonisolated struct MateApprovalRule: Codable, Equatable, Identifiable, Sendable {
    enum Decision: String, Codable, CaseIterable, Sendable { case allow, ask, deny }

    var id = UUID()
    let tool: String
    let pattern: String
    let decision: Decision
    var createdAt = Date()

    /// One plain line for the card and the settings list.
    var summary: String {
        let verb = switch decision {
        case .allow: "Allow"
        case .ask: "Ask before"
        case .deny: "Never allow"
        }
        return tool == "bash" ? "\(verb) commands matching \(pattern)" : "\(verb) \(tool == "write" ? "writing" : "editing") \(pattern)"
    }
}

/// Where a mate's rules apply: its own folder, plus the chat's private working
/// directory, where relative paths and commands land.
nonisolated struct MateApprovalRuleScope: Equatable, Sendable {
    let mateID: UUID
    var folder: URL?
    var workingDirectory: URL?

    var roots: [URL] { [folder, workingDirectory].compactMap { $0 } }
}

nonisolated enum MateApprovalRuleMatcher {
    static let ruleTools: Set<String> = ["bash", "write", "edit"]

    /// Programs that publish or deploy. With the shared floor triggers
    /// (`MateAgentApprovalPolicy.shellTriggers`, `git push`) they always ask.
    static let publishPrograms: Set<String> = ["gh", "vercel", "netlify", "wrangler", "firebase", "fly", "flyctl", "heroku", "twine", "gcloud", "aws", "az"]

    /// Programs that run arbitrary code from their arguments: a wildcard rule
    /// for them would allow anything, so "Always allow" stores the exact command.
    static let interpreters: Set<String> = ["python", "python3", "node", "ruby", "perl", "php", "bash", "sh", "zsh", "fish",
        "env", "xargs", "eval", "exec", "source", ".", "npx", "bunx", "deno", "bun", "swift", "find", "awk", "sed", "command", "nohup", "time", "watch"]

    /// The rule decision for one approval, or nil when no rule applies and the
    /// approval mode decides. Deny beats the floor, the floor beats any rule,
    /// and ask beats allow.
    static func decision(tool: String, subject: String, rules: [MateApprovalRule], scope: MateApprovalRuleScope) -> MateApprovalRule.Decision? {
        guard ruleTools.contains(tool), !subject.isEmpty else { return nil }
        let candidates = rules.filter { $0.tool == tool }
        if candidates.contains(where: { $0.decision == .deny && deniedBy($0, subject: subject, scope: scope) }) { return .deny }
        let matching = candidates.filter { $0.decision != .deny && matches($0, subject: subject, scope: scope) }
        guard !matching.isEmpty else { return nil }
        if floorAsks(tool: tool, subject: subject) { return .ask }
        return matching.contains { $0.decision == .ask } ? .ask : .allow
    }

    /// The non-configurable floor for the tools rules cover.
    static func floorAsks(tool: String, subject: String) -> Bool {
        if ApprovalFloor.reasonPlanNeedsHuman(subject) != nil { return true }
        guard tool == "bash" else { return false }
        if MateAgentApprovalPolicy.runsTriggeredProgram(subject) { return true }
        return segments(subject).contains { segment in program(segment).map(publishPrograms.contains) ?? false }
    }

    static func matches(_ rule: MateApprovalRule, subject: String, scope: MateApprovalRuleScope) -> Bool {
        switch rule.tool {
        case "bash":
            guard !isChainedOrUnsafe(subject, scope: scope) else { return false }
            return glob(rule.pattern, subject.trimmingCharacters(in: .whitespaces), pathMode: false)
        case "write", "edit":
            guard let relative = pathInsideFolder(subject, scope: scope) else { return false }
            return glob(rule.pattern, relative, pathMode: true)
        default:
            return false
        }
    }

    /// Deny rules see through chaining: any part that matches denies the whole command.
    private static func deniedBy(_ rule: MateApprovalRule, subject: String, scope: MateApprovalRuleScope) -> Bool {
        if rule.tool != "bash" { return matches(rule, subject: subject, scope: scope) }
        let whole = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([whole] + segments(subject)).contains { glob(rule.pattern, $0, pathMode: false) }
    }

    /// True when a shell command can do more than its first words say.
    static func isChainedOrUnsafe(_ command: String, scope: MateApprovalRuleScope) -> Bool {
        for token in [";", "&", "|", "`", "$(", "\n", "\r", "<(", ">(", "\\\n"] where command.contains(token) { return true }
        return !redirectTargets(command).allSatisfy { target in
            target == "/dev/null" || pathInsideRoots(target, scope: scope, roots: scope.roots) != nil
        }
    }

    /// Output redirection targets (`> f`, `>> f`, `2> f`); nil target means unparseable.
    static func redirectTargets(_ command: String) -> [String] {
        var targets: [String] = []
        let characters = Array(command)
        var index = 0
        while index < characters.count {
            guard characters[index] == ">" else { index += 1; continue }
            index += 1
            if index < characters.count, characters[index] == ">" { index += 1 }
            while index < characters.count, characters[index] == " " || characters[index] == "\t" { index += 1 }
            var target = ""
            while index < characters.count, !characters[index].isWhitespace { target.append(characters[index]); index += 1 }
            // Quotes, escapes, expansions and globs make the real destination unknowable
            // here (a quoted target can hide spaces and `..`), so they never count as inside.
            if target.isEmpty || target.contains(where: { "$~*?{}[]\"'<>\\".contains($0) }) { targets.append("") }
            else { targets.append(target) }
        }
        return targets
    }

    /// The path relative to the mate's folder when it is inside it.
    static func pathInsideFolder(_ path: String, scope: MateApprovalRuleScope) -> String? {
        guard let folder = scope.folder else { return nil }
        return pathInsideRoots(path, scope: scope, roots: [folder])
    }

    private static func pathInsideRoots(_ path: String, scope: MateApprovalRuleScope, roots: [URL]) -> String? {
        guard !path.isEmpty, !path.hasPrefix("~"), !path.contains("\0") else { return nil }
        let base = scope.workingDirectory ?? scope.folder
        let url: URL
        if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
        else if let base { url = base.appendingPathComponent(path) }
        else { return nil }
        let resolved = realPath(url.standardizedFileURL.path)
        for root in roots {
            let rootPath = realPath(root.standardizedFileURL.path)
            if resolved.hasPrefix(rootPath + "/") { return String(resolved.dropFirst(rootPath.count + 1)) }
        }
        return nil
    }

    /// Resolves symlinks through the deepest part of the path that exists, so a
    /// link inside the folder cannot point a rule outside it.
    static func realPath(_ path: String) -> String {
        var existing = path
        var rest: [String] = []
        while !existing.isEmpty, existing != "/", !FileManager.default.fileExists(atPath: existing) {
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        let resolved = realpath(existing, nil).map { pointer -> String in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? existing
        return rest.reduce(resolved) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// `*` and `?` wildcards. In path mode `*` stays within one folder and `**` crosses folders.
    static func glob(_ pattern: String, _ text: String, pathMode: Bool) -> Bool {
        let p = Array(pattern), t = Array(text)
        var memo: [Int: Bool] = [:]
        func match(_ i: Int, _ j: Int) -> Bool {
            let key = i * (t.count + 1) + j
            if let known = memo[key] { return known }
            let result: Bool
            if i == p.count { result = j == t.count }
            else if p[i] == "*" {
                let double = pathMode && i + 1 < p.count && p[i + 1] == "*"
                let next = double ? i + 2 : i + 1
                let crossesFolders = !pathMode || double
                // `**/` also matches no folder at all.
                if double, next < p.count, p[next] == "/", match(next + 1, j) { result = true }
                else {
                    var k = j, found = false
                    while true {
                        if match(next, k) { found = true; break }
                        guard k < t.count, crossesFolders || t[k] != "/" else { break }
                        k += 1
                    }
                    result = found
                }
            } else if j < t.count, p[i] == "?" ? (!pathMode || t[j] != "/") : p[i] == t[j] {
                result = match(i + 1, j + 1)
            } else { result = false }
            memo[key] = result
            return result
        }
        return match(0, 0)
    }

    /// The narrowest useful rule for "Always allow this", or nil when the floor
    /// applies, the command chains, or the path is outside the mate's folder.
    static func suggestedRule(tool: String, subject: String, scope: MateApprovalRuleScope) -> MateApprovalRule? {
        guard ruleTools.contains(tool), !subject.isEmpty, !floorAsks(tool: tool, subject: subject) else { return nil }
        let pattern: String
        if tool == "bash" {
            let command = subject.trimmingCharacters(in: .whitespaces)
            guard !isChainedOrUnsafe(command, scope: scope), !command.contains(where: { "*?".contains($0) }),
                  let program = program(command) else { return nil }
            let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
            if interpreters.contains(program) || words.count == 1 { pattern = command }
            else if words.count >= 2, words[1].range(of: #"^[A-Za-z][A-Za-z0-9:_-]*$"#, options: .regularExpression) != nil {
                pattern = "\(words[0]) \(words[1])*"
            } else { pattern = "\(words[0]) *" }
        } else {
            guard let relative = pathInsideFolder(subject, scope: scope), !relative.contains(where: { "*?".contains($0) }) else { return nil }
            let folder = (relative as NSString).deletingLastPathComponent
            pattern = folder.isEmpty ? relative : "\(folder)/**"
        }
        let rule = MateApprovalRule(tool: tool, pattern: pattern, decision: .allow)
        return matches(rule, subject: subject, scope: scope) ? rule : nil
    }

    private static func segments(_ command: String) -> [String] {
        command.replacingOccurrences(of: "$(", with: "\n").replacingOccurrences(of: "<(", with: "\n").replacingOccurrences(of: ">(", with: "\n")
            .components(separatedBy: CharacterSet(charactersIn: ";&|\n\r`()"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func program(_ segment: String) -> String? {
        guard let first = segment.split(whereSeparator: \.isWhitespace).first else { return nil }
        let name = first.split(separator: "/").last.map(String.init) ?? String(first)
        return name.isEmpty ? nil : name.lowercased()
    }
}

/// Per-mate rules on disk, in HeyMate's data directory.
@MainActor
final class MateApprovalRuleStore: ObservableObject {
    static let shared = MateApprovalRuleStore()
    static let maximumRulesPerMate = 100

    @Published private(set) var rulesByMate: [UUID: [MateApprovalRule]] = [:]
    private let fileURL: URL

    init(fileURL: URL = HeyMateDataDirectory.url.appendingPathComponent("mate-approval-rules.json")) {
        self.fileURL = fileURL
        // Saved with ISO 8601 dates; a plain decoder rejected the whole file,
        // so remembered rules were lost on relaunch.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let decoded = (try? decoder.decode([String: [MateApprovalRule]].self, from: data))
            ?? (try? JSONDecoder().decode([String: [MateApprovalRule]].self, from: data)) {
            rulesByMate = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, rules in
                UUID(uuidString: key).map { ($0, rules.filter { MateApprovalRuleMatcher.ruleTools.contains($0.tool) && !$0.pattern.isEmpty }) }
            })
        }
    }

    func rules(for mateID: UUID) -> [MateApprovalRule] { rulesByMate[mateID] ?? [] }

    /// Adds a rule, replacing one with the same tool and pattern.
    func add(_ rule: MateApprovalRule, mateID: UUID) {
        var rules = rules(for: mateID).filter { !($0.tool == rule.tool && $0.pattern == rule.pattern) }
        rules.append(rule)
        rulesByMate[mateID] = Array(rules.suffix(Self.maximumRulesPerMate))
        save()
    }

    /// Replaces one rule in place (settings › Permissions › Edit). Another
    /// rule with the same tool and pattern is folded into it.
    func replace(id: UUID, with rule: MateApprovalRule, mateID: UUID) {
        var rules = rules(for: mateID)
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return add(rule, mateID: mateID) }
        var edited = rule
        edited.id = id
        rules[index] = edited
        rules.removeAll { $0.id != id && $0.tool == edited.tool && $0.pattern == edited.pattern }
        rulesByMate[mateID] = rules
        save()
    }

    func remove(id: UUID, mateID: UUID) {
        rulesByMate[mateID]?.removeAll { $0.id == id }
        if rulesByMate[mateID]?.isEmpty == true { rulesByMate[mateID] = nil }
        save()
    }

    private func save() {
        let encoded = Dictionary(uniqueKeysWithValues: rulesByMate.map { ($0.key.uuidString, $0.value) })
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(encoded).write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            HeyMateLog.log("⚠️ Could not save approval rules: \(error.localizedDescription)")
        }
    }
}

/// Applies a mate's rules to the runtime's approval requests before any card,
/// offers "Always allow this" on the card, and stores the rule when chosen.
@MainActor
enum MateApprovalRuleGate {
    /// Added to the card's params locally (never sent to the runtime): the rule
    /// "Always allow this" would store, as a plain line.
    static let offerKey = "heymate_always_allow"
    static let rememberKey = "remember"

    static func allowOnce(remember: Bool = false) -> JSONValue {
        remember ? .object(["choice": .string("once"), "all": .bool(false), rememberKey: .bool(true)])
            : .object(["choice": .string("once"), "all": .bool(false)])
    }

    /// The answer a stored rule gives, or nil when the card or the mode decides.
    static func answer(_ params: [String: JSONValue], scope: MateApprovalRuleScope,
                       store: MateApprovalRuleStore = .shared,
                       settings: MateAgentSettingsStore = .shared) -> JSONValue? {
        guard let tool = MateAgentApprovalPolicy.toolName(params),
              let subject = MateAgentApprovalPolicy.subject(params, tool: tool) else { return nil }
        let matched = MateApprovalRuleMatcher.decision(tool: tool, subject: subject, rules: store.rules(for: scope.mateID), scope: scope)
        switch MatePermissionResolver.ruleDecision(matched, override: settings.settings(for: scope.mateID).approval) {
        case .allow: return allowOnce()
        case .deny: return .object(["choice": .string("deny"), "all": .bool(false)])
        case .ask, nil: return nil
        }
    }

    /// The card's params with the offer added, and the rule it would store.
    static func offer(_ params: [String: JSONValue], scope: MateApprovalRuleScope) -> ([String: JSONValue], MateApprovalRule)? {
        guard let tool = MateAgentApprovalPolicy.toolName(params),
              let subject = MateAgentApprovalPolicy.subject(params, tool: tool),
              let rule = MateApprovalRuleMatcher.suggestedRule(tool: tool, subject: subject, scope: scope) else { return nil }
        var offered = params
        offered[offerKey] = .string(rule.summary)
        return (offered, rule)
    }

    // In-app approval cards (task cards, the notch) carry the offer by request ID.
    private static var cardOffers: [UUID: String] = [:]
    private static var cardRemembered: Set<UUID> = []

    static func offerOnCard(_ id: UUID, summary: String) { cardOffers[id] = summary }
    static func offeredSummary(for id: UUID) -> String? { cardOffers[id] }
    /// The card's "Always allow this": approve it with the coordinator right after.
    static func approveAlways(_ id: UUID) { if cardOffers[id] != nil { cardRemembered.insert(id) } }
    /// Clears the card's offer; true when the person chose "Always allow this".
    static func finishCard(_ id: UUID) -> Bool {
        cardOffers[id] = nil
        return cardRemembered.remove(id) != nil
    }

    static func remember(_ response: JSONValue?, rule: MateApprovalRule, mateID: UUID, store: MateApprovalRuleStore = .shared) {
        guard case .object(let fields) = response, fields["choice"] == .string("once"), fields[rememberKey] == .bool(true) else { return }
        store.add(rule, mateID: mateID)
    }
}

extension CompanionManager {
    /// Whose remembered approvals apply to a chat turn: the mate, and its folder when it has one.
    func mateApprovalRuleScope(forMateID mateID: UUID) -> MateApprovalRuleScope {
        let folder = mateDirectory.mates.first(where: { $0.id == mateID })?.folderPath
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        return MateApprovalRuleScope(mateID: mateID, folder: folder, workingDirectory: nil)
    }
}
