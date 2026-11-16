//
//  MateSettingsCatalogTests.swift
//  HeyMateTests
//
//  Agent settings search and the AGENTS.md note rows.
//

import Foundation
import Testing
@testable import HeyMate

struct MateSettingsCatalogTests {
    @Test func everySectionHasSearchableControls() {
        for section in MateSettingsSection.allCases {
            #expect(!MateSettingsCatalog.items(in: section, conductsOthers: false).isEmpty, "Nothing in \(section.title)")
        }
    }

    @Test func anchorsAreUniqueAndNamedForTheirSection() {
        let anchors = MateSettingsCatalog.items.map(\.anchor)
        #expect(Set(anchors).count == anchors.count)
        for item in MateSettingsCatalog.items {
            #expect(item.anchor.hasPrefix(item.section.rawValue + "."))
            #expect(!item.title.isEmpty && !item.keywords.isEmpty)
        }
    }

    @Test func searchRanksTitlesFirstAndFindsSynonyms() {
        #expect(MateSettingsCatalog.results(for: "model", conductsOthers: false).first?.anchor == "brain.model")
        #expect(MateSettingsCatalog.results(for: "QUIET", conductsOthers: false).first?.anchor == "proactive.quiet")
        #expect(MateSettingsCatalog.results(for: "sign out", conductsOthers: false).first?.anchor == "files.browser")
        #expect(MateSettingsCatalog.results(for: "heartbeat", conductsOthers: false).map(\.anchor).contains("proactive.heartbeat"))
        #expect(MateSettingsCatalog.results(for: "  ", conductsOthers: false).isEmpty)
        #expect(MateSettingsCatalog.results(for: "zzzz", conductsOthers: false).isEmpty)
    }

    @Test func theConductorDoesNotSeeWhatDoesNotApply() {
        let anchors = MateSettingsCatalog.results(for: "delete", conductsOthers: true).map(\.anchor)
        #expect(!anchors.contains("profile.delete"))
        #expect(MateSettingsCatalog.results(for: "folder", conductsOthers: true).allSatisfy { !$0.hiddenForConductor })
        #expect(MateSettingsCatalog.results(for: "delete", conductsOthers: false).map(\.anchor).contains("profile.delete"))
    }
}

struct MateMemoryNotesTests {
    @Test func datedLinesStartNotesAndOthersContinueThem() {
        let body = """
        Kept before dates existed.
        2026-10-25: Use the build script.
        Read the docs first.
        2026-11-01: Fresh captures only.
        """
        let notes = MateMemoryNotes.parse(body)
        #expect(notes == [
            MateMemoryNote(date: nil, text: "Kept before dates existed."),
            MateMemoryNote(date: "2026-10-25", text: "Use the build script.\nRead the docs first."),
            MateMemoryNote(date: "2026-11-01", text: "Fresh captures only."),
        ])
        #expect(MateMemoryNotes.parse(MateMemoryNotes.render(notes)) == notes)
    }

    @Test func placeholderAndBlankAreNoNotes() {
        #expect(MateMemoryNotes.parse(MateWorkspaceMemory.notesPlaceholder).isEmpty)
        #expect(MateMemoryNotes.parse("  \n ").isEmpty)
        #expect(MateMemoryNotes.render([MateMemoryNote(date: "2026-11-16", text: "  ")]) == "")
    }

    @Test func appendingStampsToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 10))!
        let notes = MateMemoryNotes.appending(" Prefer commas ", to: [], now: now, calendar: calendar)
        #expect(MateMemoryNotes.render(notes) == "2026-11-16: Prefer commas")
        #expect(MateMemoryNotes.appending("", to: notes, now: now, calendar: calendar) == notes)
    }
}
