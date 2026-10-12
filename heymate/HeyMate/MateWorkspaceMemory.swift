//
//  MateWorkspaceMemory.swift
//  HeyMate
//
//  A mate's folder is their memory. AGENTS.md keeps who they are, the habits
//  they should keep, and dated notes. CLAUDE.md tells Claude Code to follow it.
//

import Foundation

nonisolated enum MateWorkspaceMemory {
    static let agentsFileName = "AGENTS.md"
    static let claudeFileName = "CLAUDE.md"

    /// Shown when this mate has no notes yet. Talk does not treat this as a saved note.
    static let notesPlaceholder = "Write a note as YYYY-MM-DD: what this agent should remember. When two notes disagree, follow the later date."

    /// Empty lines a person can fill in. Left as-is once the file exists.
    static let standingPlaceholder = """
    One line each for a habit this mate should keep.

    - 
    - 
    """

    /// Claude Code loads this beside the mate. The hidden stamp remembers the last copy HeyMate wrote.
    static let claudeStub = """
    <!-- heymate-claude-stub -->
    Follow AGENTS.md in this folder. It is this mate's memory.

    @AGENTS.md
    """

    /// Writes identity from the mate, keeps standing preferences and notes already in the folder, and creates `output/` and `tmp/`.
    /// Returns the notes body to store on the mate. The empty placeholder stays out of that body.
    @discardableResult
    static func sync(mate: Mate, folder: URL, now: Date = Date()) -> String {
        let seeded = datedNotes(from: mate.memoryNote, now: now)
        do {
            return try write(mate: mate, folder: folder, notes: seeded, preserveExistingNotes: true)
        } catch {
            return mate.memoryNote
        }
    }

    /// Replaces the Notes section with what the editor saved and returns the body to store on the mate.
    @discardableResult
    static func replaceNotes(_ note: String, for mate: Mate, in folder: URL) -> String {
        let edited = editorNotes(note)
        do {
            _ = try write(mate: mate, folder: folder, notes: edited.fileBody, preserveExistingNotes: false)
            return edited.stored
        } catch {
            return note
        }
    }

    /// Notes text for the settings field. A folder with AGENTS.md wins over a stale `memoryNote`.
    static func displayNote(for mate: Mate) -> String {
        guard let path = mate.folderPath else { return mate.memoryNote }
        guard let notes = notesBody(in: URL(fileURLWithPath: path, isDirectory: true)) else {
            return mate.memoryNote
        }
        return storedMemoryNote(for: notes)
    }

    static func notesBody(in folder: URL) -> String? {
        let url = folder.appendingPathComponent(agentsFileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text).notes
    }

    private static let claudeStampFileName = ".heymate-claude-stub"

    private enum Section {
        case identity
        case standing
        case notes
        case ignored
    }

    private struct Parsed {
        var standing: String?
        var notes: String?
    }

    private struct EditorNotes {
        var fileBody: String
        var stored: String
    }

    private static func editorNotes(_ note: String) -> EditorNotes {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == notesPlaceholder {
            return EditorNotes(fileBody: notesPlaceholder, stored: "")
        }
        return EditorNotes(fileBody: note, stored: note)
    }

    private static func datedNotes(from memoryNote: String, now: Date) -> String {
        let trimmed = memoryNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == notesPlaceholder { return notesPlaceholder }
        if isDatedNotes(trimmed) { return trimmed }
        return "\(dayStamp(now)): \(trimmed)"
    }

    private static func isDatedNotes(_ text: String) -> Bool {
        guard let first = text.split(separator: "\n", omittingEmptySubsequences: false).first else { return false }
        return first.range(of: #"^\d{4}-\d{2}-\d{2}:"#, options: .regularExpression) != nil
    }

    private static func storedMemoryNote(for notes: String) -> String {
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == notesPlaceholder { return "" }
        return trimmed
    }

    private static func dayStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func identityBody(for mate: Mate) -> String {
        var lines = ["Name: \(mate.name)", "Job: \(mate.job)"]
        let soul = mate.soul.trimmingCharacters(in: .whitespacesAndNewlines)
        if !soul.isEmpty {
            lines.append("Soul: \(soul)")
        }
        return lines.joined(separator: "\n")
    }

    private static func document(mate: Mate, standing: String, notes: String) -> String {
        """
        # \(mate.name)

        ## Identity

        \(identityBody(for: mate))

        ## Standing preferences

        \(standing)

        ## Notes

        \(notes)
        """
    }

    @discardableResult
    private static func write(
        mate: Mate,
        folder: URL,
        notes fallbackNotes: String,
        preserveExistingNotes: Bool
    ) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("output", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("tmp", isDirectory: true),
            withIntermediateDirectories: true
        )
        let existing = readParsed(in: folder)
        let standing = existing.standing ?? standingPlaceholder
        let notes: String
        if preserveExistingNotes, let current = existing.notes, storedMemoryNote(for: current) != "" {
            notes = current
        } else {
            notes = fallbackNotes
        }
        let text = document(mate: mate, standing: standing, notes: notes) + "\n"
        try text.write(to: folder.appendingPathComponent(agentsFileName), atomically: true, encoding: .utf8)
        try writeClaudeStub(in: folder)
        return storedMemoryNote(for: notes)
    }

    private static func readParsed(in folder: URL) -> Parsed {
        let url = folder.appendingPathComponent(agentsFileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return Parsed(standing: nil, notes: nil) }
        return parse(text)
    }

    private static func section(for heading: String) -> Section {
        switch heading {
        case "Identity":
            return .identity
        case "Standing preferences":
            return .standing
        case "Notes":
            return .notes
        default:
            return .ignored
        }
    }

    private static func parse(_ text: String) -> Parsed {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var current = Section.ignored
        var standingLines: [String] = []
        var notesLines: [String] = []
        var sawStanding = false
        var sawNotes = false
        for line in lines {
            if line.hasPrefix("## ") {
                current = section(for: String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces))
                switch current {
                case .standing:
                    sawStanding = true
                case .notes:
                    sawNotes = true
                case .identity, .ignored:
                    break
                }
                continue
            }
            switch current {
            case .standing:
                standingLines.append(line)
            case .notes:
                notesLines.append(line)
            case .identity, .ignored:
                break
            }
        }
        return Parsed(
            standing: sawStanding ? standingLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            notes: sawNotes ? notesLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) : nil
        )
    }

    private static func writeClaudeStub(in folder: URL) throws {
        let stub = claudeStub + "\n"
        let claudeURL = folder.appendingPathComponent(claudeFileName)
        let stampURL = folder.appendingPathComponent(claudeStampFileName)
        if let existing = try? String(contentsOf: claudeURL, encoding: .utf8) {
            let normalized = existing.replacingOccurrences(of: "\r\n", with: "\n")
            let stamp = (try? String(contentsOf: stampURL, encoding: .utf8))?
                .replacingOccurrences(of: "\r\n", with: "\n")
            if let stamp {
                if normalized != stamp && normalized != stub { return }
            } else if normalized != stub {
                return
            }
        }
        try stub.write(to: claudeURL, atomically: true, encoding: .utf8)
        try stub.write(to: stampURL, atomically: true, encoding: .utf8)
    }
}
