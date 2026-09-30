//
//  FirstMate.swift
//  leanring-buddy
//
//  The default mate is the one chat that can see the others. Specialists
//  stay scoped to their own memory. First Mate gets a roster, a way to
//  hand them work, and a short read of the memory files Claude, Codex,
//  and OpenCode already keep on this Mac.
//

import Foundation

enum FirstMateBrief {
    static func promptBlock(
        mate: Mate,
        others: [Mate],
        memoryExcerpts: [SubscriptionMemoryExcerpt],
        meetingNotesAreOn: Bool
    ) -> String {
        var lines = [
            "who you are for this turn:",
            "- you are \(mate.name). your job is \(mate.job).",
            "- you are the one chat that can see every other mate. you are also the notch companion: you can talk about what is on screen when a screenshot is attached, and you are the personal assistant when it is not.",
            "- hand work to a specialist instead of pretending you did their job. write one line they can run, using their exact name: [ASK:Exact Name: the task]",
            "- never invent a mate. if none of them fit, say so and offer to make one.",
        ]
        let personality = mate.soul.trimmingCharacters(in: .whitespacesAndNewlines)
        if !personality.isEmpty {
            lines.append("- personality: \(personality)")
        }
        if meetingNotesAreOn {
            lines.append("- meeting notes are on. keep answers useful to someone reading the note later. the audio is not stored.")
        }
        let activeOthers = others.filter { !$0.archived && !$0.conductsOthers }
        if activeOthers.isEmpty {
            lines.append("- there are no other mates yet.")
        } else {
            lines.append("- other mates:")
            for other in activeOthers {
                var summary = "  - \(other.name) — \(other.job)"
                let memory = other.memoryNote.trimmingCharacters(in: .whitespacesAndNewlines)
                if !memory.isEmpty {
                    summary += ". memory: \(clip(memory, limit: 180))"
                }
                if other.unreadCount > 0 {
                    summary += ". unread: \(other.unreadCount)"
                }
                lines.append(summary)
            }
        }
        if !memoryExcerpts.isEmpty {
            lines.append("- memory files already on this Mac, read only so you can use what the other apps remember. do not dump them unless the user asks:")
            for excerpt in memoryExcerpts {
                lines.append("  - \(excerpt.sourceName) (\(excerpt.path)): \(excerpt.text)")
            }
        }
        lines.append("- stay in this character. keep the safety rules that follow.")
        return lines.joined(separator: "\n")
    }

    private static func clip(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}

struct MateHandoff: Equatable {
    var mateID: UUID
    var mateName: String
    var instruction: String
    /// Set when another mate wrote the handoff, so the receiver knows who asked.
    var fromMateName: String? = nil
    /// Mate-to-mate hops so far. A user-driven first handoff is 1.
    var hops: Int = 1

    /// What lands in the receiving mate's chat.
    var deliveredInstruction: String {
        guard let fromMateName else { return instruction }
        return "\(fromMateName) asks: \(instruction)"
    }
}

/// How a mate learns it can message the others. Every mate gets this, not
/// only First Mate, so a specialist can pull in a teammate directly.
enum MateMessagingBrief {
    /// Ping-pong stops here: A asks B asks A asks B never ends on its own.
    static let maxHops = 3

    static func promptBlock(sender: Mate, mates: [Mate]) -> String? {
        let others = mates.filter { !$0.archived && $0.id != sender.id }
        guard !others.isEmpty else { return nil }
        var lines = [
            "messaging other mates:",
            "- to send another mate a message or task, write one line using their exact name: [ASK:Exact Name: the message]",
            "- the reply lands in their chat, not yours. ask only when their job fits, and never message yourself.",
            "- mates you can message:",
        ]
        for other in others {
            lines.append("  - \(other.name) — \(other.job)")
        }
        return lines.joined(separator: "\n")
    }
}

enum MateHandoffParser {
    struct Result: Equatable {
        var spokenText: String
        var handoffs: [MateHandoff]
    }

    /// Pulls `[ASK:Name: instruction]` out of a reply. The spoken text loses
    /// the markup so it is never read aloud. Unknown names stay in the
    /// sentence as a plain failure, because a silent drop looks like the
    /// work happened.
    static func extract(
        from text: String,
        mates: [Mate],
        sender: Mate? = nil,
        senderHops: Int = 0
    ) -> Result {
        guard let expression = try? NSRegularExpression(
            pattern: #"\[ASK:\s*([^:\]]+?)\s*:\s*([^\]]+?)\s*\]"#,
            options: []
        ) else {
            return Result(spokenText: text, handoffs: [])
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: range)
        guard !matches.isEmpty else { return Result(spokenText: text, handoffs: []) }

        var handoffs: [MateHandoff] = []
        var missing: [String] = []
        var tooDeep: [String] = []
        // First Mate answering the user directly is the user's own request,
        // so the receiver hears it unattributed. Any other sender is named.
        let announcesSender = senderHops > 0 || sender?.conductsOthers == false
        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let instructionRange = Range(match.range(at: 2), in: text) else { continue }
            let name = String(text[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let instruction = String(text[instructionRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !instruction.isEmpty else { continue }
            if let mate = mates.first(where: { candidate in
                !candidate.archived && candidate.id != sender?.id
                    && FileMateStore.normalized(candidate.name) == FileMateStore.normalized(name)
            }) {
                if senderHops >= MateMessagingBrief.maxHops {
                    tooDeep.append(mate.name)
                    continue
                }
                handoffs.append(MateHandoff(
                    mateID: mate.id,
                    mateName: mate.name,
                    instruction: instruction,
                    fromMateName: announcesSender ? sender?.name : nil,
                    hops: senderHops + 1
                ))
            } else {
                missing.append(name)
            }
        }

        var spoken = expression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: ""
        )
        spoken = spoken
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if spoken.isEmpty, !handoffs.isEmpty {
            let names = handoffs.map(\.mateName).joined(separator: ", ")
            spoken = "Asking \(names)."
        }
        if !missing.isEmpty {
            let names = missing.joined(separator: ", ")
            let note = "I don't have a mate named \(names)."
            spoken = spoken.isEmpty ? note : "\(spoken)\n\(note)"
        }
        if !tooDeep.isEmpty {
            let note = "I stopped before messaging \(tooDeep.joined(separator: ", ")). Mates already passed this along \(MateMessagingBrief.maxHops) times."
            spoken = spoken.isEmpty ? note : "\(spoken)\n\(note)"
        }
        return Result(spokenText: spoken, handoffs: handoffs)
    }
}

struct SubscriptionMemoryExcerpt: Equatable {
    var sourceName: String
    var path: String
    var text: String
}

enum SubscriptionMemoryIndex {
    /// Markdown the coding apps already keep for themselves. JSON and
    /// anything that looks like a credential file stays out: First Mate
    /// should share memory, not secrets.
    static func excerpts(
        root: URL,
        fileManager: FileManager = .default,
        characterLimit: Int = 700
    ) -> [SubscriptionMemoryExcerpt] {
        let candidates: [(String, String)] = [
            ("Claude", ".claude/CLAUDE.md"),
            ("Codex", ".codex/AGENTS.md"),
            ("OpenCode", ".config/opencode/AGENTS.md"),
        ]
        var found: [SubscriptionMemoryExcerpt] = []
        for (sourceName, relativePath) in candidates {
            let url = root.appendingPathComponent(relativePath)
            guard let excerpt = readExcerpt(at: url, sourceName: sourceName, characterLimit: characterLimit, fileManager: fileManager) else {
                continue
            }
            found.append(excerpt)
            if found.count == 3 { return found }
        }
        let memories = root.appendingPathComponent(".codex/memories")
        if let names = try? fileManager.contentsOfDirectory(atPath: memories.path) {
            for name in names.sorted() where name.hasSuffix(".md") && found.count < 3 {
                let url = memories.appendingPathComponent(name)
                guard let excerpt = readExcerpt(at: url, sourceName: "Codex", characterLimit: characterLimit, fileManager: fileManager) else {
                    continue
                }
                found.append(excerpt)
            }
        }
        return found
    }

    private static func readExcerpt(
        at url: URL,
        sourceName: String,
        characterLimit: Int,
        fileManager: FileManager
    ) -> SubscriptionMemoryExcerpt? {
        let filename = url.lastPathComponent.lowercased()
        guard !filename.contains("credential"), !filename.hasPrefix(".env") else { return nil }
        guard fileManager.fileExists(atPath: url.path),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let text = trimmed.count > characterLimit
            ? String(trimmed.prefix(characterLimit - 1)) + "…"
            : trimmed
        return SubscriptionMemoryExcerpt(sourceName: sourceName, path: url.path, text: text)
    }
}

struct MeetingNote: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    var lines: [String]
}

/// Words from a meeting, not the audio. Chat history already refuses to
/// store recordings; this follows that rule.
@MainActor
final class MeetingNotes {
    private let fileURL: URL
    private var saved: [MeetingNote]
    private(set) var active: MeetingNote?

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([MeetingNote].self, from: data) {
            saved = decoded
            active = saved.first { $0.endedAt == nil }
        } else {
            saved = []
            active = nil
        }
    }

    var isRecording: Bool { active != nil }

    @discardableResult
    func start(title: String, now: Date = Date()) -> MeetingNote {
        if let active { return active }
        let note = MeetingNote(
            id: UUID(),
            title: title,
            startedAt: now,
            endedAt: nil,
            lines: []
        )
        active = note
        saved.append(note)
        persist()
        return note
    }

    @discardableResult
    func stop(now: Date = Date()) -> MeetingNote? {
        guard var note = active else { return nil }
        note.endedAt = now
        replace(note)
        active = nil
        persist()
        return note
    }

    func append(speaker: String, text: String, now: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var note = active, !trimmed.isEmpty else { return }
        let stamp = Self.clock.string(from: now)
        note.lines.append("\(stamp) \(speaker): \(trimmed)")
        replace(note)
        active = note
        persist()
    }

    private func replace(_ note: MeetingNote) {
        if let index = saved.firstIndex(where: { $0.id == note.id }) {
            saved[index] = note
        } else {
            saved.append(note)
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(saved) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    nonisolated static func appSupportFileURL() -> URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let heymateDirectory = applicationSupportDirectory.appendingPathComponent("heymate", isDirectory: true)
        try? FileManager.default.createDirectory(at: heymateDirectory, withIntermediateDirectories: true)
        return heymateDirectory.appendingPathComponent("meetings.json")
    }
}

enum MeetingCommand: Equatable {
    case start
    case stop

    static func parse(_ text: String) -> MeetingCommand? {
        let folded = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        switch folded {
        case "start meeting notes", "record this meeting", "start the meeting notes":
            return .start
        case "stop meeting notes", "end meeting notes":
            return .stop
        default:
            return nil
        }
    }
}

enum ImagePlaygroundRequest {
    /// Only the explicit product name. "Draw" already means on-screen ink.
    static func concept(in text: String) -> String? {
        let pattern = #"(?i)^(?:please\s+)?(?:open\s+)?image playground(?:\s+(?:of|for))?\s*:?\s+(.+)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let conceptRange = Range(match.range(at: 1), in: text) else { return nil }
        let concept = String(text[conceptRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return concept.isEmpty ? nil : concept
    }
}
