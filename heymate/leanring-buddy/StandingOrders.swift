//
//  StandingOrders.swift
//  leanring-buddy
//
//  User-owned Markdown rules that may offer agent work when an existing,
//  privacy-safe signal matches. Matching only creates a proposal. It never
//  starts a process or reads the screen by itself.
//

import Foundation

nonisolated enum StandingOrderSignalKind: String, Codable, CaseIterable, Equatable, Hashable {
    case frontmostApp = "frontmost-app"
    case clipboard
    case calendar
    case screenText = "screen-text"
}

nonisolated struct StandingOrderSignal: Equatable {
    let kind: StandingOrderSignalKind
    let value: String
    let observedAt: Date
}

nonisolated struct StandingOrder: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let signalKind: StandingOrderSignalKind
    let containsAny: [String]
    let task: String
    let enabled: Bool
    let cooldownMinutes: Int
    /// Context must remain matched this long before offer appears.
    let minimumMatchMinutes: Int
    /// Off by default. When true, matching may spend subscription tokens on
    /// a read-only plan before the user opens the proposal.
    let preplanEnabled: Bool
    let sourcePath: String
}

nonisolated struct StandingOrderProposal: Equatable, Identifiable {
    let id: UUID
    let standingOrderID: String
    let title: String
    let reason: String
    let task: String
    let preplanEnabled: Bool
    let createdAt: Date
}

nonisolated enum StandingOrderMarkdownParser {

    /// Format:
    /// ---
    /// name: Offer to scaffold copied Figma links
    /// signal: clipboard
    /// contains: figma.com
    /// task: Scaffold the copied Figma design in a new project.
    /// enabled: true
    /// cooldown-minutes: 60
    /// for-minutes: 0
    /// preplan: false
    /// ---
    /// Optional human notes below the frontmatter.
    static func parse(contents: String, sourceURL: URL) -> StandingOrder? {
        let normalizedContents = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedContents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard let closingIndex = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return nil }

        var values: [String: String] = [:]
        for line in lines[1..<closingIndex] {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let key = line[..<separatorIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = line[line.index(after: separatorIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            values[key] = unquoted(value)
        }

        guard let name = nonempty(values["name"]),
              let signalRawValue = nonempty(values["signal"])?.lowercased(),
              let signalKind = StandingOrderSignalKind(rawValue: signalRawValue),
              let task = nonempty(values["task"]) else { return nil }

        let containsAny = (values["contains"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !containsAny.isEmpty else { return nil }

        let stableID = sourceURL.deletingPathExtension().lastPathComponent
        return StandingOrder(
            id: stableID,
            name: name,
            signalKind: signalKind,
            containsAny: containsAny,
            task: task,
            enabled: boolean(values["enabled"], defaultValue: true),
            cooldownMinutes: max(1, Int(values["cooldown-minutes"] ?? "60") ?? 60),
            minimumMatchMinutes: max(0, Int(values["for-minutes"] ?? "0") ?? 0),
            preplanEnabled: boolean(values["preplan"], defaultValue: false),
            sourcePath: sourceURL.path
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func boolean(_ value: String?, defaultValue: Bool) -> Bool {
        guard let value else { return defaultValue }
        switch value.lowercased() {
        case "true", "yes", "1", "on": return true
        case "false", "no", "0", "off": return false
        default: return defaultValue
        }
    }
}

nonisolated enum StandingOrderMatcher {

    static func contextMatches(_ signal: StandingOrderSignal, order: StandingOrder) -> Bool {
        guard order.enabled, order.signalKind == signal.kind else { return false }
        let normalizedSignalValue = signal.value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return order.containsAny.contains { term in
            normalizedSignalValue.contains(term.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ))
        }
    }

    static func cooldownAllows(
        _ order: StandingOrder,
        lastTriggeredAt: [String: Date],
        now: Date
    ) -> Bool {
        guard let lastTriggerDate = lastTriggeredAt[order.id] else { return true }
        return now.timeIntervalSince(lastTriggerDate) >= TimeInterval(order.cooldownMinutes * 60)
    }

    static func firstMatch(
        for signal: StandingOrderSignal,
        in standingOrders: [StandingOrder],
        lastTriggeredAt: [String: Date],
        now: Date = Date()
    ) -> StandingOrder? {
        return standingOrders.first { standingOrder in
            contextMatches(signal, order: standingOrder)
                && cooldownAllows(standingOrder, lastTriggeredAt: lastTriggeredAt, now: now)
        }
    }
}

/// Stateful duration gate for “if this stays true for ten minutes”. Signals
/// remain local; evaluator stores only first-seen timestamp and matched value.
nonisolated struct StandingOrderEvaluator {
    private struct Observation {
        let value: String
        let firstSeenAt: Date
    }

    private var observations: [String: Observation] = [:]

    mutating func firstReadyMatch(
        for signal: StandingOrderSignal,
        in standingOrders: [StandingOrder],
        lastTriggeredAt: [String: Date],
        now: Date = Date()
    ) -> StandingOrder? {
        for order in standingOrders where order.signalKind == signal.kind {
            guard StandingOrderMatcher.contextMatches(signal, order: order) else {
                observations.removeValue(forKey: order.id)
                continue
            }
            guard StandingOrderMatcher.cooldownAllows(
                order,
                lastTriggeredAt: lastTriggeredAt,
                now: now
            ) else { continue }

            let normalizedValue = signal.value.lowercased()
            let observation: Observation
            if let existing = observations[order.id], existing.value == normalizedValue {
                observation = existing
            } else {
                observation = Observation(value: normalizedValue, firstSeenAt: now)
                observations[order.id] = observation
            }
            let requiredDuration = TimeInterval(order.minimumMatchMinutes * 60)
            if now.timeIntervalSince(observation.firstSeenAt) >= requiredDuration {
                return order
            }
        }
        return nil
    }
}

nonisolated struct StandingOrderVoiceInstruction: Equatable {
    let name: String
    let signalKind: StandingOrderSignalKind
    let contains: String
    let task: String

    /// Explicit spoken grammar keeps rule creation predictable:
    /// “standing order, when clipboard contains figma.com, offer to scaffold it”.
    static func parse(_ transcript: String) -> StandingOrderVoiceInstruction? {
        var body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = body.lowercased()
        let prefixes = ["standing order", "remember this rule"]
        guard let prefix = prefixes.first(where: { lowered.hasPrefix($0) }) else { return nil }
        body.removeFirst(prefix.count)
        body = body.trimmingCharacters(in: CharacterSet(charactersIn: " ,:."))
        guard body.lowercased().hasPrefix("when ") else { return nil }
        body.removeFirst("when ".count)

        let signals: [(String, StandingOrderSignalKind)] = [
            ("frontmost app", .frontmostApp),
            ("clipboard", .clipboard),
            ("calendar", .calendar),
            ("screen text", .screenText),
            ("screen", .screenText)
        ]
        guard let (signalPhrase, signalKind) = signals.first(where: {
            body.lowercased().hasPrefix($0.0 + " contains ")
        }) else { return nil }
        body.removeFirst((signalPhrase + " contains ").count)

        let offerMarkers = [", then offer to ", ", offer to ", " offer to "]
        guard let marker = offerMarkers.first(where: {
            body.range(of: $0, options: .caseInsensitive) != nil
        }), let range = body.range(of: marker, options: .caseInsensitive) else { return nil }
        let contains = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let task = String(body[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contains.isEmpty, !task.isEmpty else { return nil }
        return StandingOrderVoiceInstruction(
            name: "Offer to \(task)",
            signalKind: signalKind,
            contains: contains,
            task: task
        )
    }
}

nonisolated enum StandingOrderRepositoryError: Error, LocalizedError, Equatable {
    case missingFile
    case outsideDirectory

    var errorDescription: String? {
        switch self {
        case .missingFile:
            return "That standing order file is missing."
        case .outsideDirectory:
            return "That standing order is outside the standing orders folder."
        }
    }
}

@MainActor
final class FileStandingOrderRepository {

    private let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func loadAll() -> [StandingOrder] {
        let sourceURLs = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return sourceURLs
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { sourceURL in
                guard let contents = try? String(contentsOf: sourceURL, encoding: .utf8) else { return nil }
                return StandingOrderMarkdownParser.parse(contents: contents, sourceURL: sourceURL)
            }
    }

    func create(
        name: String,
        signalKind: StandingOrderSignalKind,
        contains: String,
        task: String,
        cooldownMinutes: Int = 60,
        forMinutes: Int = 0
    ) throws -> URL {
        let safeName = Self.singleLine(name)
        let safeContains = Self.singleLine(contains)
        let safeTask = Self.singleLine(task)
        let slug = Self.slug(safeName)
        var candidateURL = directoryURL.appendingPathComponent("\(slug).md")
        var suffix = 2
        while fileManager.fileExists(atPath: candidateURL.path) {
            candidateURL = directoryURL.appendingPathComponent("\(slug)-\(suffix).md")
            suffix += 1
        }

        let markdown = Self.markdown(
            name: safeName,
            signalKind: signalKind,
            contains: safeContains,
            task: safeTask,
            enabled: true,
            cooldownMinutes: cooldownMinutes,
            forMinutes: forMinutes,
            preplanEnabled: false
        )
        try markdown.write(to: candidateURL, atomically: true, encoding: .utf8)
        return candidateURL
    }

    /// Rewrites the order's existing Markdown file. The filename, and therefore
    /// the stable id, stays put when the display name changes.
    func update(
        _ order: StandingOrder,
        name: String,
        signalKind: StandingOrderSignalKind,
        contains: String,
        task: String,
        cooldownMinutes: Int,
        forMinutes: Int
    ) throws {
        try rewrite(
            order,
            name: name,
            signalKind: signalKind,
            contains: contains,
            task: task,
            enabled: order.enabled,
            cooldownMinutes: cooldownMinutes,
            forMinutes: forMinutes
        )
    }

    func setEnabled(_ enabled: Bool, order: StandingOrder) throws {
        try rewrite(
            order,
            name: order.name,
            signalKind: order.signalKind,
            contains: order.containsAny.joined(separator: ", "),
            task: order.task,
            enabled: enabled,
            cooldownMinutes: order.cooldownMinutes,
            forMinutes: order.minimumMatchMinutes
        )
    }

    func delete(_ order: StandingOrder) throws {
        let fileURL = try markdownFileURL(for: order)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw StandingOrderRepositoryError.missingFile
        }
        try fileManager.removeItem(at: fileURL)
    }

    private func rewrite(
        _ order: StandingOrder,
        name: String,
        signalKind: StandingOrderSignalKind,
        contains: String,
        task: String,
        enabled: Bool,
        cooldownMinutes: Int,
        forMinutes: Int
    ) throws {
        let fileURL = try markdownFileURL(for: order)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw StandingOrderRepositoryError.missingFile
        }
        let markdown = Self.markdown(
            name: Self.singleLine(name),
            signalKind: signalKind,
            contains: Self.singleLine(contains),
            task: Self.singleLine(task),
            enabled: enabled,
            cooldownMinutes: cooldownMinutes,
            forMinutes: forMinutes,
            preplanEnabled: order.preplanEnabled
        )
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func markdownFileURL(for order: StandingOrder) throws -> URL {
        let fileURL = URL(fileURLWithPath: order.sourcePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var rootPath = directoryURL.resolvingSymlinksInPath().standardizedFileURL.path
        if !rootPath.hasSuffix("/") {
            rootPath += "/"
        }
        guard fileURL.path.hasPrefix(rootPath), fileURL.pathExtension.lowercased() == "md" else {
            throw StandingOrderRepositoryError.outsideDirectory
        }
        return fileURL
    }

    func directory() -> URL { directoryURL }

    nonisolated static func appSupportDirectoryURL() -> URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupportDirectory
            .appendingPathComponent("heymate", isDirectory: true)
            .appendingPathComponent("standing-orders", isDirectory: true)
    }

    private nonisolated static func markdown(
        name: String,
        signalKind: StandingOrderSignalKind,
        contains: String,
        task: String,
        enabled: Bool,
        cooldownMinutes: Int,
        forMinutes: Int,
        preplanEnabled: Bool
    ) -> String {
        let cooldown = max(1, cooldownMinutes)
        let duration = max(0, forMinutes)
        return """
        ---
        name: \(name)
        signal: \(signalKind.rawValue)
        contains: \(contains)
        task: \(task)
        enabled: \(enabled ? "true" : "false")
        cooldown-minutes: \(cooldown)
        for-minutes: \(duration)
        preplan: \(preplanEnabled ? "true" : "false")
        ---

        HeyMate may offer this task when matching context appears. Matching never starts work.
        """
    }

    private nonisolated static func slug(_ value: String) -> String {
        let lowercase = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let allowed = CharacterSet.alphanumerics
        let words = lowercase.components(separatedBy: allowed.inverted).filter { !$0.isEmpty }
        let result = words.prefix(8).joined(separator: "-")
        return result.isEmpty ? "standing-order" : result
    }

    private nonisolated static func singleLine(_ value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
