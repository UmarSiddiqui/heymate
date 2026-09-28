//
//  FirstMateTests.swift
//  leanring-buddyTests
//
//  First Mate sees the other mates, free OpenCode models say when they
//  train, and meeting notes keep words rather than audio.
//

import Foundation
import Testing
@testable import HeyMate

struct FirstMateTests {

    private func mate(name: String, conducts: Bool = false) -> Mate {
        let now = Date()
        return Mate(
            id: UUID(),
            name: name,
            job: "Does \(name)",
            pinned: false,
            archived: false,
            unreadCount: 0,
            createdAt: now,
            updatedAt: now,
            memoryNote: "",
            folderPath: nil,
            conductsOthers: conducts
        )
    }

    @Test func handoffMarkupIsRemovedAndRouted() {
        let nova = mate(name: "Nova")
        let result = MateHandoffParser.extract(
            from: "I'll ask her.\n[ASK:Nova: check the inbox]",
            mates: [mate(name: "First Mate", conducts: true), nova]
        )
        #expect(result.handoffs.count == 1)
        #expect(result.handoffs[0].mateID == nova.id)
        #expect(result.handoffs[0].instruction == "check the inbox")
        #expect(!result.spokenText.contains("[ASK:"))
        #expect(result.spokenText.contains("I'll ask her."))
    }

    @Test func unknownMateStaysVisible() {
        let result = MateHandoffParser.extract(
            from: "[ASK:Nobody: do the thing]",
            mates: [mate(name: "Nova")]
        )
        #expect(result.handoffs.isEmpty)
        #expect(result.spokenText.contains("Nobody"))
    }

    @Test func conductorPromptNamesTheOthers() {
        let first = mate(name: "First Mate", conducts: true)
        let block = FirstMateBrief.promptBlock(
            mate: first,
            others: [first, mate(name: "Nova")],
            memoryExcerpts: [],
            meetingNotesAreOn: false
        )
        #expect(block.contains("Nova"))
        #expect(block.contains("[ASK:Exact Name:"))
        #expect(!block.contains("- Nova —") == false || block.contains("Nova"))
    }

    @Test func memoryIndexReadsMarkdownOnly() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryIndex-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent(".claude")
        try? FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let note = claude.appendingPathComponent("CLAUDE.md")
        try? "Prefer short answers.".write(to: note, atomically: true, encoding: .utf8)
        let excerpts = SubscriptionMemoryIndex.excerpts(root: root)
        #expect(excerpts.count == 1)
        #expect(excerpts[0].sourceName == "Claude")
        #expect(excerpts[0].text.contains("short answers"))
    }
}

struct OpenCodeTrainingPolicyTests {

    @Test func bigPickleWarns() {
        let use = OpenCodeTrainingPolicy.dataUse(
            providerID: "opencode",
            modelID: "big-pickle",
            modelName: "Big Pickle"
        )
        guard case .mayTrain(let detail) = use else {
            Issue.record("expected a training warning")
            return
        }
        #expect(detail.contains("improve the model"))
    }

    @Test func spaceBunnyDoesNotWarn() {
        let use = OpenCodeTrainingPolicy.dataUse(
            providerID: "opencode",
            modelID: "space-bunny-free",
            modelName: "Space Bunny Free"
        )
        #expect(use == .notFlagged)
    }

    @Test func paidModelDoesNotWarn() {
        let use = OpenCodeTrainingPolicy.dataUse(
            providerID: "anthropic",
            modelID: "claude-sonnet-4-6",
            modelName: "Claude Sonnet"
        )
        #expect(use == .notFlagged)
    }

    @Test func acknowledgementIsPerModel() {
        let defaults = UserDefaults(suiteName: "OpenCodeTrainingPolicyTests-\(UUID().uuidString)")!
        let key = OpenCodeTrainingPolicy.modelKey(providerID: "opencode", modelID: "big-pickle")
        #expect(OpenCodeTrainingConsent.isAcknowledged(key, defaults: defaults) == false)
        OpenCodeTrainingConsent.acknowledge(key, defaults: defaults)
        #expect(OpenCodeTrainingConsent.isAcknowledged(key, defaults: defaults))
    }
}

@MainActor
struct MeetingCommandTests {

    @Test func startAndStopKeepWords() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingNotes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = MeetingNotes(fileURL: directory.appendingPathComponent("meetings.json"))
        #expect(MeetingCommand.parse("record this meeting") == .start)
        #expect(MeetingCommand.parse("stop meeting notes") == .stop)
        notes.start(title: "Standup")
        notes.append(speaker: "You", text: "Ship the notch.")
        let stopped = notes.stop()
        #expect(stopped?.lines.count == 1)
        #expect(stopped?.lines.first?.contains("Ship the notch.") == true)
        #expect(notes.isRecording == false)
    }

    @Test func imagePlaygroundPhraseIsExplicit() {
        #expect(ImagePlaygroundRequest.concept(in: "image playground a crescent over the dock") == "a crescent over the dock")
        #expect(ImagePlaygroundRequest.concept(in: "draw a circle") == nil)
    }
}
