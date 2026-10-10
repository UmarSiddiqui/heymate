//
//  StandingOrderManageTests.swift
//  HeyMateTests
//

import Foundation
import Testing
@testable import HeyMate

@MainActor
struct StandingOrderRepositoryManageTests {

    @Test func createKeepsPreviousCooldownAndDurationDefaults() throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try repository.create(
            name: "Offer Figma",
            signalKind: .clipboard,
            contains: "figma.com",
            task: "Scaffold it"
        )
        let contents = try String(contentsOf: url, encoding: .utf8)
        let loaded = repository.loadAll()

        #expect(contents.contains("cooldown-minutes: 60"))
        #expect(contents.contains("for-minutes: 0"))
        #expect(contents.contains("enabled: true"))
        #expect(loaded.count == 1)
        #expect(loaded.first?.cooldownMinutes == 60)
        #expect(loaded.first?.minimumMatchMinutes == 0)
        #expect(loaded.first?.name == "Offer Figma")
    }

    @Test func createPersistsCooldownAndForMinutes() throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try repository.create(
            name: "Watch tests",
            signalKind: .screenText,
            contains: "test failed",
            task: "Fix the failure",
            cooldownMinutes: 15,
            forMinutes: 10
        )
        let contents = try String(contentsOf: url, encoding: .utf8)
        let loaded = repository.loadAll()

        #expect(contents.contains("cooldown-minutes: 15"))
        #expect(contents.contains("for-minutes: 10"))
        #expect(loaded.count == 1)
        #expect(loaded.first?.signalKind == .screenText)
        #expect(loaded.first?.containsAny == ["test failed"])
        #expect(loaded.first?.cooldownMinutes == 15)
        #expect(loaded.first?.minimumMatchMinutes == 10)
        #expect(loaded.first?.enabled == true)
    }

    @Test func createClampsCooldownToAtLeastOneMinute() throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try repository.create(
            name: "Clamp",
            signalKind: .clipboard,
            contains: "example.com",
            task: "Offer help",
            cooldownMinutes: 0,
            forMinutes: -4
        )
        let contents = try String(contentsOf: url, encoding: .utf8)
        let loaded = repository.loadAll().first

        #expect(contents.contains("cooldown-minutes: 1"))
        #expect(contents.contains("for-minutes: 0"))
        #expect(loaded?.cooldownMinutes == 1)
        #expect(loaded?.minimumMatchMinutes == 0)
    }

    @Test func updateRewritesTheSameMarkdownFile() throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let createdURL = try repository.create(
            name: "Offer Figma",
            signalKind: .clipboard,
            contains: "figma.com",
            task: "Scaffold it",
            cooldownMinutes: 60,
            forMinutes: 0
        )
        let original = repository.loadAll().first
        #expect(original != nil)
        guard let original else { return }

        try repository.update(
            original,
            name: "Offer renamed",
            signalKind: .frontmostApp,
            contains: "Figma, FigJam",
            task: "Open the file",
            cooldownMinutes: 30,
            forMinutes: 5
        )

        let loaded = repository.loadAll()
        let markdownFiles = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" }

        #expect(loaded.count == 1)
        #expect(loaded.first?.id == original.id)
        #expect(loaded.first?.sourcePath == original.sourcePath)
        #expect(loaded.first?.name == "Offer renamed")
        #expect(loaded.first?.signalKind == .frontmostApp)
        #expect(loaded.first?.containsAny == ["Figma", "FigJam"])
        #expect(loaded.first?.task == "Open the file")
        #expect(loaded.first?.cooldownMinutes == 30)
        #expect(loaded.first?.minimumMatchMinutes == 5)
        #expect(loaded.first?.enabled == true)
        #expect(FileManager.default.fileExists(atPath: createdURL.path))
        #expect(markdownFiles.count == 1)
        #expect(markdownFiles.first?.lastPathComponent == createdURL.lastPathComponent)
    }

    @Test func updatePreservesPausedAndPreplanFlags() throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("custom.md")
        try """
        ---
        name: Custom
        signal: calendar
        contains: standup
        task: Prep notes
        enabled: false
        cooldown-minutes: 20
        for-minutes: 3
        preplan: true
        ---
        """.write(to: url, atomically: true, encoding: .utf8)

        let original = repository.loadAll().first
        #expect(original != nil)
        guard let original else { return }

        try repository.update(
            original,
            name: "Custom renamed",
            signalKind: .calendar,
            contains: "standup",
            task: "Prep notes",
            cooldownMinutes: 25,
            forMinutes: 3
        )

        let updated = repository.loadAll().first
        #expect(updated?.enabled == false)
        #expect(updated?.preplanEnabled == true)
        #expect(updated?.name == "Custom renamed")
        #expect(updated?.cooldownMinutes == 25)
        #expect(updated?.minimumMatchMinutes == 3)
        #expect(updated?.sourcePath == original.sourcePath)
    }

    @Test func setEnabledPausesAndResumesTheSameFile() throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try repository.create(
            name: "Offer Figma",
            signalKind: .clipboard,
            contains: "figma.com",
            task: "Scaffold it",
            cooldownMinutes: 45,
            forMinutes: 8
        )
        let order = repository.loadAll().first
        #expect(order != nil)
        guard let order else { return }

        try repository.setEnabled(false, order: order)
        let paused = repository.loadAll()
        let pausedContents = try String(contentsOf: URL(fileURLWithPath: order.sourcePath), encoding: .utf8)

        #expect(paused.count == 1)
        #expect(paused.first?.enabled == false)
        #expect(paused.first?.sourcePath == order.sourcePath)
        #expect(paused.first?.cooldownMinutes == 45)
        #expect(paused.first?.minimumMatchMinutes == 8)
        #expect(paused.first?.task == "Scaffold it")
        #expect(pausedContents.contains("enabled: false"))

        guard let pausedOrder = paused.first else { return }
        try repository.setEnabled(true, order: pausedOrder)
        #expect(repository.loadAll().first?.enabled == true)
    }

    @Test func deleteRemovesOnlyThatMarkdownFile() throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstURL = try repository.create(
            name: "First order",
            signalKind: .clipboard,
            contains: "one.example",
            task: "Offer one"
        )
        let secondURL = try repository.create(
            name: "Second order",
            signalKind: .calendar,
            contains: "standup",
            task: "Offer two"
        )
        let doomed = repository.loadAll().first { $0.name == "First order" }
        #expect(doomed != nil)
        guard let doomed else { return }

        try repository.delete(doomed)

        let remaining = repository.loadAll()
        #expect(FileManager.default.fileExists(atPath: firstURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: secondURL.path))
        #expect(remaining.count == 1)
        #expect(remaining.first?.name == "Second order")
    }

    @Test func deleteRefusesAFileOutsideTheStandingOrdersFolder() throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }

        let outsider = StandingOrder(
            id: "escape",
            name: "Escape",
            signalKind: .clipboard,
            containsAny: ["x"],
            task: "Nope",
            enabled: true,
            cooldownMinutes: 60,
            minimumMatchMinutes: 0,
            preplanEnabled: false,
            sourcePath: root.deletingLastPathComponent().appendingPathComponent("escape.md").path
        )

        #expect(throws: StandingOrderRepositoryError.self) {
            try repository.delete(outsider)
        }
    }

    private func makeRepository() throws -> (FileStandingOrderRepository, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heymate-standing-orders-\(UUID().uuidString)", isDirectory: true)
        return (FileStandingOrderRepository(directoryURL: root), root)
    }
}
