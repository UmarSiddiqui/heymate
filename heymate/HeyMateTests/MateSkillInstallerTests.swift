//
//  MateSkillInstallerTests.swift
//  HeyMateTests
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct MateSkillInstallerTests {

    @Test func missingSkillsRootIsNoOp() throws {
        let workspace = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: workspace) }

        let missingRoot = workspace.appendingPathComponent("missing-skills", isDirectory: true)
        try MateSkillInstaller.installMatchedSkills(
            intoFolder: workspace,
            userText: "use the pdf skill please",
            skillsRoot: missingRoot
        )

        #expect(!FileManager.default.fileExists(atPath: workspace.appendingPathComponent("skills").path))
    }

    @Test func copiesMatchedSkillIntoWorkspace() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let skillsRoot = root.appendingPathComponent("catalog", isDirectory: true)
        let workspace = root.appendingPathComponent("mate", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let pdfSkillDirectory = skillsRoot.appendingPathComponent("pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: pdfSkillDirectory, withIntermediateDirectories: true)
        let skillBody = """
        ---
        name: pdf-helper
        trigger: working with pdf files
        tools:
        ---

        Extract text carefully.
        """
        try skillBody.write(
            to: pdfSkillDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        // Loose SKILL.md at catalog root must not copy.
        try skillBody.write(
            to: skillsRoot.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        // Unmatched skill must not copy.
        let otherDirectory = skillsRoot.appendingPathComponent("spreadsheet", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        try skillBody.replacingOccurrences(of: "pdf-helper", with: "sheet-helper").write(
            to: otherDirectory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        try MateSkillInstaller.installMatchedSkills(
            intoFolder: workspace,
            userText: "Please use pdf-helper on this document",
            skillsRoot: skillsRoot
        )

        let installedSkill = workspace
            .appendingPathComponent("skills/pdf-helper/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: installedSkill.path))
        let installedText = try String(contentsOf: installedSkill, encoding: .utf8)
        #expect(installedText.contains("Extract text carefully."))
        #expect(!FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent("skills/sheet-helper/SKILL.md").path
        ))
    }

    @Test func folderNameMatchWorksWhenFrontMatterDiffers() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let skillsRoot = root.appendingPathComponent("catalog", isDirectory: true)
        let workspace = root.appendingPathComponent("mate", isDirectory: true)
        let folder = skillsRoot.appendingPathComponent("canvas-design", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        try """
        ---
        name: design-canvas
        trigger: canvas layouts
        tools:
        ---

        Layout rules.
        """.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        try MateSkillInstaller.installMatchedSkills(
            intoFolder: workspace,
            userText: "Follow canvas-design for this screen",
            skillsRoot: skillsRoot
        )

        let installedSkill = workspace.appendingPathComponent("skills/design-canvas/SKILL.md")
        #expect(FileManager.default.fileExists(atPath: installedSkill.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MateSkillInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }
}
