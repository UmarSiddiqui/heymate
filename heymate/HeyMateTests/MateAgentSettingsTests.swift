//
//  MateAgentSettingsTests.swift
//  HeyMateTests
//
//  The pure rules behind agent settings: quiet hours, notification gating,
//  stricter-only approval, limits, today's counts, folder choice, and that
//  the settings file stays loadable across builds. Nothing here touches
//  UserDefaults or the real data directory.
//

import Foundation
import Testing
@testable import HeyMate

struct MateQuietHoursTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test func defaultMatchesTheOldHeartbeatWindow() {
        let quiet = MateQuietHours()
        #expect(quiet.startMinute == 21 * 60 && quiet.endMinute == 7 * 60)
        #expect(quiet.contains(at(16, 21), calendar: calendar))
        #expect(quiet.contains(at(16, 23, 59), calendar: calendar))
        #expect(quiet.contains(at(17, 6, 59), calendar: calendar))
        #expect(!quiet.contains(at(17, 7), calendar: calendar))
        #expect(!quiet.contains(at(16, 20, 59), calendar: calendar))
    }

    @Test func windowInsideOneDayAndEmptyAndOff() {
        let lunch = MateQuietHours(startMinute: 12 * 60, endMinute: 13 * 60 + 30)
        #expect(lunch.contains(at(16, 12, 45), calendar: calendar))
        #expect(!lunch.contains(at(16, 13, 30), calendar: calendar))
        #expect(!MateQuietHours(startMinute: 600, endMinute: 600).contains(at(16, 10), calendar: calendar))
        #expect(!MateQuietHours(enabled: false).contains(at(16, 23), calendar: calendar))
    }

    @Test func endIsTheNextMorningOrTheSameMorning() {
        let quiet = MateQuietHours()
        #expect(quiet.end(after: at(16, 22), calendar: calendar) == at(17, 7))
        #expect(quiet.end(after: at(17, 3), calendar: calendar) == at(17, 7))
        #expect(quiet.end(after: at(17, 9), calendar: calendar) == nil)
    }

    @Test func minutesWrapIntoOneDay() {
        #expect(MateQuietHours.clamped(-30) == 24 * 60 - 30)
        #expect(MateQuietHours.clamped(24 * 60 + 5) == 5)
    }

    @Test func heartbeatHonoursQuietHoursAndTheDailyCap() {
        let late = MateQuietHours(startMinute: 23 * 60, endMinute: 6 * 60)
        // 21:30 was always quiet; with quiet hours from 23:00 a due check-in may run.
        #expect(MateHeartbeatSchedule.isDue(now: at(16, 21, 30), lastRunAt: at(16, 8), backedOff: false,
                                            userActive: true, calendar: calendar, quietHours: late))
        #expect(!MateHeartbeatSchedule.isDue(now: at(16, 21, 30), lastRunAt: at(16, 8), backedOff: false,
                                             userActive: true, calendar: calendar))
        #expect(!MateHeartbeatSchedule.isDue(now: at(16, 15), lastRunAt: at(16, 8), backedOff: false,
                                             userActive: true, calendar: calendar, runsToday: 1, maxPerDay: 1))
        #expect(!MateHeartbeatSchedule.isDue(now: at(16, 8), lastRunAt: nil, backedOff: false,
                                             userActive: true, calendar: calendar, runsToday: 0, maxPerDay: 0))
    }
}

struct MateNotificationGateTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    private func at(_ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: hour))!
    }

    private func decide(_ kind: MateNotificationKind, prefs: MateNotificationPreferences = .init(),
                        quiet: MateQuietHours = .init(), watching: Bool = false, unattended: Bool = false,
                        hour: Int = 10) -> MateNotificationGate.Decision {
        MateNotificationGate.decide(kind, preferences: prefs, quietHours: quiet, isWatching: watching,
                                    isUnattended: unattended, now: at(hour), calendar: calendar)
    }

    @Test func everythingIsOnByDefault() {
        for kind in MateNotificationKind.allCases {
            #expect(decide(kind) == .deliver)
        }
    }

    @Test func aSwitchOffDropsOnlyItsKind() {
        let prefs = MateNotificationPreferences(proposals: false)
        #expect(decide(.proposal, prefs: prefs) == .drop)
        #expect(decide(.failed, prefs: prefs) == .deliver)
        #expect(decide(.failed, prefs: MateNotificationPreferences(failedRoutine: false)) == .drop)
        #expect(decide(.needsInput, prefs: MateNotificationPreferences(needsInput: false)) == .drop)
    }

    @Test func finishedWorkIsSkippedWhileWatching() {
        #expect(decide(.finishedWork, watching: true) == .drop)
        #expect(decide(.needsInput, watching: true) == .deliver)
    }

    @Test func quietHoursHoldUnattendedNoticesUntilMorning() {
        let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 7))!
        #expect(decide(.failed, unattended: true, hour: 23) == .deliverAt(morning))
        #expect(decide(.proposal, unattended: true, hour: 23) == .deliverAt(morning))
        #expect(decide(.needsInput, unattended: true, hour: 23) == .deliverAt(morning))
        // A question on a task the person started still reaches them.
        #expect(decide(.needsInput, unattended: false, hour: 23) == .deliver)
        #expect(decide(.failed, quiet: MateQuietHours(enabled: false), unattended: true, hour: 23) == .deliver)
    }
}

struct MatePermissionResolverTests {
    @Test func aMateCanOnlyBeStricter() {
        #expect(MatePermissionResolver.effectiveMode(global: .fullAccess, override: .inherit) == .fullAccess)
        #expect(MatePermissionResolver.effectiveMode(global: .fullAccess, override: .alwaysAsk) == .askMe)
        #expect(MatePermissionResolver.effectiveMode(global: .askMe, override: .inherit) == .askMe)
        #expect(MatePermissionResolver.effectiveMode(global: .askMe, override: .alwaysAsk) == .askMe)
    }

    @Test func alwaysAskSetsAllowRulesAsideButKeepsAskAndDeny() {
        #expect(MatePermissionResolver.ruleDecision(.allow, override: .alwaysAsk) == nil)
        #expect(MatePermissionResolver.ruleDecision(.deny, override: .alwaysAsk) == .deny)
        #expect(MatePermissionResolver.ruleDecision(.ask, override: .alwaysAsk) == .ask)
        #expect(MatePermissionResolver.ruleDecision(.allow, override: .inherit) == .allow)
        #expect(MatePermissionResolver.ruleDecision(nil, override: .inherit) == nil)
    }
}

struct MateAgentLimitsTests {
    @Test func defaultsFollowTheApp() {
        let limits = MateAgentLimits()
        #expect(limits.effectiveMaxContinuations == MateAgentContinuation.maxContinuations)
        #expect(limits.effectiveRoutineMinutes == nil)
        #expect(limits.effectiveHeartbeatsPerDay == MateHeartbeatSchedule.slotsPerDay)
    }

    @Test func valuesAreClampedToTheirRanges() {
        let limits = MateAgentLimits(maxContinuations: 10_000, routineMinutes: 1, heartbeatsPerDay: 9)
        #expect(limits.effectiveMaxContinuations == MateAgentLimits.continuationRange.upperBound)
        #expect(limits.effectiveRoutineMinutes == MateAgentLimits.routineMinuteRange.lowerBound)
        #expect(limits.effectiveHeartbeatsPerDay == MateAgentLimits.heartbeatRange.upperBound)
        #expect(MateAgentLimits(maxContinuations: -3).effectiveMaxContinuations == 0)
    }

    @Test func routineDefaultFillsOnlyAMissingLimit() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var routine = MateRoutine.scheduled(mateID: UUID(), task: "Check mail", schedule: .everyHours(2),
                                            now: now, calendar: .current)
        let limits = MateAgentLimits(routineMinutes: 30)
        #expect(limits.applyingRoutineDefault(to: routine).maxRunMinutes == 30)
        routine.maxRunMinutes = 10
        #expect(limits.applyingRoutineDefault(to: routine).maxRunMinutes == 10)
        routine.maxRunMinutes = nil
        #expect(MateAgentLimits().applyingRoutineDefault(to: routine).maxRunMinutes == nil)
    }

    @Test func activityCountsResetEachDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 9))!
        let tuesday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 9))!
        var day = MateActivityDay.incremented(nil, .turns, now: monday, calendar: calendar)
        day = MateActivityDay.incremented(day, .turns, now: monday, calendar: calendar)
        day = MateActivityDay.incremented(day, .heartbeats, now: monday, calendar: calendar)
        #expect(day.day == "2026-11-16" && day.turns == 2 && day.heartbeats == 1 && day.routineRuns == 0)
        #expect(MateActivityDay.today(day, now: tuesday, calendar: calendar).turns == 0)
        let next = MateActivityDay.incremented(day, .routineRuns, now: tuesday, calendar: calendar)
        #expect(next.day == "2026-11-17" && next.turns == 0 && next.routineRuns == 1)
    }
}

struct MateAgentSettingsFileTests {
    @Test func anEmptyOrPartialFileLoadsWithDefaults() throws {
        let empty = try JSONDecoder().decode(MateAgentSettingsFile.self, from: Data("{}".utf8))
        #expect(empty == MateAgentSettingsFile())
        let id = UUID().uuidString
        let partial = """
        {"mates": {"\(id)": {"approval": "alwaysAsk", "quietHours": {"startMinute": 1380}, "notifications": {"proposals": false}}},
         "activity": {"\(id)": {"day": "2026-11-16", "turns": 4}}}
        """
        let file = try JSONDecoder().decode(MateAgentSettingsFile.self, from: Data(partial.utf8))
        let settings = try #require(file.mates[id])
        #expect(settings.approval == .alwaysAsk)
        #expect(settings.quietHours.startMinute == 1380 && settings.quietHours.endMinute == 7 * 60 && settings.quietHours.enabled)
        #expect(!settings.notifications.proposals && settings.notifications.finishedWork)
        #expect(settings.limits == MateAgentLimits() && settings.browserPanelStartsOpen)
        #expect(file.activity[id]?.turns == 4 && file.activity[id]?.heartbeats == 0)
    }

    @Test func unknownValuesFromALaterBuildDoNotLoseTheRest() throws {
        let id = UUID().uuidString
        let later = """
        {"mates": {"\(id)": {"approval": "neverAsk", "futureField": 1, "notifications": {"needsInput": false}}}, "extra": true}
        """
        let file = try JSONDecoder().decode(MateAgentSettingsFile.self, from: Data(later.utf8))
        let settings = try #require(file.mates[id])
        #expect(settings.approval == .inherit)
        #expect(!settings.notifications.needsInput)
    }

    @Test func roundTrips() throws {
        var settings = MateAgentSettings()
        settings.approval = .alwaysAsk
        settings.quietHours = MateQuietHours(enabled: false, startMinute: 60, endMinute: 120)
        settings.notifications.finishedWork = false
        settings.limits = MateAgentLimits(maxContinuations: 3, routineMinutes: 15, heartbeatsPerDay: 1)
        settings.browserPanelStartsOpen = false
        let file = MateAgentSettingsFile(mates: ["a": settings], activity: ["a": MateActivityDay(day: "2026-11-16", turns: 2)])
        let decoded = try JSONDecoder().decode(MateAgentSettingsFile.self, from: JSONEncoder().encode(file))
        #expect(decoded == file)
    }

    @Test func theMateRecordKeepsItsShape() throws {
        // Agent settings never adds keys to the Mate record, so the previous
        // release decodes a mate this build wrote.
        let mate = Mate(id: UUID(), name: "Scout", job: "Reads", pinned: false, archived: false, unreadCount: 0,
                        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
                        memoryNote: "", folderPath: nil)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mate)) as? [String: Any]
        let keys = Set(object?.keys.map { $0 } ?? [])
        #expect(keys.isSubset(of: ["id", "name", "job", "pinned", "archived", "unreadCount", "createdAt", "updatedAt",
                                   "memoryNote", "folderPath", "soul", "faceAssetName", "faceTint", "faceHair", "faceOutfit",
                                   "conductsOthers", "brainRawValue", "connectorExclusionIDs", "connectorOverrides",
                                   "backupBrainRawValue", "modelID", "effortRawValue", "enabledSkillNames", "browserProfileID"]))
    }
}

@MainActor
struct MateAgentSettingsStoreTests {
    @Test func savesAsItChangesAndForgetsADeletedMate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent(MateAgentSettingsStore.fileName)
        let mateID = UUID()
        let store = MateAgentSettingsStore(fileURL: url)
        #expect(store.settings(for: mateID) == MateAgentSettings())
        store.update(mateID) { $0.approval = .alwaysAsk }
        store.record(.turns, mateID: mateID)
        let reloaded = MateAgentSettingsStore(fileURL: url)
        #expect(reloaded.settings(for: mateID).approval == .alwaysAsk)
        #expect(reloaded.today(for: mateID).turns == 1)
        #expect(ApprovalMode.current(forMateID: mateID, defaults: UserDefaults(suiteName: "agent-settings-\(UUID())")!,
                                     store: reloaded) == .askMe)
        reloaded.remove(mateID)
        #expect(MateAgentSettingsStore(fileURL: url).settings(for: mateID) == MateAgentSettings())
    }
}

@MainActor
struct MateApprovalRuleStoreEditTests {
    @Test func rulesSurviveARelaunchAndEditInPlace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rules-edit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rules.json")
        let mateID = UUID()
        let store = MateApprovalRuleStore(fileURL: url)
        store.add(MateApprovalRule(tool: "bash", pattern: "git status*", decision: .allow), mateID: mateID)
        store.add(MateApprovalRule(tool: "bash", pattern: "npm test*", decision: .allow), mateID: mateID)
        // Saved with ISO 8601 dates: a fresh store must read them back.
        let reloaded = MateApprovalRuleStore(fileURL: url)
        #expect(reloaded.rules(for: mateID).map(\.pattern) == ["git status*", "npm test*"])
        let first = reloaded.rules(for: mateID)[0]
        reloaded.replace(id: first.id, with: MateApprovalRule(tool: "bash", pattern: "npm test*", decision: .deny), mateID: mateID)
        let edited = MateApprovalRuleStore(fileURL: url).rules(for: mateID)
        #expect(edited.count == 1)
        #expect(edited[0].id == first.id && edited[0].decision == .deny)
    }

    @Test func alwaysAskSetsAStoredAllowAside() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rules-ask-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("mate", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mateID = UUID()
        let scope = MateApprovalRuleScope(mateID: mateID, folder: folder, workingDirectory: nil)
        let rules = MateApprovalRuleStore(fileURL: root.appendingPathComponent("rules.json"))
        rules.add(MateApprovalRule(tool: "bash", pattern: "git status*", decision: .allow), mateID: mateID)
        let settings = MateAgentSettingsStore(fileURL: root.appendingPathComponent("settings.json"))
        let params: [String: JSONValue] = ["tool": .string("bash"), "subject": .string("git status")]
        #expect(MateApprovalRuleGate.answer(params, scope: scope, store: rules, settings: settings) == MateApprovalRuleGate.allowOnce())
        settings.update(mateID) { $0.approval = .alwaysAsk }
        #expect(MateApprovalRuleGate.answer(params, scope: scope, store: rules, settings: settings) == nil)
    }
}

struct MateFolderChoiceTests {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    @Test func refusesTheWholeDiskHomeLibraryAndSystem() {
        #expect(MateFolderChoice.refusal(for: URL(fileURLWithPath: "/"), home: home) != nil)
        #expect(MateFolderChoice.refusal(for: home, home: home) != nil)
        #expect(MateFolderChoice.refusal(for: home.appendingPathComponent("Library/Mail"), home: home) != nil)
        #expect(MateFolderChoice.refusal(for: URL(fileURLWithPath: "/System/Library"), home: home) != nil)
        #expect(MateFolderChoice.refusal(for: URL(fileURLWithPath: "/Applications"), home: home) != nil)
    }

    @Test func acceptsOwnFoldersAndOtherDrives() {
        #expect(MateFolderChoice.refusal(for: home.appendingPathComponent("Projects/Scout"), home: home) == nil)
        #expect(MateFolderChoice.refusal(for: URL(fileURLWithPath: "/Volumes/Work/Scout"), home: home) == nil)
    }
}
