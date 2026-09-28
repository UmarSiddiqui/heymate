//
//  MateCreationTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import HeyMate

struct MateCreationTests {

    @Test func oneMateKeepsTheJobText() {
        let jobs = MateCreationParser.parse("make me a mate that watches my inbox")
        #expect(jobs == ["watches my inbox"])
    }

    @Test func clickyIsAnAlias() {
        let jobs = MateCreationParser.parse("make me a clicky that watches my inbox")
        #expect(jobs == ["watches my inbox"])
    }

    @Test func listParsesUpToFiveJobs() {
        let jobs = MateCreationParser.parse(
            "make me three mates: inbox, competitor research, and newsletter"
        )
        #expect(jobs == ["inbox", "competitor research", "newsletter"])

        let six = MateCreationParser.parse(
            "make me mates: one, two, three, four, five, six"
        )
        #expect(six?.count == 5)
        #expect(six?.last == "five")
    }

    @Test func ordinaryChatIsNotAMateCommand() {
        #expect(MateCreationParser.parse("what is in my inbox") == nil)
    }

    @Test func inboxWatchIsTwoWordsAndNotBuddy() {
        let name = MateNameGenerator.name(for: "watches my inbox", existingNames: [])
        #expect(name.split(separator: " ").count == 2)
        #expect(name.hasSuffix("Buddy") == false)
        #expect(name == "Inbox Scout")
    }

    @Test func generatorVariesAgainstExistingNames() {
        let name = MateNameGenerator.name(
            for: "watches my inbox",
            existingNames: ["Inbox Scout"]
        )
        #expect(name != "Inbox Scout")
        #expect(name.hasSuffix("Buddy") == false)
        #expect(name.split(separator: " ").count == 2)
    }
}
