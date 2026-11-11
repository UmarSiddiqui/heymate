import Foundation
import Testing
@testable import HeyMate

@MainActor
struct RoutineScheduleKindsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // 2026-11-13 is a Friday.
    @Test func weekdaysSkipTheWeekend() {
        let schedule = RoutineSchedule.weekdays(hour: 8, minute: 0)
        #expect(schedule.advance(from: date(2026, 11, 13, 7), now: date(2026, 11, 13, 7), calendar: calendar) == date(2026, 11, 13, 8))
        #expect(schedule.advance(from: date(2026, 11, 13, 9), now: date(2026, 11, 13, 9), calendar: calendar) == date(2026, 11, 16, 8))
        #expect(schedule.advance(from: date(2026, 11, 14, 12), now: date(2026, 11, 14, 12), calendar: calendar) == date(2026, 11, 16, 8))
        #expect(schedule.summary == "Weekdays at 8:00am")
    }

    @Test func weeklyLandsOnItsDay() {
        let mondays = RoutineSchedule.weekly(weekday: 2, hour: 9, minute: 30)
        #expect(mondays.advance(from: date(2026, 11, 13, 9), now: date(2026, 11, 13, 9), calendar: calendar) == date(2026, 11, 16, 9, 30))
        #expect(mondays.advance(from: date(2026, 11, 16, 9, 30), now: date(2026, 11, 16, 9, 30), calendar: calendar) == date(2026, 11, 23, 9, 30))
        #expect(mondays.summary == "Mondays at 9:30am")
    }

    @Test func minutesNeverRunFasterThanTheFloor() {
        let schedule = RoutineSchedule.everyMinutes(5)
        let start = date(2026, 11, 13, 9)
        #expect(schedule.advance(from: start, now: start, calendar: calendar) == start.addingTimeInterval(15 * 60))
        var routine = MateRoutine.scheduled(mateID: UUID(), task: "Check", schedule: .everyMinutes(30), now: start, calendar: calendar)
        routine = MateRoutineAccounting.recordLaunch(routine, now: start.addingTimeInterval(1_800), calendar: calendar)
        #expect(routine.nextRunAt == start.addingTimeInterval(3_600))
    }

    @Test func phrasesParseAndRoundTrip() {
        let now = date(2026, 11, 13, 7)
        func schedule(_ text: String) -> RoutineSchedule? {
            RoutinePhraseParser.parse(text, mateID: UUID(), now: now, calendar: calendar)?.schedule
        }
        #expect(schedule("check my inbox every weekday at 8am") == .weekdays(hour: 8, minute: 0))
        #expect(schedule("weekdays at 17:30 send me a summary") == .weekdays(hour: 17, minute: 30))
        #expect(schedule("every weekday morning write the brief") == .weekdays(hour: 8, minute: 0))
        #expect(schedule("every Monday at 9:30am plan the week") == .weekly(weekday: 2, hour: 9, minute: 30))
        #expect(schedule("review spending every friday") == .weekly(weekday: 6, hour: 8, minute: 0))
        #expect(schedule("check the page every 30 minutes") == .everyMinutes(30))
        #expect(schedule("check the page every 5 min") == .everyMinutes(15))
        #expect(schedule("check the page every 120 minutes") == .everyHours(2))
        #expect(schedule("check the page every half hour") == .everyMinutes(30))
        #expect(schedule("check my inbox every morning") == .daily(hour: 8, minute: 0))
        #expect(schedule("remind me on monday") == nil)
        #expect(RoutinePhraseParser.parse("every Monday at 9am plan the week", mateID: UUID(), now: now, calendar: calendar)?.task == "plan the week")
        for kind: RoutineSchedule in [
            .weekdays(hour: 8, minute: 0), .weekdays(hour: 17, minute: 30),
            .weekly(weekday: 1, hour: 0, minute: 5), .weekly(weekday: 7, hour: 12, minute: 0),
            .everyMinutes(45), .daily(hour: 8, minute: 15), .everyHours(3)
        ] {
            #expect(schedule("Check in \(kind.instructionPhrase)") == kind)
        }
    }

    @Test func newerSchedulesLiveInTheirOwnFileSoOlderBuildsKeepTheRest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("heymate-routines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("routines.json")
        let more = FileMateRoutineStore.extendedFileURL(for: url)
        let now = date(2026, 11, 13, 7)
        let mateID = UUID()
        let store = FileMateRoutineStore(fileURL: url)
        let daily = MateRoutine.scheduled(mateID: mateID, task: "Brief", schedule: .daily(hour: 8, minute: 0), now: now, calendar: calendar)
        let weekdays = MateRoutine.scheduled(mateID: mateID, task: "Inbox", schedule: .weekdays(hour: 8, minute: 0), now: now, calendar: calendar)
        store.upsert(daily)
        #expect(!FileManager.default.fileExists(atPath: more.path))
        store.upsert(weekdays)

        // What a build from before these schedules does: one strict array.
        let legacy = try JSONDecoder().decode([MateRoutine].self, from: Data(contentsOf: url))
        #expect(legacy.map(\.task) == ["Brief"])
        #expect(try String(contentsOf: url, encoding: .utf8).contains("weekdays") == false)

        let reopened = FileMateRoutineStore(fileURL: url).loadAll()
        #expect(Set(reopened.map(\.task)) == ["Brief", "Inbox"])
        #expect(reopened.first { $0.task == "Inbox" }?.schedule == .weekdays(hour: 8, minute: 0))

        store.delete(id: weekdays.id)
        #expect(!FileManager.default.fileExists(atPath: more.path))
        #expect(FileMateRoutineStore(fileURL: url).loadAll().map(\.task) == ["Brief"])
    }
}
