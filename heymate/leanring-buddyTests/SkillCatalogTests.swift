//
//  SkillCatalogTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct SkillCatalogTests {

    @Test func scannerReadsFlatAndClaudeCodeLayouts() throws {
        let testDirectoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: testDirectoryURL) }

        let nestedSkillDirectoryURL = testDirectoryURL.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedSkillDirectoryURL, withIntermediateDirectories: true)
        try heyMateMarkdown(name: "flat", trigger: "flat trigger").write(
            to: testDirectoryURL.appendingPathComponent("flat.md"),
            atomically: true,
            encoding: .utf8
        )
        try claudeCodeMarkdown(name: "nested", description: "nested description").write(
            to: nestedSkillDirectoryURL.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let discoveredSkills = SkillDirectoryScanner.scan(
            directoryURL: testDirectoryURL,
            origin: .claudeCodeUserFolder
        )

        #expect(discoveredSkills.map(\.skill.name) == ["flat", "nested"])
        #expect(discoveredSkills.map(\.skill.trigger) == ["flat trigger", "nested description"])
        #expect(discoveredSkills.allSatisfy { $0.origin == .claudeCodeUserFolder })
    }

    @Test func flatLayoutWinsDuplicateNameWithinOneSource() throws {
        let testDirectoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: testDirectoryURL) }

        let nestedSkillDirectoryURL = testDirectoryURL.appendingPathComponent("duplicate", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedSkillDirectoryURL, withIntermediateDirectories: true)
        try heyMateMarkdown(name: "duplicate", trigger: "flat wins").write(
            to: testDirectoryURL.appendingPathComponent("duplicate.md"),
            atomically: true,
            encoding: .utf8
        )
        try claudeCodeMarkdown(name: "duplicate", description: "nested loses").write(
            to: nestedSkillDirectoryURL.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let discoveredSkills = SkillDirectoryScanner.scan(
            directoryURL: testDirectoryURL,
            origin: .claudeCodeUserFolder
        )

        #expect(discoveredSkills.count == 1)
        #expect(discoveredSkills.first?.skill.trigger == "flat wins")
    }

    @Test func allLocalSourcesIncludeUserAndProjectClaudeCodeSkills() throws {
        let rootDirectoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectoryURL) }

        let heyMateDirectoryURL = rootDirectoryURL.appendingPathComponent("heymate", isDirectory: true)
        let claudeUserDirectoryURL = rootDirectoryURL.appendingPathComponent("claude-user", isDirectory: true)
        let projectRootURL = rootDirectoryURL.appendingPathComponent("project", isDirectory: true)
        let projectSkillDirectoryURL = projectRootURL
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("project-skill", isDirectory: true)

        try FileManager.default.createDirectory(at: heyMateDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeUserDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectSkillDirectoryURL, withIntermediateDirectories: true)

        try heyMateMarkdown(name: "heymate", trigger: "heymate trigger").write(
            to: heyMateDirectoryURL.appendingPathComponent("custom.md"),
            atomically: true,
            encoding: .utf8
        )
        try claudeCodeMarkdown(name: "user", description: "user trigger").write(
            to: claudeUserDirectoryURL.appendingPathComponent("user.md"),
            atomically: true,
            encoding: .utf8
        )
        try claudeCodeMarkdown(name: "project", description: "project trigger").write(
            to: projectSkillDirectoryURL.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let discoveredSkills = SkillDirectoryScanner.scanAllLocalSources(
            heyMateSkillsDirectoryURL: heyMateDirectoryURL,
            claudeCodeUserSkillsDirectoryURL: claudeUserDirectoryURL,
            claudeCodeProjectRootPaths: [projectRootURL.path]
        )

        #expect(discoveredSkills.map(\.skill.name) == ["heymate", "user", "project"])
        #expect(discoveredSkills.map(\.origin) == [
            .userSkillsFolder,
            .claudeCodeUserFolder,
            .claudeCodeProjectFolder(projectRootPath: projectRootURL.path)
        ])
    }

    @Test func activationDefaultsAndChoicesPersist() {
        let suiteName = "SkillCatalogTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let heyMateSkill = discoveredSkill(name: "heymate", origin: .userSkillsFolder)
        let claudeCodeSkill = discoveredSkill(name: "claude", origin: .claudeCodeUserFolder)
        let initialStore = SkillActivationStore(userDefaults: userDefaults)

        #expect(initialStore.isActive(heyMateSkill))
        #expect(!initialStore.isActive(claudeCodeSkill))

        initialStore.setActive(false, for: heyMateSkill)
        initialStore.setActive(true, for: claudeCodeSkill)

        let restoredStore = SkillActivationStore(userDefaults: userDefaults)
        #expect(!restoredStore.isActive(heyMateSkill))
        #expect(restoredStore.isActive(claudeCodeSkill))
    }

    @Test func activeSkillsRespectStoredPriorityThenDiscoveryOrder() {
        let suiteName = "SkillCatalogPriorityTests-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let firstSkill = discoveredSkill(name: "first", origin: .userSkillsFolder)
        let secondSkill = discoveredSkill(name: "second", origin: .userSkillsFolder)
        let thirdSkill = discoveredSkill(name: "third", origin: .userSkillsFolder)
        let store = SkillActivationStore(userDefaults: userDefaults)

        store.setPriorityOrder([thirdSkill.identifier, firstSkill.identifier])

        let orderedSkills = store.activeSkillsInPriorityOrder(
            from: [firstSkill, secondSkill, thirdSkill]
        )
        #expect(orderedSkills.map(\.skill.name) == ["third", "first", "second"])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func discoveredSkill(name: String, origin: SkillOrigin) -> DiscoveredSkill {
        DiscoveredSkill(
            skill: SkillFile(name: name, trigger: "trigger", tools: [], instructions: "instructions"),
            origin: origin,
            fileURL: URL(fileURLWithPath: "/tmp/\(name).md")
        )
    }

    private func heyMateMarkdown(name: String, trigger: String) -> String {
        """
        ---
        name: \(name)
        trigger: \(trigger)
        tools:
        ---

        Instructions for \(name).
        """
    }

    private func claudeCodeMarkdown(name: String, description: String) -> String {
        """
        ---
        name: \(name)
        description: \(description)
        ---

        Instructions for \(name).
        """
    }
}
