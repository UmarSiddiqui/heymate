//
//  HarnessWiringTests.swift
//  HeyMateTests
//
//  Tool-shaped choices and routine declarations. No network, no manager.
//

import Foundation
import Testing
@testable import HeyMate

struct HarnessWiringTests {
    private let mateID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let now = Date(timeIntervalSince1970: 1_760_227_200)

    @Test func aToolPrefixIsTheSameChoiceAsAJSONToolObject() {
        let prefixed = HarnessToolRequestParser.parse(
            #"start_mate_work {"mate":"Nova","task":"Draft the brief","new_name":"Nova"}"#
        )
        let object = HarnessToolRequestParser.parse(
            #"{"tool":"start_mate_work","mate":"Nova","task":"Draft the brief"}"#
        )
        #expect(prefixed?.name == .startMateWork)
        #expect(prefixed?.arguments["mate"] == "Nova")
        #expect(prefixed?.arguments["task"] == "Draft the brief")
        #expect(prefixed?.arguments["new_name"] == "Nova")
        #expect(object?.name == .startMateWork)
        #expect(object?.arguments["task"] == "Draft the brief")
        #expect(object?.arguments["tool"] == nil)
    }

    @Test func theFourSessionToolsParseAndProseDoesNot() {
        #expect(HarnessToolRequestParser.parse("send_to_mate {\"mate\":\"Ada\",\"message\":\"Status?\"}")?.name == .sendToMate)
        #expect(HarnessToolRequestParser.parse("answer_request {\"mate\":\"Ada\",\"answer\":\"Yes, send it.\"}")?.name == .answerRequest)
        #expect(HarnessToolRequestParser.parse("ask_deeper")?.name == .askDeeper)
        #expect(HarnessToolRequestParser.parse("get_mate_status {\"agent\":\"Ada\"}")?.name == .getMateStatus)
        #expect(HarnessToolRequestParser.parse("What is on my screen?") == nil)
    }

    @Test func catalogNamesMatchTheParser() {
        #expect(TalkToolCatalog.startMateWorkToolName == HarnessToolName.startMateWork.rawValue)
        #expect(TalkToolCatalog.sendToMateToolName == HarnessToolName.sendToMate.rawValue)
        #expect(TalkToolCatalog.answerRequestToolName == HarnessToolName.answerRequest.rawValue)
        #expect(TalkToolCatalog.askDeeperToolName == HarnessToolName.askDeeper.rawValue)
        #expect(TalkToolCatalog.getMateStatusToolName == HarnessToolName.getMateStatus.rawValue)
    }

    @Test func everyMinutesBecomesHourlySlots() {
        #expect(HarnessRoutineDeclaration.schedule(everyMinutes: 120) == .everyHours(2))
        #expect(HarnessRoutineDeclaration.schedule(everyMinutes: 60) == .everyHours(1))
        #expect(HarnessRoutineDeclaration.schedule(everyMinutes: 90) == .everyHours(1))
        #expect(HarnessRoutineDeclaration.schedule(everyMinutes: 30) == .everyHours(1))
        #expect(HarnessRoutineDeclaration.schedule(everyMinutes: nil) == .everyHours(1))
    }

    @Test func createUpdateAndDeleteMatchByTitleWithinTheMate() {
        let calendar = Calendar(identifier: .gregorian)
        let created = HarnessRoutineDeclaration.changes(
            for: AgentRoutineRequest(action: .create, everyMinutes: 120, title: "Morning check", task: "Look at overnight mail", newTitle: nil),
            mateID: mateID,
            existing: [],
            now: now,
            calendar: calendar
        )
        guard case .upsert(let routine) = created.first else {
            Issue.record("create did not upsert")
            return
        }
        #expect(HarnessRoutineDeclaration.title(of: routine) == "Morning check")
        #expect(routine.schedule == .everyHours(2))
        #expect(routine.mateID == mateID)

        let otherMate = MateRoutine(
            id: UUID(),
            mateID: UUID(),
            task: "Morning check",
            enabled: true,
            schedule: .everyHours(1),
            nextRunAt: now,
            lastRunAt: nil,
            lastStatusMessage: nil,
            consecutiveFailures: 0,
            pausedReason: nil
        )
        let updated = HarnessRoutineDeclaration.changes(
            for: AgentRoutineRequest(action: .update, everyMinutes: 180, title: "morning check", task: "Look at overnight mail", newTitle: "Dawn check"),
            mateID: mateID,
            existing: [routine, otherMate],
            now: now,
            calendar: calendar
        )
        guard case .upsert(let renamed) = updated.first else {
            Issue.record("update did not upsert")
            return
        }
        #expect(renamed.id == routine.id)
        #expect(HarnessRoutineDeclaration.title(of: renamed) == "Dawn check")
        #expect(renamed.schedule == .everyHours(3))
        #expect(otherMate.task == "Morning check")

        let deleted = HarnessRoutineDeclaration.changes(
            for: AgentRoutineRequest(action: .delete, everyMinutes: nil, title: "Dawn check", task: nil, newTitle: nil),
            mateID: mateID,
            existing: [renamed],
            now: now,
            calendar: calendar
        )
        #expect(deleted == [.delete(renamed.id)])
    }

    @Test func pauseAndResumeKeepTheSameRoutine() {
        let calendar = Calendar(identifier: .gregorian)
        let routine = MateRoutine(
            id: UUID(),
            mateID: mateID,
            task: "Inbox\nScan new mail",
            enabled: true,
            schedule: .everyHours(1),
            nextRunAt: now,
            lastRunAt: nil,
            lastStatusMessage: nil,
            consecutiveFailures: 0,
            pausedReason: nil
        )
        let paused = HarnessRoutineDeclaration.changes(
            for: AgentRoutineRequest(action: .pause, everyMinutes: nil, title: "Inbox", task: nil, newTitle: nil),
            mateID: mateID,
            existing: [routine],
            now: now,
            calendar: calendar
        )
        guard case .upsert(let held) = paused.first else {
            Issue.record("pause did not upsert")
            return
        }
        #expect(held.id == routine.id)
        #expect(held.pausedReason != nil)

        let resumed = HarnessRoutineDeclaration.changes(
            for: AgentRoutineRequest(action: .resume, everyMinutes: nil, title: "Inbox", task: nil, newTitle: nil),
            mateID: mateID,
            existing: [held],
            now: now,
            calendar: calendar
        )
        guard case .upsert(let running) = resumed.first else {
            Issue.record("resume did not upsert")
            return
        }
        #expect(running.pausedReason == nil)
        #expect(running.enabled)
    }
}
