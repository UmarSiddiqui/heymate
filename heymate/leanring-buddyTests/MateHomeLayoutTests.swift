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
        #expect(MateHomeLayout.workspaceSections == [.connectors, .settings])
        #expect(MateHomeLayout.workspaceSections.contains(.agents) == false)
    }

    @Test func sidebarIsChatAppsAndSettings() {
        #expect(DesktopSection.sidebarSections == [.connectors, .settings])
        #expect(DesktopSection.connectors.displayName == "Apps")
        #expect(DesktopSection.connectors.rawValue == "connectors")
        #expect(DesktopSection.agents.displayName == "Jobs")
    }

    @Test func notchAppsAndPrivacyDeepLinksLandOnSettingsTabs() {
        #expect(DesktopSection.notch.landingSection == .settings)
        #expect(DesktopSection.notch.settingsTab == "notch")
        #expect(DesktopSection.privacy.landingSection == .settings)
        #expect(DesktopSection.privacy.settingsTab == "privacy")
        #expect(DesktopSection.agents.landingSection == .agents)
        #expect(DesktopSection.settings.settingsTab == nil)
    }

    @Test func offSidebarPagesCarryTheirOwnWayBack() {
        #expect(DesktopSection.agents.isOffSidebarPage)
        #expect(DesktopSection.skills.isOffSidebarPage)
        #expect(DesktopSection.memory.isOffSidebarPage)
        #expect(DesktopSection.notch.isOffSidebarPage == false)
        #expect(DesktopSection.connectors.isOffSidebarPage == false)
        #expect(DesktopSection.chat.isOffSidebarPage == false)
    }

    @Test func mateJobsAreTheRunsItAskedForOrRanInItsFolder() {
        let mateID = UUID()
        var mate = sampleMate(id: mateID, name: "Builder", job: "Build sites")
        mate.folderPath = "/tmp/heymate-tests/builder"
        let inFolder = sampleRun(
            status: .succeeded,
            path: "/tmp/heymate-tests/builder/",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let owned = sampleRun(
            status: .awaitingPlanApproval,
            path: "/tmp/heymate-tests/sandbox-1",
            createdAt: Date(timeIntervalSince1970: 200)
        )
        let someoneElse = sampleRun(
            status: .running,
            path: "/tmp/heymate-tests/other",
            createdAt: Date(timeIntervalSince1970: 300)
        )
        let jobs = MateJobs.runs(
            for: mate,
            in: [inFolder, owned, someoneElse],
            owners: [owned.id: mateID, someoneElse.id: UUID()]
        )
        #expect(jobs.map(\.id) == [owned.id, inFolder.id])
    }

    @Test func jobsBadgeCountsUnfinishedWorkAndNeedsYouCountsApprovals() {
        let runs = [
            sampleRun(status: .running, path: "/tmp/a", createdAt: Date()),
            sampleRun(status: .awaitingPlanApproval, path: "/tmp/b", createdAt: Date()),
            sampleRun(status: .waitingForApproval, path: "/tmp/c", createdAt: Date()),
            sampleRun(status: .succeeded, path: "/tmp/d", createdAt: Date()),
            sampleRun(status: .cancelled, path: "/tmp/e", createdAt: Date())
        ]
        #expect(MateJobs.activeCount(in: runs) == 3)
        #expect(MateJobs.needsYouCount(in: runs) == 2)
    }

    @Test func jobStatusWordsAvoidAgentJargon() {
        let statuses: [AgentRunStatus] = [
            .queued, .planning, .awaitingPlanApproval, .running,
            .waitingForApproval, .succeeded, .failed, .cancelled
        ]
        for status in statuses {
            let label = MateJobs.statusLabel(for: status).lowercased()
            #expect(!label.contains("agent"))
            #expect(!label.contains("sandbox"))
        }
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

    private func sampleRun(status: AgentRunStatus, path: String, createdAt: Date) -> AgentRun {
        var run = AgentRun.queued(
            id: UUID(),
            title: "Job",
            prompt: "Job",
            workspaceURL: URL(fileURLWithPath: path, isDirectory: true),
            executor: .openCode,
            origin: .sandbox,
            createdAt: createdAt
        )
        run.status = status
        return run
    }
}
