//
//  MacAccountContextTests.swift
//  HeyMateTests
//
//  Calendar and Mail are read only for questions about them, and what
//  reaches the prompt is one readable line per event or message.
//

import Foundation
import Testing
@testable import HeyMate

struct MacAccountContextTests {

    @Test func screenQuestionsReadNothing() {
        #expect(MacAccountContext.topics(in: "what does this error mean?").isEmpty)
        #expect(MacAccountContext.topics(in: "why is my mac so slow").isEmpty)
    }

    @Test func calendarAndMailQuestionsAreRecognised() {
        #expect(MacAccountContext.topics(in: "Am I free tomorrow afternoon?") == [.calendar])
        #expect(MacAccountContext.topics(in: "what's in my Gmail inbox") == [.mail])
        #expect(MacAccountContext.topics(in: "check my calendar and my email") == [.calendar, .mail])
    }

    @Test func eventLineNamesTheCalendarAndAccount() {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 6
        components.hour = 10; components.minute = 0
        let start = Calendar.current.date(from: components)!
        let end = start.addingTimeInterval(30 * 60)

        let line = MacAccountContext.formattedEventLine(
            title: "Standup",
            start: start,
            end: end,
            isAllDay: false,
            calendarName: "Work",
            accountName: "Google"
        )
        #expect(line == "- Tue 6 Oct 10:00–10:30 · Standup (Work, Google)")
    }

    @Test func untitledAllDayEventStillReads() {
        let line = MacAccountContext.formattedEventLine(
            title: nil,
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 86_400),
            isAllDay: true,
            calendarName: nil,
            accountName: nil
        )
        #expect(line.hasSuffix(", all day · Untitled"))
    }

    @Test func emptyCalendarSaysSo() {
        let block = MacAccountContext.calendarPromptBlock(eventLines: [], lookaheadDays: 7)
        #expect(block.contains("nothing scheduled"))
    }

    @Test func mailOutputBecomesOneLinePerMessage() {
        let raw = "\"Monday, 5 October 2026 at 09:12:00\\tSam <sam@example.com>\\tLunch?\\tunread\\nSunday, 4 October 2026 at 18:00:00\\tGitHub\\tYour build passed\\tread\\n\""
        let block = MacAccountContext.mailPromptBlock(rawOutput: raw)
        #expect(block.contains("- Monday, 5 October 2026 at 09:12:00 · from Sam <sam@example.com> · \"Lunch?\" · unread"))
        #expect(block.contains("· from GitHub · \"Your build passed\" · read"))
        #expect(block.contains("never send or delete"))
    }

    @Test func emptyInboxSaysSo() {
        #expect(MacAccountContext.mailPromptBlock(rawOutput: "\"\"").contains("the inbox is empty"))
    }
}
