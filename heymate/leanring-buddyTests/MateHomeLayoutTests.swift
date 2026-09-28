//
//  MateHomeLayoutTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct MateHomeLayoutTests {

    @Test func desktopShowsRailAndConversationUntilTheDrawerOpens() {
        #expect(MateHomeLayout.visibleColumns(isCompact: false, isDrawerOpen: false) == [.rail, .conversation])
        #expect(
            MateHomeLayout.visibleColumns(isCompact: false, isDrawerOpen: true)
                == [.rail, .conversation, .drawer]
        )
    }

    @Test func compactLayoutKeepsTheDrawerOutOfTheColumnList() {
        #expect(MateHomeLayout.visibleColumns(isCompact: true, isDrawerOpen: true) == [.conversation])
    }

    @Test func workspacePagesAreNotPeersOfMates() {
        #expect(MateHomeLayout.workspaceSections.contains(.chat) == false)
        #expect(MateHomeLayout.workspaceSections.contains(.settings))
        #expect(MateHomeLayout.workspaceSections.contains(.agents))
    }

    @Test func scrolledAwayTranscriptDoesNotFollow() {
        #expect(MateHomeLayout.shouldFollowLatest(isNearBottom: true))
        #expect(MateHomeLayout.shouldFollowLatest(isNearBottom: false) == false)
    }

    @Test func heyMateKeepsTheLilacFaceAndOtherMatesKeepTheirs() {
        let hey = sampleMate(id: UUID(), name: Mate.defaultName, job: Mate.defaultJob)
        #expect(MateFace.assetName(for: hey) == "MateFaceLilac")
        let id = UUID()
        let scout = sampleMate(id: id, name: "Inbox Scout", job: "Watch the inbox")
        let renamed = sampleMate(id: id, name: "Mail Scout", job: "Watch the inbox")
        #expect(MateFace.assetName(for: scout) == MateFace.assetName(for: renamed))
        #expect(MateFace.assetNames.contains(MateFace.assetName(for: scout)))
        #expect(MateFace.assetNames.count == 20)
        #expect(MateFace.assetNames.contains("MateFaceCrescent"))
        #expect(MateFace.assetNames.contains("MateFaceRobot"))
        #expect(MateFace.fillsFrame("MateFaceLilac"))
        #expect(MateFace.fillsFrame("MateFaceAmber") == false)
        #expect(MateFace.fillsFrame("MateFaceStyledGirl") == false)
    }

    @Test func longChatsShowTheNewestPageUntilEarlierIsAskedFor() {
        let messages = (0..<50).map { index in
            ChatMessage(id: UUID(), role: .user, text: "turn \(index)", createdAt: Date())
        }
        let first = MateHomeLayout.visibleMessages(messages, extraRevealed: 0)
        #expect(first.hiddenCount == 10)
        #expect(first.visible.count == 40)
        #expect(first.visible.first?.text == "turn 10")
        #expect(first.visible.last?.text == "turn 49")
        let opened = MateHomeLayout.visibleMessages(messages, extraRevealed: 40)
        #expect(opened.hiddenCount == 0)
        #expect(opened.visible.count == 50)
    }

    @Test func startersComeFromTheJob() {
        let lines = MateStarterPrompts.lines(for: "watches my inbox")
        #expect(lines.count == 3)
        #expect(lines.contains { $0.localizedCaseInsensitiveContains("watches my inbox") })
    }

    @Test func searchMatchesNameJobAndMessageText() {
        let mateID = UUID()
        let otherID = UUID()
        let mates = [
            sampleMate(id: mateID, name: "Inbox Scout", job: "Watch the inbox"),
            sampleMate(id: otherID, name: "Field Notes", job: "Keep a log")
        ]
        let sessions = [
            ChatSession(
                id: UUID(),
                title: "Old",
                createdAt: Date(),
                updatedAt: Date(),
                messages: [
                    ChatMessage(id: UUID(), role: .user, text: "the newsletter draft", createdAt: Date())
                ],
                mateID: mateID
            )
        ]
        let byMessage = MateSearch.filter(
            mates: mates,
            sessions: sessions,
            query: "newsletter",
            defaultMateID: otherID
        )
        #expect(byMessage.map(\.id) == [mateID])
        let byJob = MateSearch.filter(
            mates: mates,
            sessions: sessions,
            query: "log",
            defaultMateID: otherID
        )
        #expect(byJob.map(\.id) == [otherID])
    }

    @Test func pausedRoutineShowsOnTheRail() {
        let mateID = UUID()
        let routine = MateRoutine(
            id: UUID(),
            mateID: mateID,
            task: "Check inbox",
            enabled: true,
            schedule: .daily(hour: 8, minute: 0),
            nextRunAt: Date(),
            lastRunAt: nil,
            lastStatusMessage: nil,
            consecutiveFailures: 0,
            pausedReason: "Paused by you."
        )
        #expect(MateHomeLayout.presence(for: mateID, routines: [routine], isWorking: false) == .pausedRoutine)
        #expect(MateHomeLayout.presence(for: mateID, routines: [routine], isWorking: true) == .working)
    }

    private func sampleMate(id: UUID, name: String, job: String) -> Mate {
        Mate(
            id: id,
            name: name,
            job: job,
            pinned: false,
            archived: false,
            unreadCount: 0,
            createdAt: Date(),
            updatedAt: Date(),
            memoryNote: "",
            folderPath: nil
        )
    }
}
