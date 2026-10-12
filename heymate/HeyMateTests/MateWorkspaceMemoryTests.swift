//
//  MateWorkspaceMemoryTests.swift
//  HeyMateTests
//
//  A mate folder keeps AGENTS.md, CLAUDE.md, and the work directories.
//

import Foundation
import Testing
@testable import HeyMate

struct MateWorkspaceMemoryTests {

    @Test func syncWritesIdentityPreferencesNotesAndWorkFolders() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mate = sampleMate(name: "Mira", job: "a patient design tutor", soul: "Calm and specific.")

        let stored = MateWorkspaceMemory.sync(mate: mate, folder: folder)
        let agents = try String(contentsOf: folder.appendingPathComponent("AGENTS.md"), encoding: .utf8)

        #expect(stored == "")
        #expect(agents.hasPrefix("# Mira\n"))
        #expect(agents.contains("## Identity"))
        #expect(agents.contains("Name: Mira"))
        #expect(agents.contains("Job: a patient design tutor"))
        #expect(agents.contains("Soul: Calm and specific."))
        #expect(agents.contains("## Standing preferences"))
        #expect(agents.contains(MateWorkspaceMemory.standingPlaceholder))
        #expect(agents.contains("## Notes"))
        #expect(agents.contains(MateWorkspaceMemory.notesPlaceholder))
        #expect(directoryExists(folder.appendingPathComponent("output")))
        #expect(directoryExists(folder.appendingPathComponent("tmp")))

        let claude = try String(contentsOf: folder.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        #expect(claude.contains("AGENTS.md"))
        #expect(claude.contains("heymate-claude-stub"))
    }

    @Test func renameRewritesIdentityAndKeepsDatedNotes() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var mate = sampleMate(name: "Mira", job: "a patient design tutor", soul: "Calm and specific.")
        mate.memoryNote = "Use concise design feedback."
        _ = MateWorkspaceMemory.sync(mate: mate, folder: folder)

        let agentsURL = folder.appendingPathComponent("AGENTS.md")
        var text = try String(contentsOf: agentsURL, encoding: .utf8)
        text = text.replacingOccurrences(
            of: "- \n- ",
            with: "- Answer in short lines\n- "
        )
        text += "2020-01-02: keeps the extra note\n"
        try text.write(to: agentsURL, atomically: true, encoding: .utf8)

        mate.name = "North"
        mate.job = "a practical design tutor"
        _ = MateWorkspaceMemory.sync(mate: mate, folder: folder)
        let rewritten = try String(contentsOf: agentsURL, encoding: .utf8)

        #expect(rewritten.contains("# North\n"))
        #expect(rewritten.contains("Name: North"))
        #expect(rewritten.contains("Job: a practical design tutor"))
        #expect(rewritten.contains("Soul: Calm and specific."))
        #expect(!rewritten.contains("Name: Mira"))
        #expect(!rewritten.contains("# Mira"))
        #expect(rewritten.contains("Use concise design feedback."))
        #expect(rewritten.contains("2020-01-02: keeps the extra note"))
        #expect(rewritten.contains("- Answer in short lines"))
    }

    @Test func memoryNoteRoundTripsIntoNotes() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var mate = sampleMate(name: "Mira", job: "a patient design tutor", soul: "")
        mate.memoryNote = "Use concise design feedback."

        let stored = MateWorkspaceMemory.sync(mate: mate, folder: folder)
        #expect(stored.contains("Use concise design feedback."))
        #expect(stored.range(of: #"^\d{4}-\d{2}-\d{2}: Use concise design feedback\.$"#, options: .regularExpression) != nil)
        #expect(MateWorkspaceMemory.notesBody(in: folder) == stored)

        mate.memoryNote = stored
        #expect(MateWorkspaceMemory.sync(mate: mate, folder: folder) == stored)
        let agents = try String(contentsOf: folder.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        #expect(agents.components(separatedBy: "Use concise design feedback.").count == 2)

        let edited = MateWorkspaceMemory.replaceNotes("2026-04-01: likes short notes", for: mate, in: folder)
        #expect(edited == "2026-04-01: likes short notes")
        #expect(MateWorkspaceMemory.notesBody(in: folder) == edited)
        mate.memoryNote = "stale note that should not win"
        #expect(MateWorkspaceMemory.displayNote(for: mateWithFolder(mate, folder: folder)) == edited)
    }

    @Test func userEditedClaudeFileIsNotReplaced() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var mate = sampleMate(name: "Mira", job: "a patient design tutor", soul: "Calm and specific.")
        _ = MateWorkspaceMemory.sync(mate: mate, folder: folder)

        let claudeURL = folder.appendingPathComponent("CLAUDE.md")
        let custom = "These rules are mine.\n"
        try custom.write(to: claudeURL, atomically: true, encoding: .utf8)

        mate.name = "North"
        _ = MateWorkspaceMemory.sync(mate: mate, folder: folder)

        let claude = try String(contentsOf: claudeURL, encoding: .utf8)
        #expect(claude == custom)
        let agents = try String(contentsOf: folder.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        #expect(agents.contains("Name: North"))
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func sampleMate(name: String, job: String, soul: String) -> Mate {
        Mate(
            id: UUID(),
            name: name,
            job: job,
            pinned: false,
            archived: false,
            unreadCount: 0,
            createdAt: Date(),
            updatedAt: Date(),
            memoryNote: "",
            folderPath: nil,
            soul: soul
        )
    }

    private func mateWithFolder(_ mate: Mate, folder: URL) -> Mate {
        var copy = mate
        copy.folderPath = folder.path
        return copy
    }
}
